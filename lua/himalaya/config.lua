local M = {}

local defaults = {
  -- Path to the himalaya CLI binary
  executable = 'himalaya',

  -- Path to a custom himalaya config file (nil = CLI default)
  config_path = nil,

  -- Folder/account picker: 'native', 'fzf', 'fzf-lua', or 'telescope'
  -- nil = auto-detect (telescope > fzf-lua > fzf > native)
  folder_picker = nil,

  -- Show preview in Telescope picker
  telescope_preview = false,

  -- Shell command for contact completion (omnifunc); %s = query
  complete_contact_cmd = nil,

  -- Additional flags for flag completion
  custom_flags = {},

  -- Prompt before destructive actions (delete, move)
  always_confirm = true,

  -- Mailbox delete() moves messages to (himalaya's `message delete` no
  -- longer exists - deleting is moving to trash, same as most webmail).
  -- Resolved through the account's [mailbox.alias] map, so this only needs
  -- changing if an account's config doesn't alias 'trash' to something.
  trash_mailbox = 'trash',

  -- Flag display characters in the listing
  flags = {
    header = 'FLGS',
    flagged = '!',
    unseen = '*',
    answered = 'R',
    attachment = '@',
  },

  -- Compact flags into the subject column instead of a separate column.
  -- nil/false: never (5-column layout), true: when narrow, "always": always.
  compact_flags = true,

  -- Compact IDs: remove the ID column and reclaim its width for the subject.
  -- nil/false: never, true: when narrow, "always": always.
  compact_ids = nil,

  -- Show vertical separators between columns
  gutters = true,

  -- Date format (strftime)
  date_format = '%Y-%m-%d %H:%M',

  -- Compact date format used when the listing is too narrow for the full FROM column.
  compact_date_format = '%m/%d',

  -- Start in thread view instead of flat listing
  thread_view = false,

  -- Show newest messages at top in thread view
  thread_reverse = false,

  -- Named search presets for quick access via g?
  search_presets = {},

  -- Override default keybinds (key = plug-name, value = key or false)
  keymaps = {},

  -- Periodically re-fetch envelopes in the background
  background_sync = false,

  -- Background sync interval in seconds
  sync_interval = 60,

  -- Per-account email signatures: string or { account_name = string }
  signature = nil,

  -- Reading pane split configuration.
  -- threshold: listing width at which 'over' vs 'under' is chosen.
  -- size: 0.0–1.0 = fraction of space; >1 = absolute cols/rows (shared default)
  -- over/under: direction string ('left'|'right'|'above'|'below')
  --   or table { side = direction, size = number } to override size per branch.
  reading_split = {
    threshold = 115,
    size = 0.6,
    over = 'right',
    under = 'below',
  },

  -- HTML image rendering. REQUIRES the xav-ie fork of image.nvim
  -- (https://github.com/xav-ie/image.nvim) — upstream image.nvim lacks the
  -- unicode-placeholder, preload, and batched-write support this relies on —
  -- plus chrome-headless-shell and ImageMagick (magick).
  -- binary: path to chrome-headless-shell (or compatible headless browser).
  -- pixels_per_column: scale factor to convert buffer columns to viewport
  --   pixels (default 8). Increase for sharper text on HiDPI displays.
  render_html = {
    binary = 'chrome-headless-shell',
    pixels_per_column = 8,
    device_scale_factor = 2,
    max_screenshot_height = 5000,
    -- Content zoom, as a percentage. The on-screen display area is fixed; zoom
    -- controls the CSS width the email is laid out at, hence how large the
    -- content appears. 100 = lay out at the true display width (content 1:1).
    -- >100 magnifies (narrower layout, bigger text/images); <100 shrinks
    -- (wider layout, more fits, smaller content). Independent of
    -- device_scale_factor, which only affects capture sharpness, not size.
    zoom = 100,
    -- When true, emails are rendered as images by default (gI toggles this).
    image_mode = false,
    -- Progressive (two-pass) rendering. When true, paint a first image as soon
    -- as the DOM is interactive (fast), then re-render once the page reaches
    -- 'complete' (all images settled) for a refined result. Off by default:
    -- single capture once the page is complete (or the load cap is hit).
    progressive = false,
    -- Device scale factor for the progressive FIRST (interactive) pass. Lower
    -- than device_scale_factor means the preview is captured at reduced
    -- resolution (blurry, but far fewer PNG bytes to transmit and a faster
    -- capture); the final pass still renders at device_scale_factor (sharp).
    -- The CSS layout width is held fixed across passes so the layout doesn't
    -- shift. Clamped to [1, device_scale_factor]. Only used when progressive.
    preview_scale_factor = 1,
    -- Smooth-scroll plugins (e.g. vim-smoothie) animate Ctrl-d/u/f/b as many
    -- rapid scroll frames. Inline images are positioned at absolute screen
    -- coords and reposition one tick behind neovim's text-grid scroll; with the
    -- image split into stacked tiles that one-frame lag is visible as flicker at
    -- the tile seams during the animation (a single discrete jump doesn't show
    -- it). When false (default), Ctrl-d/u/f/b are mapped buffer-local to the
    -- builtin discrete scroll while an email image is displayed, so there's no
    -- flicker; set true to keep smooth scrolling over the image (with flicker).
    smooth_image_scroll = false,
    -- Unicode-placeholder rendering (kitty/ghostty). When true, the email image
    -- is transmitted once as a virtual placement and laid out as placeholder
    -- cells in the buffer, so it scrolls in lockstep with the text grid — no
    -- seam flicker, fully smooth scrolling. Trade-off vs. chunked: the whole
    -- image is transmitted up front. Requires termguicolors. Takes precedence
    -- over `chunked`; falls back to it (or single image) when unavailable or the
    -- image is too tall for the placeholder grid.
    placeholders = false,
    -- Dark-mode rendering. When true, the headless browser is told to emulate
    -- `prefers-color-scheme: dark`, so emails render their OWN dark theme
    -- instead of blinding white. Emails that don't support a dark theme still
    -- render as authored. Off by default.
    dark = false,
    -- Hybrid text/image layer (experimental, placeholder mode only). When true,
    -- the headless render also extracts the email's links/text with their
    -- bounding boxes and maps them onto the placeholder cells, giving the image
    -- a clickable/copyable/searchable layer. Over a link: hover shows its URL,
    -- gx/<CR> opens it, gy copies it. g/ searches the email's text+links, marks
    -- matches on the image, and n/N cycle the cursor through them.
    -- (:HimalayaHybridDots overlays link alignment markers, :HimalayaHybridDump
    -- lists entities.) Off by default.
    hybrid = false,
    -- Chunked rendering. When true, the tall email PNG is sliced into
    -- viewport-height tiles, each placed as its own image.nvim image stacked in
    -- the buffer. image.nvim only transmits the chunks intersecting the visible
    -- window (off-screen tiles early-return before transmit), so a long email
    -- ships ~1 screen of pixels up front and streams the rest on scroll. Slices
    -- are produced in parallel. Off by default: one image for the whole email.
    chunked = false,
  },

  -- Enable mock mode (no CLI binary or email account needed)
  mock = false,
}

local current = vim.deepcopy(defaults)

function M.setup(opts)
  current = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
end

function M.get()
  return current
end

--- Set a single config key.
--- @param key string
--- @param value any
function M.set(key, value)
  current[key] = value
end

function M._reset()
  current = vim.deepcopy(defaults)
end

return M
