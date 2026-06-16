local config = require('himalaya.config')
local request = require('himalaya.request')
local log = require('himalaya.log')
local account_state = require('himalaya.state.account')
local context = require('himalaya.state.context')

local M = {}

-- Pre-fetch state keyed by bufnr.  Populated by M.prefetch(), consumed
-- by M.render().  Each entry: { tmpdir, done, ok, job, callbacks }
local prefetch_state = {}

-- Render generation counter keyed by bufnr.  Incremented each time render()
-- is called; in-flight renders compare against this to detect cancellation.
local render_gen = {}

--- Start exporting email HTML in the background so gi is near-instant.
--- Called from email.lua immediately after the email text is displayed.
function M.prefetch(bufnr, account, folder, email_id)
  local function pflog(msg)
    local f = io.open('/tmp/himalaya-image-perf.log', 'a')
    if f then
      f:write(string.format('[%s] prefetch(buf=%d email=%s): %s\n', os.date('%H:%M:%S'), bufnr, email_id, msg))
      f:close()
    end
  end

  -- Kill any prior pre-fetch for this buffer (e.g. user navigated to new email).
  local old = prefetch_state[bufnr]
  if old then
    pflog('killing old prefetch for email=' .. tostring(old.email_id) .. ' tmpdir=' .. tostring(old.tmpdir))
    if old.job then
      pcall(old.job.kill, old.job)
    end
    if old.tmpdir then
      vim.fn.delete(old.tmpdir, 'rf')
    end
  end

  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, 'p')
  pflog('tmpdir=' .. tmpdir)

  local state = { tmpdir = tmpdir, email_id = email_id, done = false, ok = false, callbacks = {} }
  prefetch_state[bufnr] = state

  local cmd = request._build_cmd(
    'message export %s --folder %q -d %q %s',
    { account_state.flag(account), folder, tmpdir, email_id },
    'plain'
  )

  state.job = vim.system(cmd, { text = true, env = { RUST_LOG = 'off' } }, function(result)
    vim.schedule(function()
      state.done = true
      state.ok = result.code == 0
      state.job = nil
      for _, cb in ipairs(state.callbacks) do
        cb(state)
      end
      state.callbacks = {}
    end)
  end)
end

local IMAGE_SCROLL_KEYS = { '<C-d>', '<C-u>', '<C-f>', '<C-b>' }

--- While an email image is displayed, shadow smooth-scroll page keys with the
--- builtin discrete scroll (buffer-local) so stacked tiles don't flicker at
--- their seams during a smooth-scroll animation (the images reposition a frame
--- behind neovim's text-grid scroll; a single discrete jump doesn't show it).
--- No-op when render_html.smooth_image_scroll is set.
function M._apply_image_scroll_maps(bufnr)
  local cfg = config.get()
  if cfg.render_html and cfg.render_html.smooth_image_scroll then
    return
  end
  for _, key in ipairs(IMAGE_SCROLL_KEYS) do
    pcall(vim.keymap.set, 'n', key, key, {
      buffer = bufnr,
      nowait = true,
      silent = true,
      desc = 'himalaya: discrete scroll over inline image',
    })
  end
end

--- Remove the buffer-local discrete-scroll overrides (restoring smooth scroll
--- for the text view of the email).
function M._clear_image_scroll_maps(bufnr)
  for _, key in ipairs(IMAGE_SCROLL_KEYS) do
    pcall(vim.keymap.del, 'n', key, { buffer = bufnr })
  end
end

-- ───────────────────────── unicode placeholders ──────────────────────────
-- An alternative renderer that displays the email as kitty/ghostty unicode
-- placeholders: the image is transmitted once as a VIRTUAL placement (U=1) and
-- the placeholder cells live in the buffer as real text, so neovim scrolls them
-- in lockstep with the grid — zero cross-writer lag, no seams, no flicker, even
-- with smooth scrolling. The trade-off vs. chunked crop rendering: the whole
-- image must be resident in the terminal (transmitted up front). Behind the
-- render_html.placeholders toggle.
local ph_ok, ph_codes = pcall(require, 'image.backends.kitty.codes')
local PH_CHAR = ph_ok and ph_codes.placeholder or nil
local PH_DIAC = ph_ok and ph_codes.diacritics or nil
local PH_MAX = PH_DIAC and #PH_DIAC or 0 -- max rows/cols addressable with one diacritic

local ph_state = {} -- bufnr -> { id = <image id>, src = <scaled png path> }
local ph_id_counter = 90000 -- image ids; kept < 2^24 so the id fits the cell fg RGB
local ph_tty = nil

-- Hybrid text/image layer (render_html.hybrid, default off). The headless render
-- exposes the email's links/text with their bounding boxes; we map those onto the
-- placeholder buffer cells so the image gains a clickable/copyable layer. Because
-- the image lives in buffer cells, the entity rects live in buffer coordinates too
-- and scroll with it for free. Phase 0: extraction + alignment proof only (debug
-- dots / dump). Hover + hint UI build on hybrid_cells in later phases.
local hybrid_raw = {} -- bufnr -> { vw = <css viewport width>, items = {entities} }
local hybrid_cells = {} -- bufnr -> mapped entities in buffer-cell coords
local hybrid_dots_on = {} -- bufnr -> bool (debug overlay toggle)
local hybrid_hover = {} -- bufnr -> { win, buf, idx } for the live hover float
local hybrid_aug = {} -- bufnr -> augroup id for the hover autocmds
local hybrid_search = {} -- bufnr -> { matches = {{row,cell,idx}}, cur, query }
local hybrid_entering = {} -- bufnr -> bool: guards the hover auto-close while K focuses the float
local hybrid_nav_on = {} -- bufnr -> bool: hjkl node-navigation mode active
local HYBRID_NS = vim.api.nvim_create_namespace('himalaya_hybrid')
local HYBRID_SEARCH_NS = vim.api.nvim_create_namespace('himalaya_hybrid_search')
local HYBRID_HINT_NS = vim.api.nvim_create_namespace('himalaya_hybrid_hint')

local function ph_alloc_id()
  ph_id_counter = ph_id_counter + 1
  return ph_id_counter
end

local function ph_send(seq)
  if vim.env.TMUX then
    seq = '\x1bPtmux;' .. seq:gsub('\x1b', '\x1b\x1b') .. '\x1b\\'
  end
  if not ph_tty then
    ph_tty = vim.uv.new_tty(1, false)
  end
  if ph_tty then
    ph_tty:write(seq)
  end
end

-- Transmit + create a virtual placement (U=1) from a file (t=f -> payload is the
-- base64 path; kitty reads the file). Re-transmitting the same id replaces it.
local function ph_transmit(path, id)
  ph_send(('\x1b_Ga=T,U=1,i=%d,f=100,t=f,q=2;%s\x1b\\'):format(id, vim.base64.encode(path)))
end

-- Delete the image and free its data.
local function ph_delete(id)
  ph_send(('\x1b_Ga=d,d=I,i=%d,q=2\x1b\\'):format(id))
end

-- Re-transmit every live placeholder image. image.nvim deletes ALL terminal
-- images on focus/resume events (for its own lifecycle); since our images
-- aren't image.nvim-managed they'd otherwise blank out until re-rendered.
function M._ph_retransmit_all()
  for bufnr, st in pairs(ph_state) do
    if
      vim.api.nvim_buf_is_valid(bufnr)
      and vim.b[bufnr].himalaya_image_rendered
      and st.src
      and vim.fn.filereadable(st.src) == 1
    then
      ph_transmit(st.src, st.id)
    end
  end
end

local ph_autocmds_done = false
local function ph_ensure_autocmds()
  if ph_autocmds_done then
    return
  end
  ph_autocmds_done = true
  local grp = vim.api.nvim_create_augroup('HimalayaPlaceholders', { clear = true })
  vim.api.nvim_create_autocmd({ 'FocusGained', 'VimResume' }, {
    group = grp,
    callback = function()
      -- run after image.nvim's synchronous "delete all" so ours light back up
      vim.defer_fn(function()
        M._ph_retransmit_all()
      end, 60)
    end,
  })
end

--- Display a PNG in the buffer via image.nvim, replacing text with filler lines.
--- Used by both the full render pipeline and the cached-PNG fast path.
function M._show_image(image, bufnr, winid, png_path, plog)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  local saved_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local win_width = vim.api.nvim_win_get_width(winid)

  -- Stable id (the png path) so progressive's two passes reuse ONE image.nvim
  -- Image object — it gets re-measured on the second pass (its mtime changed)
  -- rather than spawning a second, stacked image that also re-renders on every
  -- scroll.
  local img = image.from_file(png_path, {
    id = png_path,
    buffer = bufnr,
    window = winid,
    x = 0,
    y = 0,
    width = win_width,
    max_height_window_percentage = 9999,
  })
  if not img then
    log.err('image.nvim failed to load ' .. png_path)
    return
  end

  -- Set filler lines BEFORE render so the number-column width (textoff)
  -- is stable when image.nvim calls screenpos().  image.nvim positions
  -- images at absolute screen coordinates; if the buffer line count
  -- changes after render (changing textoff), the image is offset by the
  -- difference.  Pre-compute height from the image dimensions that
  -- from_file already read from the PNG header.
  local height_rows = 500
  if img.image_width > 0 and img.image_height > 0 then
    local aspect_ratio = img.image_width / img.image_height
    -- image.nvim converts win_width columns to pixels using the terminal
    -- cell size, then divides by aspect ratio and cell height.  We
    -- replicate that here using the same utility it uses.
    local ok_ts, term_size = pcall(function()
      return require('image.utils.term').get_size()
    end)
    if ok_ts and term_size and term_size.cell_width > 0 and term_size.cell_height > 0 then
      local pixel_width = win_width * term_size.cell_width
      height_rows = math.ceil(pixel_width / aspect_ratio / term_size.cell_height)
    end
  end

  if plog then
    plog(
      string.format(
        'image src dims=%sx%s win_width=%d -> filler height_rows=%d',
        tostring(img.image_width),
        tostring(img.image_height),
        win_width,
        height_rows
      )
    )
  end

  local filler = {}
  for i = 1, height_rows - 1 do
    filler[i] = ''
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, filler)
  vim.bo[bufnr].modifiable = false

  local render_t0 = vim.uv.hrtime()
  img:render()
  local render_ms = (vim.uv.hrtime() - render_t0) / 1e6
  if plog then
    plog(
      string.format(
        'image.nvim render: %.1fms (post-render src=%sx%s rendered=%sx%s rows=%s)',
        render_ms,
        tostring(img.image_width),
        tostring(img.image_height),
        tostring(img.rendered_geometry and img.rendered_geometry.width),
        tostring(img.rendered_geometry and img.rendered_geometry.height),
        tostring(img.rendered_geometry and img.rendered_geometry.height)
      )
    )
  end

  -- Correct filler if image.nvim computed a different height (rounding, or the
  -- source PNG changed between progressive passes so render() re-read dims).
  local actual_rows = img.rendered_geometry and img.rendered_geometry.height
  if actual_rows and actual_rows > 0 and actual_rows ~= height_rows then
    if plog then
      plog(string.format('filler correction: %d -> %d rows', height_rows, actual_rows))
    end
    height_rows = actual_rows
    filler = {}
    for i = 1, height_rows - 1 do
      filler[i] = ''
    end
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, filler)
    vim.bo[bufnr].modifiable = false
  end

  vim.b[bufnr].himalaya_image_rendered = true
  vim.b[bufnr].himalaya_image_png = png_path
  vim.b[bufnr].himalaya_saved_lines = saved_lines
  M._apply_image_scroll_maps(bufnr)

  -- Update winbar to indicate image mode.
  local base = vim.b[bufnr].himalaya_original_winbar or vim.wo[winid].winbar or ''
  vim.b[bufnr].himalaya_original_winbar = base
  vim.wo[winid].winbar = base .. ' [IMAGE]'

  if plog then
    plog('DONE — image visible')
  end
end

--- Read a PNG's pixel dimensions straight from the IHDR header (no decode, no
--- subprocess).  PNG layout: 8-byte signature, 4-byte chunk length, "IHDR",
--- then width/height as big-endian uint32 (file offsets 16 and 20, 0-based).
function M._read_png_size(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local hdr = f:read(24)
  f:close()
  if not hdr or #hdr < 24 then
    return nil
  end
  local function be(s)
    local n = 0
    for i = 1, #s do
      n = n * 256 + s:byte(i)
    end
    return n
  end
  return be(hdr:sub(17, 20)), be(hdr:sub(21, 24))
end

--- Display a tall PNG as a vertical stack of viewport-height tiles, each its own
--- image.nvim image.  image.nvim only transmits the tiles intersecting the
--- visible window (off-screen tiles early-return before transmit in its render
--- loop), so a long email ships ~1 screen of pixels up front and streams the
--- rest on scroll.  Slices are produced in parallel by magick.
---
--- Falls back to M._show_image (single image) when the prerequisites aren't met
--- (no magick / no cell size) or when the email is short enough to fit one tile.
function M._show_image_chunked(image, bufnr, winid, png_path, plog)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  local function clog(msg)
    if plog then
      plog('chunked: ' .. msg)
    end
  end

  local ok_ts, term_size = pcall(function()
    return require('image.utils.term').get_size()
  end)
  local img_w, img_h = M._read_png_size(png_path)
  local have_magick = vim.fn.executable('magick') == 1

  -- Bail to the single-image path if we can't slice meaningfully.
  if
    not have_magick
    or not ok_ts
    or not term_size
    or not term_size.cell_height
    or term_size.cell_height <= 0
    or not img_h
    or img_h <= 0
  then
    clog('prerequisites unmet — falling back to single image')
    return M._show_image(image, bufnr, winid, png_path, plog)
  end

  local cell_w = term_size.cell_width
  local cell_h = term_size.cell_height
  local win_width = vim.api.nvim_win_get_width(winid)
  local viewport_rows = vim.api.nvim_win_get_height(winid)
  if viewport_rows < 1 then
    viewport_rows = 1
  end
  local chunk_rows = viewport_rows

  if math.ceil(img_h / cell_h) <= chunk_rows then
    clog('email fits one tile — falling back to single image')
    return M._show_image(image, bufnr, winid, png_path, plog)
  end

  local saved_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Set a preliminary full-height filler block FIRST so the number column
  -- (textoff) settles at its final digit width before we read it. image.nvim
  -- clamps the display to (win_width - textoff) columns and renders the PNG at
  -- that many cell_widths; if the source PNG isn't already that exact width it
  -- resizes — and with N tiles that means N expensive resizes AND per-tile
  -- ceil-rounding that misaligns the seams (the visible gap). We instead resize
  -- the whole PNG once to that exact width, then slice, so every tile is
  -- pixel-for-pixel what image.nvim wants (needs_resize=false, exact rows).
  local function set_filler(n)
    local filler = {}
    for i = 1, n do
      filler[i] = ''
    end
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, filler)
    vim.bo[bufnr].modifiable = false
  end
  set_filler(math.ceil(img_h / cell_h))

  local textoff = (vim.fn.getwininfo(winid)[1] or {}).textoff or 0
  local display_cols = math.max(1, win_width - textoff)
  local target_w = math.floor(display_cols * cell_w + 0.5)
  local scaled = (png_path:gsub('%.png$', '')) .. '.scaled.png'

  clog(
    string.format(
      'png=%dx%d cell=%.2fx%.2f win_width=%d textoff=%d display_cols=%d target_w=%d',
      img_w or 0,
      img_h,
      cell_w,
      cell_h,
      win_width,
      textoff,
      display_cols,
      target_w
    )
  )

  -- Resize the whole email to image.nvim's exact render width once, then build
  -- the tiles from the scaled copy.
  vim.system({ 'magick', png_path, '-resize', target_w .. 'x', '+repage', scaled }, { text = true }, function(rz)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_win_is_valid(winid) then
        return
      end
      local src, sw, sh
      if rz.code == 0 then
        sw, sh = M._read_png_size(scaled)
      end
      if sw and sh and sw > 0 and sh > 0 then
        src = scaled
      else
        -- Resize failed — fall back to slicing the original (image.nvim will
        -- resize each tile, slower, but still correct).
        clog('full resize failed; slicing original')
        src, sw, sh = png_path, img_w, img_h
      end

      local total_rows = math.ceil(sh / cell_h)
      local num_chunks = math.ceil(total_rows / chunk_rows)
      set_filler(total_rows)

      clog(
        string.format(
          'scaled=%dx%d total_rows=%d chunk_rows=%d num_chunks=%d',
          sw,
          sh,
          total_rows,
          chunk_rows,
          num_chunks
        )
      )

      -- Tile layout: row boundaries map to pixel boundaries through cell_h, so
      -- tiles abut exactly on cell rows (no gap, no overlap).
      local chunks = {}
      for i = 0, num_chunks - 1 do
        local anchor_y = i * chunk_rows
        local rows_i = math.min(chunk_rows, total_rows - anchor_y)
        local y_top = math.floor(anchor_y * cell_h + 0.5)
        local y_bot = math.min(math.floor((anchor_y + rows_i) * cell_h + 0.5), sh)
        if y_bot > y_top then
          chunks[#chunks + 1] = {
            index = i,
            anchor_y = anchor_y,
            y_top = y_top,
            chunk_px = y_bot - y_top,
            file = (png_path:gsub('%.png$', '')) .. '.c' .. i .. '.png',
            id = png_path .. '#' .. i,
          }
        end
      end

      -- Clear leftover tiles from a previous (taller) render of this buffer —
      -- e.g. a progressive first pass that produced more chunks than this one.
      local prev_count = vim.b[bufnr].himalaya_chunk_count or 0
      if prev_count > #chunks then
        local keep = {}
        for _, c in ipairs(chunks) do
          keep[c.id] = true
        end
        for _, im in ipairs(image.get_images({ buffer = bufnr })) do
          if not keep[im.id] then
            im:clear()
          end
        end
      end
      vim.b[bufnr].himalaya_chunk_count = #chunks

      vim.b[bufnr].himalaya_image_rendered = true
      vim.b[bufnr].himalaya_image_png = png_path
      vim.b[bufnr].himalaya_saved_lines = saved_lines
      M._apply_image_scroll_maps(bufnr)

      local base = vim.b[bufnr].himalaya_original_winbar or vim.wo[winid].winbar or ''
      vim.b[bufnr].himalaya_original_winbar = base
      vim.wo[winid].winbar = base .. ' [IMAGE]'

      local t0 = vim.uv.hrtime()
      local placed = 0
      local placed_imgs = {}
      local first_paint_logged = false

      local function place(c)
        if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_win_is_valid(winid) then
          return
        end
        local img = image.from_file(c.file, {
          id = c.id,
          buffer = bufnr,
          window = winid,
          x = 0,
          y = c.anchor_y,
          width = win_width,
          max_height_window_percentage = 9999,
        })
        if not img then
          clog('from_file failed for ' .. c.file)
          return
        end
        img:render()
        placed_imgs[c.index] = img
        placed = placed + 1
        -- Chunk 0 covers the visible top — log when it lands so we can compare
        -- time-to-first-paint against the full stack completing.
        if c.index == 0 and not first_paint_logged then
          first_paint_logged = true
          clog(string.format('first tile painted at %.1fms', (vim.uv.hrtime() - t0) / 1e6))
        end
        if placed == #chunks then
          clog(string.format('all %d tiles placed at %.1fms', #chunks, (vim.uv.hrtime() - t0) / 1e6))
          -- Background-preload every tile shortly after first paint: off-screen
          -- tiles get transmitted to the terminal now so that scrolling to one
          -- shows it instantly, instead of paying the transmit latency at that
          -- moment (a one-time blank-gap flicker the first time each tile
          -- appears). Deferred + transmit-only, so it doesn't delay first paint
          -- or place anything; tiles already visible are no-ops (cache hit).
          vim.defer_fn(function()
            if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_win_is_valid(winid) then
              return
            end
            for _, im in pairs(placed_imgs) do
              if im and im.preload then
                pcall(function()
                  im:preload()
                end)
              end
            end
          end, 80)
        end
      end

      -- Slice every tile in parallel; place each the instant its slice lands.
      -- Off-screen tiles cost only a from_file + an early-return in image.nvim
      -- (no transmit), so the visible tile paints without waiting on the rest.
      --
      -- magick writes to a temp file which is then atomically renamed onto the
      -- tile path. A progressive second pass re-slices the SAME tile files, and
      -- image.nvim may be reading one on a scroll re-render at that moment;
      -- writing in place would let it read a half-written PNG (magick identify
      -- "unexpected end-of-file", and torn image bytes spilling to the screen).
      -- The rename is the only mutation of c.file, so a concurrent reader
      -- always sees a complete file — the old one or the new one, never a mix.
      for _, c in ipairs(chunks) do
        local work = c.file .. '.work'
        vim.system(
          { 'magick', src, '-crop', sw .. 'x' .. c.chunk_px .. '+0+' .. c.y_top, '+repage', work },
          { text = true },
          function(res)
            vim.schedule(function()
              if res.code ~= 0 then
                clog(string.format('slice %d failed: %s', c.index, (res.stderr or ''):gsub('%s+', ' ')))
                return
              end
              local ok, err = os.rename(work, c.file)
              if not ok then
                clog(string.format('slice %d rename failed (%s); copying', c.index, tostring(err)))
                pcall(vim.uv.fs_copyfile, work, c.file)
                pcall(os.remove, work)
              end
              place(c)
            end)
          end
        )
      end
    end)
  end)
end

--- When placeholders can't be used (too tall, missing prerequisites), fall back
--- to the crop renderer (chunked if enabled, else single image).
function M._show_image_fallback(image, bufnr, winid, png_path, plog)
  local cfg = config.get()
  if cfg.render_html and cfg.render_html.chunked then
    return M._show_image_chunked(image, bufnr, winid, png_path, plog)
  end
  return M._show_image(image, bufnr, winid, png_path, plog)
end

--- Display the email as unicode placeholders (smooth-scrolling, grid-integrated).
--- Transmits the resized PNG once as a virtual placement and lays the placeholder
--- cells as real buffer text; neovim scrolls them natively.
function M._show_image_placeholders(image, bufnr, winid, png_path, plog)
  local function clog(msg)
    if plog then
      plog('placeholders: ' .. msg)
    end
  end
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  if not PH_CHAR or not PH_DIAC or vim.fn.executable('magick') ~= 1 then
    clog('unavailable (no kitty codes / no magick) — falling back')
    return M._show_image_fallback(image, bufnr, winid, png_path, plog)
  end
  local ok_ts, term_size = pcall(function()
    return require('image.utils.term').get_size()
  end)
  if not ok_ts or not term_size or not term_size.cell_height or term_size.cell_height <= 0 then
    clog('no cell size — falling back')
    return M._show_image_fallback(image, bufnr, winid, png_path, plog)
  end
  local cell_w = term_size.cell_width
  local cell_h = term_size.cell_height
  local win_width = vim.api.nvim_win_get_width(winid)
  local img_w, img_h = M._read_png_size(png_path)
  if not img_h then
    return M._show_image_fallback(image, bufnr, winid, png_path, plog)
  end

  if not vim.o.termguicolors then
    clog('WARNING: termguicolors is off — placeholders need it (the image id is read from the cell fg)')
  end

  local function set_lines(tbl)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, tbl)
    vim.bo[bufnr].modifiable = false
  end

  -- A re-render of the SAME buffer (progressive's blurry→sharp second pass) must
  -- not disturb the on-screen placeholder cells, or the image blinks. The two
  -- passes overlap, so re-entry detection and the saved email text are stamped
  -- on the buffer SYNCHRONOUSLY here, before any async work: a second pass that
  -- starts before the first's async layout finishes still sees them.
  local is_reentry = vim.b[bufnr].himalaya_ph_id ~= nil
  local id = vim.b[bufnr].himalaya_ph_id
  if not id then
    id = ph_alloc_id()
    vim.b[bufnr].himalaya_ph_id = id
  end
  local saved_lines
  if is_reentry then
    saved_lines = vim.b[bufnr].himalaya_saved_lines
  else
    saved_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.b[bufnr].himalaya_saved_lines = saved_lines -- stamp the real text before mutating
    -- Prelim filler so textoff (the number column) settles before we measure
    -- cols. It must have the SAME line COUNT (hence the same gutter digit width)
    -- as the final layout, or textoff is measured wrong and cols comes out off
    -- by one. Sizing from the raw png height is wrong: the image is first scaled
    -- to the window width, so the laid-out row count is the SCALED height /
    -- cell_h, not the raw height / cell_h. For a low-res progressive pass the
    -- raw png is short (few lines, 2-digit gutter) while the real layout is
    -- hundreds of lines (3-digit gutter) — a one-column mismatch that jams an
    -- N+1-cell grid into an N-column text area and clips the right edge.
    -- Estimate the scaled rows assuming cols ~ win_width (textoff is small
    -- relative to it, and only the digit width of the count matters here).
    local est_rows = math.max(1, math.ceil(img_h * win_width * cell_w / math.max(1, img_w) / cell_h))
    local pf = {}
    for i = 1, est_rows do
      pf[i] = ''
    end
    set_lines(pf)
  end

  local textoff = (vim.fn.getwininfo(winid)[1] or {}).textoff or 0
  local cols = math.max(1, win_width - textoff)
  local target_w = math.floor(cols * cell_w + 0.5)
  local scaled = (png_path:gsub('%.png$', '')) .. '.ph.png'
  local work = scaled .. '.work'
  clog(
    string.format(
      'png=%dx%d cols=%d target_w=%d textoff=%d reentry=%s',
      img_w or 0,
      img_h,
      cols,
      target_w,
      textoff,
      tostring(is_reentry)
    )
  )

  -- magick to a temp file then atomic rename, so a concurrent focus re-transmit
  -- never reads a half-written scaled PNG.
  vim.system({ 'magick', png_path, '-resize', target_w .. 'x', '+repage', work }, { text = true }, function(rz)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_win_is_valid(winid) then
        return
      end
      local src, sw, sh
      if rz.code == 0 then
        if not os.rename(work, scaled) then
          pcall(vim.uv.fs_copyfile, work, scaled)
          pcall(os.remove, work)
        end
        sw, sh = M._read_png_size(scaled)
      end
      if sw and sh and sw > 0 and sh > 0 then
        src = scaled
      else
        src, sw, sh = png_path, img_w, img_h
      end

      local rows = math.ceil(sh / cell_h)
      if rows > PH_MAX or cols > PH_MAX then
        clog(
          string.format(
            'too large for single-diacritic grid (rows=%d cols=%d max=%d) — falling back',
            rows,
            cols,
            PH_MAX
          )
        )
        if not is_reentry then
          vim.b[bufnr].himalaya_ph_id = nil
          ph_state[bufnr] = nil
          set_lines(saved_lines)
        end
        return M._show_image_fallback(image, bufnr, winid, png_path, plog)
      end

      -- Hybrid layer: map the extracted entity boxes onto this layout. Before
      -- the same-grid early return so it runs on every pass reaching here.
      -- No-op unless render_html.hybrid and a layer was extracted.
      if (config.get().render_html or {}).hybrid then
        M._hybrid_map(bufnr, target_w, cell_w, cell_h, rows, cols, clog)
      end

      -- (Re-)transmit the image data under this id. Whichever pass's magick
      -- finishes FIRST lays out the cells (ph_state still nil); a later pass with
      -- the same grid does ONLY the re-transmit — kitty redraws the existing
      -- cells with the new (sharp) data underneath, seamless, no buffer change.
      ph_transmit(src, id)
      local prev = ph_state[bufnr]
      local same_grid = prev and prev.rows == rows and prev.cols == cols
      ph_state[bufnr] = { id = id, src = src, rows = rows, cols = cols }
      if same_grid then
        clog(string.format('id=%d in-place data update (seamless) rows=%d cols=%d', id, rows, cols))
        return
      end

      -- Fresh layout (or the grid changed): lay placeholder cells as buffer text.
      -- The LAST cell of each row is a BARE placeholder char (no diacritics):
      -- kitty auto-derives its position (same row, previous column + 1), so it
      -- still references the correct image column. This matters at the
      -- terminal's absolute rightmost column, where the deferred-wrap
      -- ("magic margin") state drops the combining diacritics on every
      -- continuation row — leaving a ragged black strip down the right edge for
      -- all rows but the first. A bare codepoint carries no combining marks, so
      -- it commits at the edge like plain text and the image spans full width.
      -- Harmless when not flush against the edge (auto-increment is standard).
      local lines = {}
      for r = 0, rows - 1 do
        local dr = PH_DIAC[r + 1]
        local cells = {}
        for c = 0, cols - 1 do
          cells[c + 1] = PH_CHAR .. dr .. PH_DIAC[c + 1]
        end
        if cols > 1 then
          cells[cols] = PH_CHAR -- fully bare (auto-increments row+col) for the edge
        end
        lines[r + 1] = table.concat(cells)
      end
      set_lines(lines)

      local hl = 'HimalayaPh' .. id
      vim.api.nvim_set_hl(0, hl, { fg = ('#%06x'):format(id) })
      local ns = vim.api.nvim_create_namespace('himalaya_ph')
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
      for ln = 0, rows - 1 do
        vim.api.nvim_buf_set_extmark(bufnr, ns, ln, 0, {
          end_row = ln,
          end_col = #lines[ln + 1],
          hl_group = hl,
        })
      end

      vim.b[bufnr].himalaya_image_rendered = true
      vim.b[bufnr].himalaya_image_png = png_path
      vim.b[bufnr].himalaya_saved_lines = saved_lines

      local base = vim.b[bufnr].himalaya_original_winbar or vim.wo[winid].winbar or ''
      vim.b[bufnr].himalaya_original_winbar = base
      vim.wo[winid].winbar = base .. ' [IMAGE]'

      ph_ensure_autocmds()
      if (config.get().render_html or {}).hybrid then
        M._hybrid_attach(bufnr) -- idempotent; hover lights up once entities map
      end
      clog(string.format('id=%d scaled=%dx%d rows=%d cols=%d (smooth)', id, sw, sh, rows, cols))
    end)
  end)
end

--- Display a rendered PNG, dispatching to placeholders, the chunked tile stack,
--- or the single image based on the render_html toggles.
-- === Hybrid text/image layer (render_html.hybrid) ===========================

-- JS evaluated in the settled headless page: collect links AND text runs with
-- their on-page rects. The page isn't scrolled (the whole email fits the tall
-- viewport), so getClientRects() are absolute document coords in CSS px — the
-- same origin as the screenshot. Links are typed/special (carry href); text
-- runs (one per text node, skipping link text already captured) power g/
-- search. A node spanning several visual lines yields one rect per line.
local HYBRID_EXTRACT_JS = [[(function(){
  var out=[],CAP=2000;
  function pushRects(el){
    var rs=el.getClientRects(),rects=[];
    for(var j=0;j<rs.length;j++){var r=rs[j];if(r.width<1||r.height<1)continue;
      rects.push({x:r.left,y:r.top,w:r.width,h:r.height});}
    return rects;
  }
  var as=document.querySelectorAll('a[href]');
  for(var i=0;i<as.length&&out.length<CAP;i++){
    var a=as[i],rects=pushRects(a);
    if(!rects.length)continue;
    var t=(a.innerText||a.textContent||'').replace(/\s+/g,' ').trim();
    if(!t){ // image links (a wrapping img, no text): use the image alt text
      var alts=[],imgs=a.querySelectorAll('img');
      for(var k=0;k<imgs.length;k++){var al=(imgs[k].getAttribute('alt')||'').trim();if(al)alts.push(al);}
      t=alts.join(' · ').replace(/\s+/g,' ').trim();
    }
    if(!t)t=(a.getAttribute('aria-label')||a.getAttribute('title')||'').replace(/\s+/g,' ').trim();
    out.push({type:'link',text:t.slice(0,200),href:a.href,rects:rects});
  }
  var wlk=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,{acceptNode:function(n){
    if(!n.nodeValue||!n.nodeValue.trim())return NodeFilter.FILTER_REJECT;
    var p=n.parentElement;if(!p)return NodeFilter.FILTER_REJECT;
    var tag=p.tagName;
    if(tag==='SCRIPT'||tag==='STYLE'||tag==='NOSCRIPT'||tag==='TITLE')return NodeFilter.FILTER_REJECT;
    if(p.closest('a[href]'))return NodeFilter.FILTER_REJECT;
    var st=getComputedStyle(p);
    if(st.visibility==='hidden'||st.display==='none')return NodeFilter.FILTER_REJECT;
    return NodeFilter.FILTER_ACCEPT;
  }});
  var n;
  while((n=wlk.nextNode())&&out.length<CAP){
    var rg=document.createRange();rg.selectNodeContents(n);
    var rs2=rg.getClientRects(),rects2=[];
    for(var k=0;k<rs2.length;k++){var r2=rs2[k];if(r2.width<1||r2.height<1)continue;
      rects2.push({x:r2.left,y:r2.top,w:r2.width,h:r2.height});}
    if(!rects2.length)continue;
    var tt=n.nodeValue.replace(/\s+/g,' ').trim().slice(0,4000);
    if(tt)out.push({type:'text',text:tt,rects:rects2});
  }
  return JSON.stringify(out);
})()]]

--- Pull the entity layer from the (final-pass) headless page over CDP and stash
--- it keyed by buffer. Never blocks the render: calls done() regardless.
function M._hybrid_extract(client, bufnr, viewport_width, plog, done)
  client:send('Runtime.evaluate', { expression = HYBRID_EXTRACT_JS, returnByValue = true }, function(err, result)
    local ok, items = false, nil
    if not err and result and result.result then
      ok, items = pcall(vim.json.decode, result.result.value or '')
    end
    if ok and type(items) == 'table' then
      hybrid_raw[bufnr] = { vw = viewport_width, items = items }
      if plog then
        plog(string.format('hybrid: extracted %d entities (vw=%d)', #items, viewport_width))
      end
    else
      hybrid_raw[bufnr] = nil
      if plog then
        plog('hybrid: extract failed or empty: ' .. tostring(err))
      end
    end
    if done then
      done()
    end
  end)
end

--- Map the extracted CSS-px rects to buffer-cell rects against the displayed
--- image geometry. The image occupies buffer lines 0..rows-1; display px =
--- css px * (target_w / viewport_width); cell = floor(px / cell_size).
function M._hybrid_map(bufnr, target_w, cell_w, cell_h, rows, cols, clog)
  local hy = hybrid_raw[bufnr]
  if not hy or not hy.vw or hy.vw <= 0 then
    return
  end
  local scale = target_w / hy.vw
  local mapped = {}
  for _, it in ipairs(hy.items) do
    local crects = {}
    for _, r in ipairs(it.rects) do
      local cc0 = math.floor(r.x * scale / cell_w)
      local cr0 = math.floor(r.y * scale / cell_h)
      local cc1 = math.ceil((r.x + r.w) * scale / cell_w) - 1
      local cr1 = math.ceil((r.y + r.h) * scale / cell_h) - 1
      cc0 = math.max(0, math.min(cc0, cols - 1))
      cc1 = math.max(cc0, math.min(cc1, cols - 1))
      cr0 = math.max(0, math.min(cr0, rows - 1))
      cr1 = math.max(cr0, math.min(cr1, rows - 1))
      crects[#crects + 1] = { cr0 = cr0, cc0 = cc0, cr1 = cr1, cc1 = cc1 }
    end
    if #crects > 0 then
      mapped[#mapped + 1] = { type = it.type, text = it.text, href = it.href, rects = crects }
    end
  end
  hybrid_cells[bufnr] = mapped
  if clog then
    clog(string.format('hybrid: mapped %d entities (scale=%.3f)', #mapped, scale))
  end
  if hybrid_dots_on[bufnr] then
    M._hybrid_dots(bufnr, true) -- refresh the overlay against the new layout
  end
end

--- Debug overlay (Phase 0 alignment proof): drop a marker at the top-left cell
--- of every entity rect so the mapping can be eyeballed against the rendered
--- image. virt_text_win_col positions by window column (cell index), so no
--- per-cell byte math is needed over the multi-byte placeholder text.
function M._hybrid_dots(bufnr, show)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, HYBRID_NS, 0, -1)
  if not show then
    return
  end
  local mapped = hybrid_cells[bufnr]
  if not mapped then
    return
  end
  local n = 0
  for _, e in ipairs(mapped) do
    if e.type == 'link' then
      -- links: one numbered cyan marker at the entity's anchor (first rect).
      -- Multi-line links get a single marker — the continuation lines aren't
      -- jump targets, so extra same-numbered markers were just clutter.
      n = n + 1
      local r = e.rects[1]
      if r then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, HYBRID_NS, r.cr0, 0, {
          virt_text = { { tostring(n % 10), 'HimalayaHybridLink' } },
          virt_text_win_col = r.cc0,
          priority = 4096,
        })
      end
    else
      -- text runs: a single purple marker at the start (one per run, to limit
      -- clutter), so plain text is also visibly indicated.
      local r = e.rects[1]
      if r then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, HYBRID_NS, r.cr0, 0, {
          virt_text = { { '•', 'HimalayaHybridTextMark' } },
          virt_text_win_col = r.cc0,
          priority = 4096,
        })
      end
    end
  end
end

--- Find the entity whose cell-rect contains buffer-cell (row, cell). row is the
--- 0-based buffer line; cell is the 0-based display column within the grid.
function M._hybrid_at(bufnr, row, cell)
  local mapped = hybrid_cells[bufnr]
  if not mapped then
    return nil
  end
  -- Cell rounding makes rects overlap on BOTH axes: a rect's bottom edge ceils
  -- into the next row (vertical neighbours) and its right edge ceils into the
  -- next column (horizontal neighbours). Any rect containing the cursor has
  -- cr0 <= row and cc0 <= cell, so the entity you're actually on is the one
  -- whose anchor (cr0, cc0) is the LATEST in reading order — largest cr0, then
  -- largest cc0. When the cursor sits exactly on a marker, that rect's anchor
  -- equals (row, cell), the maximum possible, so the marker always wins.
  -- Ties (same anchor) go to the smaller/more-specific rect.
  local best, besti
  for i, e in ipairs(mapped) do
    for _, r in ipairs(e.rects) do
      if row >= r.cr0 and row <= r.cr1 and cell >= r.cc0 and cell <= r.cc1 then
        local better
        if not best then
          better = true
        elseif r.cr0 ~= best.cr0 then
          better = r.cr0 > best.cr0
        elseif r.cc0 ~= best.cc0 then
          better = r.cc0 > best.cc0
        else
          better = ((r.cr1 - r.cr0) + (r.cc1 - r.cc0)) < ((best.cr1 - best.cr0) + (best.cc1 - best.cc0))
        end
        if better then
          best, besti = r, i
        end
      end
    end
  end
  if best then
    return mapped[besti], besti
  end
  return nil
end

--- Close the hover float for a buffer.
function M._hybrid_close_hover(bufnr)
  local h = hybrid_hover[bufnr]
  if h and h.win and vim.api.nvim_win_is_valid(h.win) then
    pcall(vim.api.nvim_win_close, h.win, true)
  end
  hybrid_hover[bufnr] = nil
end

--- Cursor-driven hover: show a float describing the entity under the cursor.
--- Only re-renders when the hovered entity CHANGES, so moving within one link
--- (or over non-link image) causes no window churn/flicker.
--- Decide what the preview should show for the current cursor position: a g/
--- search match (any type, with an [i/n] header) takes priority; else a link
--- (links-only hover stays calm over dense body text); else nothing.
function M._hybrid_hover_update(bufnr)
  if not hybrid_cells[bufnr] then
    return
  end
  local row = vim.fn.line('.') - 1
  local cell = vim.fn.virtcol('.') - 1
  local e, idx = M._hybrid_at(bufnr, row, cell)
  local s = hybrid_search[bufnr]
  if e and s and s.byidx and s.byidx[idx] then
    s.cur = s.byidx[idx]
    M._hybrid_show_preview(bufnr, e, idx, string.format('match %d/%d  "%s"', s.cur, #s.matches, s.query), s.query)
  elseif e then
    M._hybrid_show_preview(bufnr, e, idx, nil, nil) -- links and text both, so text is copyable
  else
    M._hybrid_close_hover(bufnr)
  end
end

--- Render (or update) the preview float for an entity, with an optional header
--- line (e.g. the g/ match counter) and an optional query to highlight in the
--- shown text. Reused in place across calls.
function M._hybrid_show_preview(bufnr, e, idx, header, query)
  local key = tostring(idx) .. '|' .. (header or '')
  local existing = hybrid_hover[bufnr]
  if existing and existing.key == key and existing.win and vim.api.nvim_win_is_valid(existing.win) then
    return -- already showing this exact content
  end
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    return
  end

  local win_w = vim.api.nvim_win_get_width(winid)
  local win_h = vim.api.nvim_win_get_height(winid)
  local wrap_w = math.max(1, win_w)

  -- Hard-wrap a string to <= wrap_w display cells per line (word-aware, with
  -- char-splitting for tokens longer than the width). REAL buffer lines, not
  -- soft wrap, so j/k/V behave per visual row. gy still copies the single-line
  -- original from the entity, so copy stays single-line.
  local function wrap_display(s)
    local out, cur = {}, ''
    local function wof(x)
      return vim.fn.strdisplaywidth(x)
    end
    for word in s:gmatch('%S+') do
      if wof(word) <= wrap_w then
        if cur == '' then
          cur = word
        elseif wof(cur) + 1 + wof(word) <= wrap_w then
          cur = cur .. ' ' .. word
        else
          out[#out + 1] = cur
          cur = word
        end
      else
        if cur ~= '' then
          out[#out + 1] = cur
        end
        local piece = ''
        for _, ch in ipairs(vim.fn.split(word, '\\zs')) do
          if piece ~= '' and wof(piece .. ch) > wrap_w then
            out[#out + 1] = piece
            piece = ch
          else
            piece = piece .. ch
          end
        end
        cur = piece
      end
    end
    if cur ~= '' then
      out[#out + 1] = cur
    end
    if #out == 0 then
      out = { '' }
    end
    return out
  end

  -- Content: optional header (g/ match counter), the text/alt label first, then
  -- the URL (colored), then a type-aware hint. URL/text hard-wrap into real
  -- lines; track each section's line indices for highlighting.
  local lines, header_line, url_lines, text_lines = {}, nil, {}, {}
  if header then
    lines[#lines + 1] = header
    header_line = #lines - 1
  end
  if e.text and #e.text > 0 then
    for _, l in ipairs(wrap_display(e.text)) do
      lines[#lines + 1] = l
      text_lines[#text_lines + 1] = #lines - 1
    end
  end
  if e.href and #e.href > 0 then
    for _, l in ipairs(wrap_display(e.href)) do
      lines[#lines + 1] = l
      url_lines[#url_lines + 1] = #lines - 1
    end
  end
  if #lines == (header and 1 or 0) then
    lines[#lines + 1] = '(no text)'
  end
  local q = (query and query ~= '') and query:lower() or nil
  if e.href and #e.href > 0 then
    lines[#lines + 1] = 'gx/<CR> open · gy copy · K scroll · q back'
  elseif header then
    lines[#lines + 1] = 'gy copy · n/N next · K scroll · q back'
  else
    lines[#lines + 1] = 'gy copy · K scroll · q back'
  end

  local function set_content(buf)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    pcall(vim.api.nvim_buf_clear_namespace, buf, HYBRID_NS, 0, -1)
    if header_line then
      pcall(vim.api.nvim_buf_set_extmark, buf, HYBRID_NS, header_line, 0, {
        end_row = header_line,
        end_col = #lines[header_line + 1],
        hl_group = 'HimalayaHybridMatch',
      })
    end
    for _, li in ipairs(url_lines) do
      pcall(vim.api.nvim_buf_set_extmark, buf, HYBRID_NS, li, 0, {
        end_row = li,
        end_col = #lines[li + 1],
        hl_group = 'HimalayaHybridUrl',
        priority = 100,
      })
    end
    -- Highlight per-line occurrences of the query in the URL/text lines (above
    -- the URL color via priority). A match split across a wrap boundary won't
    -- highlight — acceptable for the common single-word case.
    if q then
      local scan = {}
      for _, li in ipairs(url_lines) do
        scan[#scan + 1] = li
      end
      for _, li in ipairs(text_lines) do
        scan[#scan + 1] = li
      end
      for _, li in ipairs(scan) do
        local hay = lines[li + 1]:lower()
        local from = 1
        while true do
          local a, b = hay:find(q, from, true)
          if not a then
            break
          end
          pcall(vim.api.nvim_buf_set_extmark, buf, HYBRID_NS, li, a - 1, {
            end_row = li,
            end_col = b,
            hl_group = 'HimalayaHybridMatchText',
            priority = 200,
          })
          from = b + 1
        end
      end
    end
    vim.bo[buf].modifiable = false
  end
  -- Borderless panel (bg from NormalFloat keeps it distinct). FIXED height for a
  -- stable, non-jittery popup: it stays this size regardless of content length —
  -- shorter content shows a couple of blank rows, longer content scrolls (K).
  local cw = math.max(1, win_w)
  local HOVER_H = 4
  local height = math.max(1, math.min(HOVER_H, win_h - 1))
  -- Place so the panel doesn't cover the NODE (not just the cursor): a tall
  -- image link extends well below the cursor. Compute the node's window-row span
  -- (placeholder lines are 1:1 with screen rows) and prefer the side it doesn't
  -- reach. Reserve the window's last row so a bottom panel clears the statusline.
  local info = vim.fn.getwininfo(winid)[1]
  local topline = (info and info.topline) or 1
  local ntop0, nbot0 = math.huge, -1
  for _, r in ipairs(e.rects) do
    ntop0 = math.min(ntop0, r.cr0)
    nbot0 = math.max(nbot0, r.cr1)
  end
  local node_top = (ntop0 + 1) - topline -- 0-based window rows
  local node_bot = (nbot0 + 1) - topline
  local bottom_row = math.max(0, win_h - height - 1)
  local bottom_overlap = node_bot >= bottom_row
  local top_overlap = node_top <= (height - 1)
  -- Hysteresis: stay on the side the panel is already on as long as that side
  -- still clears the node, so it doesn't flip top<->bottom needlessly while you
  -- move between nodes. Only switch when the current side would cover the node.
  local cur_side = existing and existing.side
  local row, side
  if cur_side == 'top' and not top_overlap then
    row, side = 0, 'top'
  elseif cur_side == 'bottom' and not bottom_overlap then
    row, side = bottom_row, 'bottom'
  elseif not bottom_overlap then
    row, side = bottom_row, 'bottom'
  elseif not top_overlap then
    row, side = 0, 'top'
  else
    -- node fills both candidate areas — use the roomier side
    if node_top > (win_h - 1 - node_bot) then
      row, side = 0, 'top'
    else
      row, side = bottom_row, 'bottom'
    end
  end
  local fcfg = {
    relative = 'win',
    win = winid,
    anchor = 'NW',
    row = row,
    col = 0,
    width = cw,
    height = height,
    style = 'minimal',
    border = 'none',
    focusable = true,
    zindex = 200,
  }

  -- Reuse the existing float (update content + config) rather than close/reopen,
  -- so switching between links doesn't flicker or move the window.
  local cur = hybrid_hover[bufnr]
  if cur and cur.win and vim.api.nvim_win_is_valid(cur.win) and cur.buf and vim.api.nvim_buf_is_valid(cur.buf) then
    set_content(cur.buf)
    pcall(vim.api.nvim_win_set_config, cur.win, fcfg)
    cur.idx = idx
    cur.key = key
    cur.side = side
    return
  end

  local fbuf = vim.api.nvim_create_buf(false, true)
  set_content(fbuf)
  vim.bo[fbuf].bufhidden = 'wipe'
  -- q / <Esc> in the focused float just return to the email window (the popup
  -- stays while the cursor is still on the link; move off it to dismiss).
  local function leave_float()
    local w = vim.fn.bufwinid(bufnr)
    if w ~= -1 then
      pcall(vim.api.nvim_set_current_win, w)
    end
  end
  vim.keymap.set('n', 'q', leave_float, { buffer = fbuf, nowait = true, silent = true })
  vim.keymap.set('n', '<Esc>', leave_float, { buffer = fbuf, nowait = true, silent = true })
  -- gy/gx act on the entity the popup is showing (single-line text/href).
  local function focused_entity()
    local h = hybrid_hover[bufnr]
    return h and hybrid_cells[bufnr] and hybrid_cells[bufnr][h.idx] or nil
  end
  vim.keymap.set('n', 'gy', function()
    local fe = focused_entity()
    if fe then
      local target = fe.href or fe.text or ''
      vim.fn.setreg('+', target)
      vim.fn.setreg('"', target)
      vim.notify('hybrid: copied ' .. target:sub(1, 80))
    end
  end, { buffer = fbuf, nowait = true, silent = true })
  vim.keymap.set('n', 'gx', function()
    local fe = focused_entity()
    if fe and fe.href and #fe.href > 0 and vim.ui and vim.ui.open then
      vim.ui.open(fe.href)
    end
  end, { buffer = fbuf, nowait = true, silent = true })
  fcfg.noautocmd = true
  local ok, fwin = pcall(vim.api.nvim_open_win, fbuf, false, fcfg)
  if not ok then
    return
  end
  vim.wo[fwin].winhighlight = 'Normal:HimalayaHybridHover,EndOfBuffer:HimalayaHybridHover'
  vim.wo[fwin].wrap = false -- content is pre-wrapped into real lines
  hybrid_hover[bufnr] = { win = fwin, buf = fbuf, idx = idx, key = key, side = side }
end

--- Act on the entity under the cursor: 'open' (href via vim.ui.open) or 'copy'
--- (href/text to the + and " registers).
function M._hybrid_action(bufnr, kind)
  local row = vim.fn.line('.') - 1
  local cell = vim.fn.virtcol('.') - 1
  local e = M._hybrid_at(bufnr, row, cell)
  if not e then
    if kind == 'copy' then
      vim.notify('hybrid: no link under cursor', vim.log.levels.INFO)
    end
    return -- open with nothing under the cursor is a silent no-op
  end
  local target = e.href or e.text or ''
  if kind == 'open' then
    if e.href and #e.href > 0 and vim.ui and vim.ui.open then
      vim.ui.open(e.href)
    else
      vim.notify('hybrid: nothing to open', vim.log.levels.WARN)
    end
  else
    vim.fn.setreg('+', target)
    vim.fn.setreg('"', target)
    vim.notify('hybrid: copied ' .. target:sub(1, 80))
  end
end

--- Move the cursor to a buffer cell (row, cell are 0-based grid coords). The
--- placeholder cells are multi-byte, so convert the display column to a byte
--- column with virtcol2col (the inverse of virtcol used for lookups).
local function hybrid_goto_cell(bufnr, row, cell)
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    return
  end
  local lnum = row + 1
  local bytecol = vim.fn.virtcol2col(winid, lnum, cell + 1)
  pcall(vim.api.nvim_win_set_cursor, winid, { lnum, math.max(0, bytecol - 1) })
end

--- The full row span (top..bottom) of an entity across all its rects.
local function entity_rows(e)
  local top, bot = math.huge, -1
  for _, r in ipairs(e.rects) do
    top = math.min(top, r.cr0)
    bot = math.max(bot, r.cr1)
  end
  return top, bot
end

--- After jumping to an entity, scroll so its WHOLE extent is in view — a tall
--- image link is treated like a "word": you don't land on it half-cut. If it's
--- not fully visible, bring its top to the top of the window (showing the most
--- of it; for a short entity this just ensures it's fully on screen). Assumes
--- the cursor is already on the entity's top row.
local function hybrid_ensure_visible(bufnr, top0, bot0)
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    return
  end
  local info = vim.fn.getwininfo(winid)[1]
  if not info then
    return
  end
  local top, bot = top0 + 1, bot0 + 1
  local win_h = info.height
  local new_topline
  if top < info.topline then
    new_topline = top -- entity above view: scroll up just enough to reveal its top
  elseif bot > info.botline then
    -- entity below view: scroll down the minimum to reveal its bottom; if it
    -- fits this shows the whole thing low on screen (no jarring jump-to-top).
    -- Taller than the window: align its top (can't show all).
    new_topline = ((bot - top + 1) <= win_h) and (bot - win_h + 1) or top
  else
    return -- already fully visible: don't scroll at all
  end
  new_topline = math.max(1, new_topline)
  vim.api.nvim_win_call(winid, function()
    local so = vim.wo.scrolloff
    vim.wo.scrolloff = 0 -- honor the exact topline without re-centering
    local view = vim.fn.winsaveview()
    view.topline = new_topline
    vim.fn.winrestview(view)
    vim.wo.scrolloff = so
  end)
end

--- Node navigation (HimalayaHybridMode): jump the cursor between entity anchors
--- (each entity's first rect) instead of moving by cell. h/l = prev/next in
--- reading order; j/k = nearest node on a row below/above (closest column).
function M._hybrid_nav(bufnr, dir)
  local mapped = hybrid_cells[bufnr]
  if not mapped or #mapped == 0 then
    return
  end
  local nodes = {}
  for i, e in ipairs(mapped) do
    local r = e.rects[1]
    if r then
      nodes[#nodes + 1] = { row = r.cr0, cell = r.cc0, idx = i }
    end
  end
  table.sort(nodes, function(a, b)
    if a.row ~= b.row then
      return a.row < b.row
    end
    return a.cell < b.cell
  end)
  local crow = vim.fn.line('.') - 1
  local ccell = vim.fn.virtcol('.') - 1
  local target
  if dir == 'l' then
    for _, nd in ipairs(nodes) do
      if nd.row > crow or (nd.row == crow and nd.cell > ccell) then
        target = nd
        break
      end
    end
  elseif dir == 'h' then
    for i = #nodes, 1, -1 do
      local nd = nodes[i]
      if nd.row < crow or (nd.row == crow and nd.cell < ccell) then
        target = nd
        break
      end
    end
  elseif dir == 'j' or dir == 'k' then
    local best_row
    for _, nd in ipairs(nodes) do
      if dir == 'j' and nd.row > crow then
        best_row = best_row and math.min(best_row, nd.row) or nd.row
      elseif dir == 'k' and nd.row < crow then
        best_row = best_row and math.max(best_row, nd.row) or nd.row
      end
    end
    if best_row then
      local best_diff
      for _, nd in ipairs(nodes) do
        if nd.row == best_row then
          local d = math.abs(nd.cell - ccell)
          if not best_diff or d < best_diff then
            best_diff, target = d, nd
          end
        end
      end
    end
  end
  if target then
    hybrid_goto_cell(bufnr, target.row, target.cell)
    local e = mapped[target.idx]
    if e then
      hybrid_ensure_visible(bufnr, entity_rows(e))
    end
    pcall(M._hybrid_hover_update, bufnr)
  end
end

--- Toggle the hjkl node-navigation maps for a buffer.
function M._hybrid_set_nav(bufnr, on)
  for _, k in ipairs({ 'h', 'j', 'k', 'l' }) do
    if on then
      vim.keymap.set('n', k, function()
        M._hybrid_nav(bufnr, k)
      end, { buffer = bufnr, silent = true, nowait = true })
    else
      pcall(vim.keymap.del, 'n', k, { buffer = bufnr })
    end
  end
end

-- Generate n distinct labels of UNIFORM length from a key pool (home-row first),
-- so no label is a prefix of another.
local HINT_POOL = 'asdfghjklqwertyuiopzxcvbnm'
local function gen_labels(n)
  local chars = {}
  for c in HINT_POOL:gmatch('.') do
    chars[#chars + 1] = c
  end
  local out = {}
  if n <= #chars then
    for i = 1, n do
      out[i] = chars[i]
    end
  else
    for i = 1, #chars do
      for j = 1, #chars do
        out[#out + 1] = chars[i] .. chars[j]
        if #out >= n then
          return out
        end
      end
    end
  end
  return out
end

--- Hint-jump (f): label every VISIBLE node, read the typed label, jump to it.
function M._hybrid_hint(bufnr)
  local mapped = hybrid_cells[bufnr]
  if not mapped or #mapped == 0 then
    return
  end
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    return
  end
  local info = vim.fn.getwininfo(winid)[1]
  if not info then
    return
  end
  -- visible entities (anchor row within the viewport), in reading order
  local targets = {}
  for _, e in ipairs(mapped) do
    local r = e.rects[1]
    if r and (r.cr0 + 1) >= info.topline and (r.cr0 + 1) <= info.botline then
      targets[#targets + 1] = { e = e, row = r.cr0, cell = r.cc0 }
    end
  end
  if #targets == 0 then
    return
  end
  table.sort(targets, function(a, b)
    if a.row ~= b.row then
      return a.row < b.row
    end
    return a.cell < b.cell
  end)
  local labels = gen_labels(#targets)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, HYBRID_HINT_NS, 0, -1)
  for i, t in ipairs(targets) do
    t.label = labels[i]
    pcall(vim.api.nvim_buf_set_extmark, bufnr, HYBRID_HINT_NS, t.row, 0, {
      virt_text = { { t.label, 'HimalayaHybridHint' } },
      virt_text_win_col = t.cell,
      priority = 5000,
    })
  end
  vim.cmd('redraw')

  local function cleanup()
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, HYBRID_HINT_NS, 0, -1)
    vim.cmd('redraw')
  end
  local typed = ''
  while true do
    local ok, ch = pcall(vim.fn.getcharstr)
    if not ok or ch == '' or ch == '\27' then -- error / <Esc> / interrupt
      cleanup()
      return
    end
    typed = typed .. ch
    local exact, prefixes = nil, 0
    for _, t in ipairs(targets) do
      if t.label == typed then
        exact = t
      end
      if t.label:sub(1, #typed) == typed then
        prefixes = prefixes + 1
      end
    end
    if exact then
      cleanup()
      hybrid_goto_cell(bufnr, exact.row, exact.cell)
      hybrid_ensure_visible(bufnr, entity_rows(exact.e))
      pcall(M._hybrid_hover_update, bufnr)
      return
    end
    if prefixes == 0 then
      cleanup()
      return -- no label matches the typed prefix
    end
  end
end

--- Move to the next (dir=1) / previous (dir=-1) g/ match, wrapping. Feedback is
--- the preview panel itself (the cursor jump triggers it with an [i/n] header) —
--- no cmdline echo.
function M._hybrid_search_cycle(bufnr, dir)
  local s = hybrid_search[bufnr]
  if not s or #s.matches == 0 then
    vim.notify('hybrid: no active search (g/ to search)', vim.log.levels.INFO)
    return
  end
  local n = #s.matches
  s.cur = ((s.cur - 1 + dir) % n) + 1
  local m = s.matches[s.cur]
  hybrid_goto_cell(bufnr, m.row, m.cell)
  local e = (hybrid_cells[bufnr] or {})[m.idx]
  if e then
    hybrid_ensure_visible(bufnr, entity_rows(e))
  end
  pcall(M._hybrid_hover_update, bufnr)
end

--- g/ search: mark every entity whose text/href contains the query, sorted
--- top-to-bottom, and jump to the first. n/N cycle. Empty query clears.
function M._hybrid_search(bufnr, query)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, HYBRID_SEARCH_NS, 0, -1)
  hybrid_search[bufnr] = nil
  if not query or query == '' then
    return
  end
  local mapped = hybrid_cells[bufnr]
  if not mapped then
    vim.notify('hybrid: nothing to search yet')
    return
  end
  local q = query:lower()
  local matches = {}
  for i, e in ipairs(mapped) do
    local hay = ((e.text or '') .. ' ' .. (e.href or '')):lower()
    if hay:find(q, 1, true) then
      local r = e.rects[1]
      matches[#matches + 1] = { row = r.cr0, cell = r.cc0, idx = i }
    end
  end
  if #matches == 0 then
    vim.notify('hybrid: no match for "' .. query .. '"')
    return
  end
  table.sort(matches, function(a, b)
    if a.row ~= b.row then
      return a.row < b.row
    end
    return a.cell < b.cell
  end)
  local byidx = {}
  for pos, m in ipairs(matches) do
    byidx[m.idx] = pos -- entity index -> match position, for the [i/n] header
    pcall(vim.api.nvim_buf_set_extmark, bufnr, HYBRID_SEARCH_NS, m.row, 0, {
      virt_text = { { '✱', 'HimalayaHybridMatch' } },
      virt_text_win_col = m.cell,
      priority = 4097,
    })
  end
  hybrid_search[bufnr] = { matches = matches, cur = 0, query = query, byidx = byidx }
  M._hybrid_search_cycle(bufnr, 1)
end

--- Wire the hover autocmds + action/search keymaps for a buffer (idempotent).
function M._hybrid_attach(bufnr)
  if hybrid_aug[bufnr] then
    return
  end
  local grp = vim.api.nvim_create_augroup('HimalayaHybrid' .. bufnr, { clear = true })
  hybrid_aug[bufnr] = grp
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = grp,
    buffer = bufnr,
    callback = function()
      pcall(M._hybrid_hover_update, bufnr)
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufLeave', 'WinLeave' }, {
    group = grp,
    buffer = bufnr,
    callback = function()
      if hybrid_entering[bufnr] then
        return -- leaving to focus the float (K) — keep it open
      end
      M._hybrid_close_hover(bufnr)
    end,
  })
  local opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set('n', 'K', function()
    local h = hybrid_hover[bufnr]
    if h and h.win and vim.api.nvim_win_is_valid(h.win) then
      hybrid_entering[bufnr] = true -- suppress the leave auto-close for this hop
      pcall(vim.api.nvim_set_current_win, h.win)
      hybrid_entering[bufnr] = false
    end
  end, opts)
  vim.keymap.set('n', 'gx', function()
    M._hybrid_action(bufnr, 'open')
  end, opts)
  vim.keymap.set('n', '<CR>', function()
    M._hybrid_action(bufnr, 'open')
  end, opts)
  vim.keymap.set('n', 'gy', function()
    M._hybrid_action(bufnr, 'copy')
  end, opts)
  vim.keymap.set('n', 'g/', function()
    vim.ui.input({ prompt = 'Email search: ' }, function(input)
      if input == nil then
        return
      end
      M._hybrid_search(bufnr, input)
    end)
  end, opts)
  -- n/N cycle email-search matches. Native n/N over the placeholder text is
  -- meaningless (it's image-encoding gibberish), so repurposing them here is safe.
  vim.keymap.set('n', 'n', function()
    M._hybrid_search_cycle(bufnr, 1)
  end, opts)
  vim.keymap.set('n', 'N', function()
    M._hybrid_search_cycle(bufnr, -1)
  end, opts)
  -- <Esc> clears the active search (markers + state) and closes the popup.
  vim.keymap.set('n', '<Esc>', function()
    M._hybrid_search(bufnr, '')
    M._hybrid_close_hover(bufnr)
  end, opts)
  -- f: hint-jump — label every visible node, type the label to open/copy it.
  vim.keymap.set('n', 'f', function()
    M._hybrid_hint(bufnr)
  end, opts)

  -- Node navigation (hjkl jump between nodes) is on by default for image
  -- buffers; :HimalayaHybridMode toggles it off for cell-wise movement.
  if not hybrid_nav_on[bufnr] then
    hybrid_nav_on[bufnr] = true
    M._hybrid_set_nav(bufnr, true)
  end
end

--- Tear down hover autocmds, keymaps, search marks, and any open float.
function M._hybrid_detach(bufnr)
  M._hybrid_close_hover(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, HYBRID_SEARCH_NS, 0, -1)
  hybrid_search[bufnr] = nil
  if hybrid_aug[bufnr] then
    pcall(vim.api.nvim_del_augroup_by_id, hybrid_aug[bufnr])
    hybrid_aug[bufnr] = nil
  end
  hybrid_entering[bufnr] = nil
  if hybrid_nav_on[bufnr] then
    M._hybrid_set_nav(bufnr, false)
    hybrid_nav_on[bufnr] = nil
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, HYBRID_HINT_NS, 0, -1)
  for _, k in ipairs({ 'gx', '<CR>', 'gy', 'g/', 'n', 'N', 'K', '<Esc>', 'f' }) do
    pcall(vim.keymap.del, 'n', k, { buffer = bufnr })
  end
end

function M._display(image, bufnr, winid, png_path, plog)
  local cfg = config.get()
  local rh = cfg.render_html or {}
  if rh.placeholders then
    M._show_image_placeholders(image, bufnr, winid, png_path, plog)
  elseif rh.chunked then
    M._show_image_chunked(image, bufnr, winid, png_path, plog)
  else
    M._show_image(image, bufnr, winid, png_path, plog)
  end
end

--- Toggle between image and text view of the current email.
function M.toggle()
  if vim.b.himalaya_image_rendered then
    M.clear()
  else
    M.render()
  end
end

--- Open the rendered email PNG in the system's default app (image viewer), for
--- verifying the inline render against the source image at full resolution.
--- Renders first if no PNG exists yet for this buffer.
function M.open_in_app()
  local function open(path)
    if path and vim.fn.filereadable(path) == 1 then
      vim.ui.open(path)
      return true
    end
    return false
  end

  if open(vim.b.himalaya_image_png) then
    return
  end

  -- No PNG yet: render, then open it once the buffer var is set.
  local bufnr = vim.api.nvim_get_current_buf()
  M.render()
  local tries = 0
  local timer = vim.uv.new_timer()
  timer:start(
    150,
    150,
    vim.schedule_wrap(function()
      tries = tries + 1
      local png = vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].himalaya_image_png or nil
      if open(png) or tries > 40 then
        timer:stop()
        timer:close()
        if tries > 40 then
          log.err('image render timed out; nothing to open')
        end
      end
    end)
  )
end

--- Toggle the default image mode and render/clear the current email accordingly.
--- When image_mode is enabled, newly opened emails auto-render as images.
function M.toggle_mode()
  local cfg = config.get()
  if not cfg.render_html then
    cfg.render_html = {}
  end
  cfg.render_html.image_mode = not cfg.render_html.image_mode
  local mode = cfg.render_html.image_mode

  local has_email = vim.b.himalaya_current_email_id and vim.b.himalaya_current_email_id ~= ''

  if mode then
    log.info('Image mode ON — emails will render as images by default')
    if has_email and not vim.b.himalaya_image_rendered then
      M.render()
    end
  else
    log.info('Image mode OFF — emails will show as text by default')
    if has_email and vim.b.himalaya_image_rendered then
      M.clear()
    end
  end
end

--- Render the current email's HTML as an image via image.nvim.
function M.render()
  local ok_img, image = pcall(require, 'image')
  if not ok_img then
    log.err('image.nvim is not installed — required for HTML image rendering')
    return
  end

  local cfg = config.get()
  local bin = cfg.render_html and cfg.render_html.binary
  if not bin then
    log.err('render_html.binary is not configured')
    return
  end

  if vim.fn.executable(bin) ~= 1 then
    log.err(bin .. ' is not installed or not in PATH')
    return
  end

  local email_id = vim.b.himalaya_current_email_id
  if not email_id or email_id == '' then
    log.warn('No email ID found in this buffer')
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()

  -- Fast path: if we already rendered this email, reuse the cached PNG.
  local cached_png = vim.b[bufnr].himalaya_image_png
  if cached_png and vim.fn.filereadable(cached_png) == 1 then
    M._display(image, bufnr, winid, cached_png)
    return
  end

  local account, folder = context.resolve(bufnr)
  local account_flag = account_state.flag(account)

  -- Cancel any prior in-flight render for this buffer.
  local gen = (render_gen[bufnr] or 0) + 1
  render_gen[bufnr] = gen

  -- Show "Loading…" in winbar while rendering; save original for restore.
  -- Use the stored original if one exists (avoids stacking "Loading…").
  local orig_winbar = vim.b[bufnr].himalaya_original_winbar or vim.wo[winid].winbar or ''
  vim.b[bufnr].himalaya_original_winbar = orig_winbar
  vim.wo[winid].winbar = orig_winbar .. ' Loading…'

  local t0 = vim.uv.hrtime()
  local function elapsed()
    return (vim.uv.hrtime() - t0) / 1e6
  end
  local tag = string.format('email=%s gen=%d buf=%d', email_id, gen, bufnr)
  local function plog(msg)
    local f = io.open('/tmp/himalaya-image-perf.log', 'a')
    if f then
      f:write(string.format('[%s] [+%7.1fms] [%s] %s\n', os.date('%H:%M:%S'), elapsed(), tag, msg))
      f:close()
    end
  end
  plog('START render')

  local function restore_winbar()
    if vim.api.nvim_win_is_valid(winid) then
      vim.wo[winid].winbar = orig_winbar
    end
  end

  --- Check if this render has been superseded (new render started, or
  --- buffer now shows a different email).  Safe to call from fast event
  --- contexts — only reads the generation counter, no nvim API calls.
  local function is_stale()
    if render_gen[bufnr] ~= gen then
      plog('render cancelled: superseded by newer render')
      return true
    end
    return false
  end

  --- Like is_stale() but also checks the buffer's current email_id.
  --- Must only be called from vim.schedule (main loop), not from
  --- libuv/websocket callbacks.
  local function is_stale_scheduled()
    if is_stale() then
      return true
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return true
    end
    if vim.b[bufnr].himalaya_current_email_id ~= email_id then
      plog('render cancelled: email changed to ' .. tostring(vim.b[bufnr].himalaya_current_email_id))
      return true
    end
    return false
  end

  -- Core rendering pipeline: HTML injection → Chrome CDP → display.
  -- Called with the tmpdir that already contains exported HTML files.
  local function do_render(tmpdir)
    -- Clean up images via image.nvim API when the buffer is wiped,
    -- then defer tmpdir deletion so the PNG isn't removed while
    -- image.nvim is still processing.
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = bufnr,
      once = true,
      callback = function()
        local ok, img_api = pcall(require, 'image')
        if ok then
          local images = img_api.get_images({ buffer = bufnr })
          for _, img in ipairs(images) do
            img:clear()
          end
        end
        vim.defer_fn(function()
          vim.fn.delete(tmpdir, 'rf')
        end, 200)
      end,
    })

    -- Find the exported HTML file.
    local html_files = vim.fn.glob(tmpdir .. '/*.html', false, true)
    if #html_files == 0 then
      restore_winbar()
      return
    end
    local html_path = html_files[1]
    local png_path = tmpdir .. '/email.png'

    -- Pre-set filler lines so textoff (line-number column width) stabilises
    -- before we read it.  The email text may have 100+ lines (3-digit
    -- numbers, textoff=6) but image.nvim will render after _show_image
    -- replaces them with ~30-80 filler lines (2-digit, textoff=5).
    -- Without this, the PNG width can be off by one cell_width.
    local prelim_filler = {}
    for i = 1, 99 do
      prelim_filler[i] = ''
    end
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, prelim_filler)
    vim.bo[bufnr].modifiable = false

    local win_width = vim.api.nvim_win_get_width(winid)
    local dpr = cfg.render_html.device_scale_factor or 2
    local ppc = cfg.render_html.pixels_per_column or 8
    local zoom = cfg.render_html.zoom or 100
    local viewport_width = win_width * ppc

    -- Compute the CSS layout width (the width the headless browser lays the
    -- email out at). The on-screen display area is fixed at display_cols *
    -- cell_width pixels; the placeholder/image path scales the capture to fit
    -- it. So the CSS layout width controls how big the email content appears:
    --   layout == display width  -> content shown 1:1            (zoom 100)
    --   layout <  display width  -> content magnified to fill    (zoom > 100)
    --   layout >  display width  -> content shrunk, more fits     (zoom < 100)
    -- i.e. magnification = display_width / layout = zoom/100, so
    -- layout = display_width * 100 / zoom. device_scale_factor is independent:
    -- it's the capture supersample factor (PNG = layout * dpr, downscaled to
    -- the display width), purely for sharpness — it does NOT affect size.
    local ok_ts, term_size = pcall(function()
      return require('image.utils.term').get_size()
    end)
    if ok_ts and term_size and term_size.cell_width and term_size.cell_width > 0 then
      local textoff = vim.fn.getwininfo(winid)[1].textoff or 0
      local display_cols = win_width - textoff
      local display_width = display_cols * term_size.cell_width
      viewport_width = math.floor(display_width * 100 / math.max(1, zoom) + 0.5)
    end

    -- Prepare measurement HTML: inject a small snippet that hides
    -- the scrollbar and reports scrollHeight via a data attribute.
    -- The snippet lives in measure_inject.html next to this file.
    local measure_html = tmpdir .. '/measure.html'
    local hf = io.open(html_path, 'r')
    local html_content = hf:read('*a')
    hf:close()

    local inject_path = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h') .. '/measure_inject.html'
    local inf = io.open(inject_path, 'r')
    local inject = inf and inf:read('*a') or ''
    if inf then
      inf:close()
    end

    -- Log content fingerprint to verify we're rendering the right email
    local title = html_content:match('<title>(.-)</title>') or '(no title)'
    local subject = html_content:match('<th>Subject</th>.-<td>(.-)</td>') or html_content:sub(1, 120)
    plog(string.format('HTML fingerprint: title=%q subject=%q len=%d', title, subject, #html_content))

    local modified = html_content:gsub('</body>', inject .. '</body>')
    local mf = io.open(measure_html, 'w')
    mf:write(modified)
    mf:close()
    plog('HTML injection done')

    local max_height = cfg.render_html.max_screenshot_height or 5000

    local function show_image()
      if is_stale_scheduled() then
        restore_winbar()
        return
      end
      -- DEBUG: copy PNG to persistent location for inspection
      local debug_dir = '/tmp/himalaya-debug-pngs'
      vim.fn.mkdir(debug_dir, 'p')
      local debug_path = string.format('%s/email_%s_gen%d.png', debug_dir, email_id, gen)
      vim.uv.fs_copyfile(png_path, debug_path)
      plog(string.format('image.nvim from_file start (png=%s, debug_copy=%s)', png_path, debug_path))
      M._display(image, bufnr, winid, png_path, plog)
    end

    -- Trim trailing uniform background below the visible content, keeping the
    -- full width and the top (leading) untouched, then show. Email HTML
    -- routinely makes the document taller than what's visible — invisible
    -- tracking pixels / spacer images appended after the content, viewport-fill
    -- wrappers (height="100%"/100vh), trailing margins — which inflate the
    -- measured height (sometimes all the way to the cap). Trimming the rendered
    -- *pixels* is the general fix: the height then matches what a browser
    -- visually shows, regardless of the cause.
    --
    -- Only the BOTTOM is trimmed: leading space at the top is usually the
    -- email's intended margin (and is visible in a real browser), whereas the
    -- dead space is always trailing. Horizontal layout is left untouched.
    -- `src` is the freshly-written PNG; we trim it in place then atomically
    -- move it onto png_path. The move is the only mutation of png_path, so a
    -- concurrent read (e.g. a scroll re-render in image.nvim, or a progressive
    -- second pass) always sees a complete file — never a half-written one.
    local function trim_then_show(src, after)
      local function finish()
        if src ~= png_path then
          local ok, err = os.rename(src, png_path)
          if not ok then
            plog('atomic rename failed (' .. tostring(err) .. '); copying instead')
            pcall(vim.uv.fs_copyfile, src, png_path)
            pcall(os.remove, src)
          end
        end
        show_image()
        if after then
          after()
        end
      end
      if vim.fn.executable('magick') ~= 1 then
        finish()
        return
      end
      plog('trim: probe magick start')
      vim.system({ 'magick', src, '-fuzz', '3%', '-format', '%w %h|%@', 'info:' }, { text = true }, function(probe)
        vim.schedule(function()
          -- "%w %h|%@" -> "FULLW FULLH|TRIMWxTRIMH+TX+TY"
          local fullw, fullh, th, ty = (probe.stdout or ''):match('(%d+)%s+(%d+)|%d+x(%d+)%+%d+%+(%d+)')
          plog(string.format('trim: probe done (bbox=%s)', (probe.stdout or ''):gsub('%s+', ' ')))
          if not th then
            finish()
            return
          end
          -- Keep everything from the top down to the last visible row.
          local content_bottom = tonumber(ty) + tonumber(th)
          -- Bail on a degenerate trim (blank image) or when there's nothing to
          -- cut (content already reaches the bottom).
          if content_bottom < 16 or content_bottom >= tonumber(fullh) then
            finish()
            return
          end
          vim.system(
            { 'magick', src, '-crop', fullw .. 'x' .. content_bottom .. '+0+0', '+repage', src },
            { text = true },
            function(crop)
              vim.schedule(function()
                if crop.code ~= 0 then
                  plog('content trim failed; using untrimmed image')
                else
                  plog(string.format('content trim -> %sx%s (was %sx%s)', fullw, content_bottom, fullw, fullh))
                end
                finish()
              end)
            end
          )
        end)
      end)
    end

    local render_fallback -- forward declaration for CDP fallback

    --- Poll document.readyState until 'complete', then call callback.
    --- Avoids relying on Page.loadEventFired which can fire spuriously
    --- (e.g. when setDeviceMetricsOverride triggers a page reload).
    -- ~3s at 50ms/poll. Emails reach 'complete' in well under a second; a much
    -- longer wait only happens when a remote resource hangs (commonly a
    -- tracking pixel whose server never responds), which blocks 'complete'
    -- forever. We cap the wait and then PROCEED to screenshot the DOM as-is
    -- rather than erroring — erroring triggers the one-shot chrome fallback,
    -- which waits on the same hang for ~20s.
    local LOAD_POLL_CAP = 60
    local function wait_for_load(client, callback)
      local attempts = 0
      local function poll()
        attempts = attempts + 1
        if is_stale() then
          return
        end
        client:send('Runtime.evaluate', {
          expression = 'document.readyState',
          returnByValue = true,
        }, function(err, result)
          if err then
            callback('evaluate readyState failed: ' .. tostring(err))
            return
          end
          local state = result and result.result and result.result.value
          if state == 'complete' then
            plog(string.format('CDP: page ready (complete) after %d polls', attempts))
            callback(nil)
          elseif attempts >= LOAD_POLL_CAP then
            -- Not 'complete' in time — almost always a slow/hung remote
            -- resource. The DOM is parsed and laid out, so screenshot what's
            -- there. Proceed (callback succeeds), do NOT fall back.
            plog(
              string.format(
                'CDP: not complete after %d polls (state=%s) — proceeding to screenshot',
                attempts,
                tostring(state)
              )
            )
            callback(nil)
          else
            -- Poll again after a short delay (50ms)
            local timer = vim.uv.new_timer()
            timer:start(50, 0, function()
              timer:close()
              poll()
            end)
          end
        end)
      end
      poll()
    end

    --- Render via CDP (Chrome daemon). Falls back to vim.system on failure.
    local function render_cdp()
      local chrome = require('himalaya.domain.email.chrome')
      plog('CDP: getting client')
      chrome.get_client(function(err, client)
        if is_stale() then
          return
        end
        if err then
          plog('CDP client failed: ' .. tostring(err) .. ', falling back to vim.system')
          vim.schedule(function()
            render_fallback()
          end)
          return
        end

        plog(string.format('CDP: setDeviceMetrics (viewport=%dx%d dpr=%d)', viewport_width, max_height, dpr))
        client:send('Emulation.setDeviceMetricsOverride', {
          width = viewport_width,
          height = max_height,
          deviceScaleFactor = dpr,
          mobile = false,
        }, function(metrics_err)
          if is_stale() then
            return
          end
          if metrics_err then
            plog('CDP setDeviceMetrics failed: ' .. tostring(metrics_err))
            vim.schedule(function()
              render_fallback()
            end)
            return
          end

          -- Dark mode: have Chrome report prefers-color-scheme: dark so the email
          -- renders its OWN dark theme (no invert hack). Sent before navigate;
          -- CDP processes commands in order, so it applies to the loaded page.
          if cfg.render_html.dark then
            plog('CDP: emulating prefers-color-scheme: dark')
            client:send('Emulation.setEmulatedMedia', {
              features = { { name = 'prefers-color-scheme', value = 'dark' } },
            }, function() end)
          end

          plog('CDP: navigating to ' .. measure_html)
          client:send('Page.navigate', {
            url = 'file://' .. measure_html,
          }, function(nav_err, nav_result)
            if is_stale() then
              return
            end
            if nav_err then
              plog('CDP navigate failed: ' .. tostring(nav_err))
              vim.schedule(function()
                render_fallback()
              end)
              return
            end
            plog('CDP: navigate acknowledged, frameId=' .. tostring(nav_result and nav_result.frameId))

            -- One capture pass: measure height, (resize), screenshot, trim,
            -- show, then on_done(). on_done lets the progressive second pass
            -- start only after the first fully completes (no overlap on the
            -- shared PNG path).
            local function capture(pass_dpr, on_done)
              plog('CDP: measuring content height (pass_dpr=' .. tostring(pass_dpr) .. ')')
              -- Measure content height robustly.  We collect multiple
              -- measurements because email HTML often has body/html
              -- stretching to fill the viewport (height:100% etc.).
              -- The most reliable is the max bottom of direct body
              -- children, which ignores body/html CSS entirely.
              local measure_js = '(function(){'
                .. 'var b=document.body,h=document.documentElement,'
                .. 'ch=b.children,m=0;'
                .. 'for(var i=0;i<ch.length;i++){'
                .. 'var r=ch[i].getBoundingClientRect();'
                .. 'if(r.bottom>m)m=r.bottom}'
                .. 'var cs=getComputedStyle(b);'
                .. 'm+=parseFloat(cs.paddingBottom)+parseFloat(cs.marginBottom);'
                .. 'return JSON.stringify({'
                .. 'childrenBottom:Math.ceil(m),'
                .. 'scrollHeight:b.scrollHeight,'
                .. 'bodyRect:Math.ceil(b.getBoundingClientRect().height),'
                .. 'dataSh:h.getAttribute("data-sh")'
                .. '})})()'
              client:send('Runtime.evaluate', {
                expression = measure_js,
                returnByValue = true,
              }, function(eval_err, eval_result)
                if is_stale() then
                  return
                end
                if eval_err then
                  plog('CDP evaluate failed: ' .. tostring(eval_err))
                  vim.schedule(function()
                    render_fallback()
                  end)
                  return
                end

                local raw = eval_result.result.value
                local ok_json, measures = pcall(vim.json.decode, raw or '')
                if not ok_json then
                  measures = {}
                end
                plog(
                  string.format(
                    'CDP: measures childrenBottom=%s scrollHeight=%s bodyRect=%s dataSh=%s',
                    tostring(measures.childrenBottom),
                    tostring(measures.scrollHeight),
                    tostring(measures.bodyRect),
                    tostring(measures.dataSh)
                  )
                )

                -- Pick the best measurement: childrenBottom (ignores
                -- body CSS), then dataSh, then bodyRect, then scrollHeight.
                local content_height = measures.childrenBottom
                if not content_height or content_height < 1 then
                  content_height = tonumber(measures.dataSh)
                end
                if not content_height or content_height < 1 then
                  content_height = measures.bodyRect
                end
                if not content_height or content_height < 1 then
                  content_height = measures.scrollHeight
                end
                if not content_height or content_height < 1 then
                  content_height = max_height
                end
                plog(string.format('CDP: content_height=%d, capturing screenshot', content_height))

                local function take_screenshot()
                  client:send('Page.captureScreenshot', {
                    format = 'png',
                    clip = {
                      x = 0,
                      y = 0,
                      width = viewport_width,
                      height = content_height,
                      scale = 1,
                    },
                  }, function(ss_err, ss_result)
                    if is_stale() then
                      return
                    end
                    if ss_err or not ss_result or not ss_result.data then
                      plog('CDP captureScreenshot failed: ' .. tostring(ss_err))
                      vim.schedule(function()
                        render_fallback()
                      end)
                      return
                    end

                    plog('CDP: screenshot captured, decoding base64')
                    local png_data = vim.base64.decode(ss_result.data)
                    -- Write to a temp work file, not png_path directly: a second
                    -- (progressive) pass must not overwrite the png image.nvim is
                    -- actively reading — trim_then_show atomically renames this
                    -- onto png_path so concurrent reads never see a partial file.
                    local work = png_path .. '.work'
                    local f = io.open(work, 'wb')
                    if not f then
                      plog('CDP: failed to write PNG')
                      vim.schedule(function()
                        render_fallback()
                      end)
                      return
                    end
                    f:write(png_data)
                    f:close()
                    plog('CDP: PNG written, displaying')

                    vim.schedule(function()
                      trim_then_show(work, on_done)
                    end)
                  end)
                end

                -- Resize the viewport to the actual content height (so the page
                -- lays out at the correct size, avoiding shift when body
                -- stretches to fill an oversized viewport) AND apply this pass's
                -- device scale factor. The CSS width (viewport_width) is fixed
                -- across passes so the layout is identical between them; only the
                -- resolution changes — the progressive first pass renders at a
                -- lower dpr (blurry preview, far fewer PNG bytes to transmit and a
                -- faster capture), the final pass at full dpr (sharp).
                local cap_h = math.min(content_height, max_height)
                plog(string.format('CDP: setDeviceMetrics for capture %dx%d dpr=%d', viewport_width, cap_h, pass_dpr))
                client:send('Emulation.setDeviceMetricsOverride', {
                  width = viewport_width,
                  height = cap_h,
                  deviceScaleFactor = pass_dpr,
                  mobile = false,
                }, function(resize_err)
                  if is_stale() then
                    return
                  end
                  if resize_err then
                    plog('CDP viewport resize failed, screenshotting at original size')
                  end
                  -- Hybrid layer: extract the entity boxes from the settled,
                  -- full-res layout (final pass only) before the screenshot.
                  -- Never blocks — it always proceeds to take_screenshot.
                  if cfg.render_html.hybrid and pass_dpr == dpr then
                    M._hybrid_extract(client, bufnr, viewport_width, plog, take_screenshot)
                  else
                    take_screenshot()
                  end
                end)
              end)
            end

            -- Run capture when the page is ready. Progressive (toggle): first
            -- paint at 'interactive', then a refined pass at 'complete'/cap.
            -- Serialized so the final pass never overlaps the first.
            if cfg.render_html.progressive then
              -- First (interactive) pass renders at a reduced scale factor for a
              -- cheap blurry preview; the final pass renders at full dpr. Clamp
              -- to [1, dpr] so a preview >= dpr is just a no-op (preview == final).
              local preview_dpr = math.max(1, math.min(cfg.render_html.preview_scale_factor or 1, dpr))
              local first_started, final_started, busy, final_pending = false, false, false, false
              local function start_final()
                if final_started then
                  return
                end
                if busy then
                  final_pending = true
                  return
                end
                final_started = true
                plog('CDP: progressive final pass')
                capture(dpr, nil)
              end
              local attempts = 0
              local function poll()
                attempts = attempts + 1
                if is_stale() then
                  return
                end
                client:send(
                  'Runtime.evaluate',
                  { expression = 'document.readyState', returnByValue = true },
                  function(poll_err, result)
                    if is_stale() then
                      return
                    end
                    local state = (not poll_err) and result and result.result and result.result.value or nil
                    if not first_started and (state == 'interactive' or state == 'complete') then
                      first_started = true
                      if state == 'complete' then
                        final_started = true -- first paint IS the final
                      end
                      busy = true
                      -- If the page is already 'complete' on the first poll there
                      -- is no second pass, so render the first paint at full dpr.
                      local first_dpr = (state == 'complete') and dpr or preview_dpr
                      plog('CDP: progressive first paint (state=' .. tostring(state) .. ' dpr=' .. first_dpr .. ')')
                      capture(first_dpr, function()
                        busy = false
                        if final_pending then
                          start_final()
                        end
                      end)
                    end
                    if err or state == 'complete' then
                      if state == 'complete' then
                        plog('CDP: complete after ' .. attempts .. ' polls')
                      end
                      start_final()
                    elseif attempts >= LOAD_POLL_CAP then
                      plog('CDP: load cap reached (state=' .. tostring(state) .. ') — finalizing')
                      start_final()
                    else
                      local timer = vim.uv.new_timer()
                      timer:start(50, 0, function()
                        timer:close()
                        poll()
                      end)
                    end
                  end
                )
              end
              poll()
            else
              wait_for_load(client, function()
                if is_stale() then
                  return
                end
                capture(dpr, nil)
              end)
            end
          end)
        end)
      end)
    end

    --- Fallback: spawn Chrome as a one-shot process (original approach).
    render_fallback = function()
      plog(string.format('fallback: chrome start (viewport=%dx%d dpr=%d)', viewport_width, max_height, dpr))
      vim.system({
        bin,
        '--disable-gpu',
        '--no-sandbox',
        '--force-device-scale-factor=' .. dpr,
        -- Bound the wait: without this, a hung remote resource (e.g. a tracking
        -- pixel whose server never responds) makes Chrome block on load for
        -- ~20s. virtual-time advances regardless, so we capture what's there.
        '--virtual-time-budget=5000',
        '--dump-dom',
        '--screenshot=' .. png_path,
        '--window-size=' .. viewport_width .. ',' .. max_height,
        'file://' .. measure_html,
      }, { text = true }, function(result)
        vim.schedule(function()
          if is_stale_scheduled() then
            restore_winbar()
            return
          end
          if result.code ~= 0 then
            local fallback_err = (result.stderr or ''):match('^[^\n]+') or 'unknown error'
            log.err('Converter failed: ' .. fallback_err)
            restore_winbar()
            return
          end

          if vim.fn.filereadable(png_path) ~= 1 then
            log.err('Converter produced no output at ' .. png_path)
            restore_winbar()
            return
          end

          local content_height = max_height
          if result.stdout then
            local h = result.stdout:match('data%-sh="(%d+)"')
            if h then
              content_height = tonumber(h)
            end
          end
          plog(string.format('fallback: chrome done (content_height=%s)', tostring(content_height)))

          if content_height < max_height then
            local pixel_height = content_height * dpr
            plog(string.format('fallback: magick crop (height=%dpx)', pixel_height))
            vim.system({
              'magick',
              png_path,
              '-crop',
              '0x' .. pixel_height .. '+0+0',
              '+repage',
              png_path,
            }, { text = true }, function(crop_result)
              vim.schedule(function()
                plog('fallback: magick crop done')
                if crop_result.code ~= 0 then
                  log.warn('magick crop failed, using uncropped image')
                end
                trim_then_show(png_path)
              end)
            end)
          else
            trim_then_show(png_path)
          end
        end)
      end)
    end

    render_cdp()
  end

  -- Start a fresh export (fallback when no pre-fetch is available).
  local function fresh_export()
    plog('no pre-fetch, starting fresh export')
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, 'p')
    request.plain({
      cmd = 'message export %s --folder %q -d %q %s',
      args = { account_flag, folder, tmpdir, email_id },
      msg = 'Exporting email HTML',
      on_data = function()
        plog('himalaya export done')
        do_render(tmpdir)
      end,
    })
  end

  -- Use pre-fetched export if available, wait if in-progress, else fresh.
  local state = prefetch_state[bufnr]
  if state and state.done and state.ok then
    prefetch_state[bufnr] = nil
    plog(
      string.format('using pre-fetched export (prefetch_email=%s, tmpdir=%s)', tostring(state.email_id), state.tmpdir)
    )
    if state.email_id ~= email_id then
      plog(
        string.format('WARNING: prefetch email_id mismatch! prefetch=%s render=%s', tostring(state.email_id), email_id)
      )
    end
    do_render(state.tmpdir)
  elseif state and not state.done then
    plog(
      string.format(
        'waiting for in-progress pre-fetch (prefetch_email=%s, tmpdir=%s)',
        tostring(state.email_id),
        state.tmpdir
      )
    )
    if state.email_id ~= email_id then
      plog(
        string.format('WARNING: prefetch email_id mismatch! prefetch=%s render=%s', tostring(state.email_id), email_id)
      )
    end
    table.insert(state.callbacks, function(s)
      -- Only clear if the slot still belongs to this prefetch;
      -- a newer prefetch may have replaced it already.
      if prefetch_state[bufnr] == s then
        prefetch_state[bufnr] = nil
      end
      if is_stale_scheduled() then
        plog('pre-fetch callback: stale, bailing')
        restore_winbar()
        return
      end
      if s.ok then
        plog(string.format('pre-fetch completed (prefetch_email=%s)', tostring(s.email_id)))
        do_render(s.tmpdir)
      else
        fresh_export()
      end
    end)
  else
    fresh_export()
  end
end

--- Clear the rendered image and restore text view.
--- @param bufnr? number  Buffer to clear (defaults to current)
function M.clear(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Clear via image.nvim API so its internal state stays consistent
  -- (enables proper re-render on focus/zoom and prevents WinResized
  -- from re-rendering a deleted image).
  local ok_img, image = pcall(require, 'image')
  if ok_img then
    local images = image.get_images({ buffer = bufnr })
    for _, img in ipairs(images) do
      img:clear()
    end
  end

  -- Restore saved buffer content.
  local saved_lines = vim.b[bufnr].himalaya_saved_lines
  if saved_lines then
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, saved_lines)
    vim.bo[bufnr].modifiable = false
    vim.b[bufnr].himalaya_saved_lines = nil
  end

  -- Tear down a unicode-placeholder render: delete the terminal image and drop
  -- the placeholder extmark highlights (the saved-lines restore above already
  -- replaced the placeholder text).
  local st = ph_state[bufnr]
  if st then
    ph_delete(st.id)
    ph_state[bufnr] = nil
  end
  vim.b[bufnr].himalaya_ph_id = nil
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, vim.api.nvim_create_namespace('himalaya_ph'), 0, -1)

  -- Drop the hybrid entity layer + debug overlay + hover for this buffer.
  M._hybrid_detach(bufnr)
  hybrid_raw[bufnr] = nil
  hybrid_cells[bufnr] = nil
  hybrid_dots_on[bufnr] = nil
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, HYBRID_NS, 0, -1)

  vim.b[bufnr].himalaya_image_rendered = false
  vim.b[bufnr].himalaya_chunk_count = nil
  M._clear_image_scroll_maps(bufnr)

  -- Restore original winbar.
  local winid = vim.fn.bufwinid(bufnr)
  local original = vim.b[bufnr].himalaya_original_winbar
  if original and winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
    vim.wo[winid].winbar = original
    vim.b[bufnr].himalaya_original_winbar = nil
  end
end

-- Hybrid debug commands (Phase 0): toggle the alignment dots / dump the
-- extracted entities. Registered once. No effect unless render_html.hybrid is
-- on AND an email image has been rendered in the current buffer.
if not M._hybrid_cmds_done then
  M._hybrid_cmds_done = true
  pcall(vim.api.nvim_set_hl, 0, 'HimalayaHybridLink', { fg = '#000000', bg = '#7dcfff', bold = true })
  pcall(vim.api.nvim_set_hl, 0, 'HimalayaHybridMatch', { fg = '#000000', bg = '#ffc777', bold = true })
  -- Hover panel inherits the theme's float colors; URL inherits a themed link
  -- color (Directory is a always-defined, typically-colored group).
  pcall(vim.api.nvim_set_hl, 0, 'HimalayaHybridHover', { link = 'NormalFloat' })
  pcall(vim.api.nvim_set_hl, 0, 'HimalayaHybridUrl', { link = 'Directory' })
  pcall(vim.api.nvim_set_hl, 0, 'HimalayaHybridMatchText', { link = 'Search' })
  pcall(vim.api.nvim_set_hl, 0, 'HimalayaHybridTextMark', { fg = '#000000', bg = '#bb9af7', bold = true })
  pcall(vim.api.nvim_set_hl, 0, 'HimalayaHybridHint', { fg = '#1a1b26', bg = '#ff9e64', bold = true })
  vim.api.nvim_create_user_command('HimalayaHybridDots', function()
    local b = vim.api.nvim_get_current_buf()
    local show = not hybrid_dots_on[b]
    hybrid_dots_on[b] = show
    M._hybrid_dots(b, show)
    local n = hybrid_cells[b] and #hybrid_cells[b] or 0
    vim.notify(string.format('hybrid dots %s (%d entities)', show and 'ON' or 'off', n))
  end, { desc = 'Toggle hybrid entity alignment dots over the email image' })
  vim.api.nvim_create_user_command('HimalayaHybridMode', function()
    local b = vim.api.nvim_get_current_buf()
    local on = not hybrid_nav_on[b]
    hybrid_nav_on[b] = on
    M._hybrid_set_nav(b, on)
    vim.notify('hybrid node-nav ' .. (on and 'ON — hjkl jump between text/link nodes' or 'off'))
  end, { desc = 'Toggle hjkl navigation between email text/link nodes' })
  vim.api.nvim_create_user_command('HimalayaHybridDump', function()
    local b = vim.api.nvim_get_current_buf()
    local m = hybrid_cells[b]
    if not m or #m == 0 then
      vim.notify('hybrid: no entities (flag off, none found, or not yet rendered)')
      return
    end
    local out = {}
    for i, e in ipairs(m) do
      local r = e.rects[1]
      out[#out + 1] =
        string.format('%2d [%s] r%d c%d  %s', i, e.type, r.cr0, r.cc0, (e.href or e.text or ''):sub(1, 90))
    end
    vim.notify(table.concat(out, '\n'))
  end, { desc = 'List hybrid entities and their buffer-cell positions' })
end

return M
