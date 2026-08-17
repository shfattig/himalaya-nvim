-- himalaya v2 removed `message export` entirely with no CLI replacement
-- (see image.lua's own dead HTML-export codepath), so there's no way to
-- get HTML onto disk for a headless-browser screenshot pipeline anymore.
-- But `message read --json` still hands back the HTML part's raw text
-- inline (parts[i].body.Html), which is enough to render something far
-- more useful than raw markup: a plain-text approximation.
--
-- Converted via pandoc (a real HTML parser, now installed at the system
-- level - see home.nix) when it's available, since it handles arbitrary/
-- malformed markup far better than regex ever could; the self-contained
-- Lua parser below (M.to_text) still backs it as a fallback for machines
-- where pandoc isn't installed, so `gh` never just breaks.
local request = require('himalaya.request')
local account_state = require('himalaya.state.account')
local log = require('himalaya.log')

local M = {}

local account_flag = account_state.flag

--- Path to pandoc_filter.lua, a sibling file (NOT a neovim module - see its
--- own header comment) - resolved relative to this file's own source path
--- so it works regardless of where the plugin is installed.
local PANDOC_FILTER = (function()
  local source = debug.getinfo(1, 'S').source
  local dir = source:sub(1, 1) == '@' and source:sub(2):match('(.*)/[^/]+$') or nil
  return dir and (dir .. '/pandoc_filter.lua') or nil
end)()

local ENTITIES = {
  ['&amp;'] = '&',
  ['&lt;'] = '<',
  ['&gt;'] = '>',
  ['&quot;'] = '"',
  ['&#39;'] = "'",
  ['&apos;'] = "'",
  ['&nbsp;'] = ' ',
  ['&mdash;'] = '—',
  ['&ndash;'] = '–',
  ['&hellip;'] = '…',
  ['&rsquo;'] = '’',
  ['&lsquo;'] = '‘',
  ['&rdquo;'] = '”',
  ['&ldquo;'] = '“',
}

local function decode_entities(s)
  for enc, dec in pairs(ENTITIES) do
    s = s:gsub(enc, dec)
  end
  s = s:gsub('&#(%d+);', function(n)
    local ok, char = pcall(vim.fn.nr2char, tonumber(n))
    return ok and char or ''
  end)
  return s
end

--- Collapse a raw converted string into trimmed lines with no more than
--- one consecutive blank line, and no leading/trailing blank lines.
--- @param s string
--- @return string[]
local function tidy_lines(s)
  local lines = {}
  for line in (s .. '\n'):gmatch('([^\n]*)\n') do
    lines[#lines + 1] = (line:gsub('%s+$', ''))
  end
  local out, blank_run = {}, 0
  for _, line in ipairs(lines) do
    if line == '' then
      blank_run = blank_run + 1
      if blank_run <= 1 then
        out[#out + 1] = line
      end
    else
      blank_run = 0
      out[#out + 1] = line
    end
  end
  while out[1] == '' do
    table.remove(out, 1)
  end
  while out[#out] == '' do
    table.remove(out, #out)
  end
  return out
end

--- Crude HTML -> readable text/markdown-ish conversion. Not a real parser -
--- good enough for typical notification/marketing HTML, not meant to
--- faithfully reproduce arbitrary markup.
--- @param html string
--- @return string[] lines
function M.to_text(html)
  local s = html
  s = s:gsub('<!%-%-.-%-%->', '')
  s = s:gsub('<[Ss][Cc][Rr][Ii][Pp][Tt].->.-</[Ss][Cc][Rr][Ii][Pp][Tt]>', '')
  s = s:gsub('<[Ss][Tt][Yy][Ll][Ee].->.-</[Ss][Tt][Yy][Ll][Ee]>', '')

  -- Links: <a href="url">text</a> -> text (url)
  s = s:gsub('<[Aa]%s+[^>]-[Hh][Rr][Ee][Ff]%s*=%s*["\']([^"\']-)["\'][^>]*>(.-)</[Aa]>', function(url, text)
    text = vim.trim((text:gsub('<[^>]+>', ''):gsub('%s+', ' ')))
    if text == '' or text == url then
      return url
    end
    return string.format('%s (%s)', text, url)
  end)

  -- Headings
  for i = 1, 6 do
    s = s:gsub('<[Hh]' .. i .. '[^>]*>(.-)</[Hh]' .. i .. '>', function(t)
      return '\n\n' .. string.rep('#', i) .. ' ' .. vim.trim((t:gsub('<[^>]+>', ''))) .. '\n\n'
    end)
  end

  -- Bold/italic
  s = s:gsub('<[Bb]>(.-)</[Bb]>', '**%1**')
  s = s:gsub('<[Ss][Tt][Rr][Oo][Nn][Gg]>(.-)</[Ss][Tt][Rr][Oo][Nn][Gg]>', '**%1**')
  s = s:gsub('<[Ii]>(.-)</[Ii]>', '*%1*')
  s = s:gsub('<[Ee][Mm]>(.-)</[Ee][Mm]>', '*%1*')

  -- Block/list boundaries -> line breaks
  s = s:gsub('<[Ll][Ii][^>]*>', '\n- ')
  s = s:gsub('<[Bb][Rr]%s*/?>', '\n')
  s = s:gsub('</[Pp]>', '\n\n')
  s = s:gsub('</[Dd][Ii][Vv]>', '\n')
  s = s:gsub('</[Tt][Rr]>', '\n')
  s = s:gsub('<[Tt][Dd][^>]*>', '  ')

  -- Strip whatever tags remain (images, spans, tables, etc.)
  s = s:gsub('<[^>]+>', '')

  s = decode_entities(s)

  return tidy_lines(s)
end

--- Fetch a message's HTML body via `message read --json` (himalaya v2 has
--- no `message export` anymore). Calls back with the raw HTML string, or
--- nil if the message has no HTML part.
--- @param account string
--- @param folder string
--- @param id string
--- @param callback fun(html: string?)
function M.fetch_html(account, folder, id, callback)
  request.json({
    cmd = 'message read %s --mailbox %q %s',
    args = { account_flag(account), folder, id },
    msg = 'Fetching HTML body',
    on_error = function()
      callback(nil)
    end,
    on_data = function(data)
      -- himalaya's html_body/text_body indices are 0-based (Rust Vec
      -- indices serialized as-is); vim.json.decode's arrays are Lua
      -- tables (1-based), so the stored index needs +1 to land on the
      -- right element.
      local raw_idx = data.html_body and data.html_body[1]
      local part = raw_idx and data.parts and data.parts[raw_idx + 1]
      local body = part and part.body
      callback(type(body) == 'table' and body.Html or nil)
    end,
  })
end

--- Convert HTML to a lines[] text view. Prefers shelling out to pandoc when
--- it's on PATH, falling back to the bespoke M.to_text parser above
--- otherwise, or if pandoc unexpectedly fails/produces nothing.
---
--- Target is `-t markdown`, not `-t plain`: `plain` discards <a href> links
--- entirely (renders just the link text), while `markdown` preserves them
--- as `[text](url)`. Reading with `-native_divs-native_spans` disabled
--- keeps that from also round-tripping every styling-only <div>/<span> as
--- literal `::: ... :::` fenced-div and `[x]{style="..."}` bracketed-span
--- syntax - those extensions only gate how the AST is *written*, so
--- disabling them on the *reader* instead makes html-to-Pandoc parsing drop
--- the wrapper and keep just its contents. pandoc_filter.lua (--lua-filter,
--- a sibling file, not a neovim module) still flattens layout tables into
--- flowing paragraphs and drops alt-text-less tracking pixels at the AST
--- level, so switching writers doesn't reintroduce the "wall of
--- box-drawing borders" a full-width layout <table> would otherwise
--- produce under either writer.
--- @param html string
--- @param callback fun(lines: string[])
function M.convert(html, callback)
  if vim.fn.executable('pandoc') ~= 1 or not PANDOC_FILTER then
    callback(M.to_text(html))
    return
  end
  vim.system(
    {
      'pandoc',
      '-f',
      'html-native_divs-native_spans',
      '-t',
      'markdown',
      '--wrap=none',
      '--lua-filter=' .. PANDOC_FILTER,
    },
    { text = true, stdin = html },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 or not result.stdout or vim.trim(result.stdout) == '' then
          callback(M.to_text(html))
          return
        end
        callback(tidy_lines(result.stdout))
      end)
    end
  )
end

--- @param bufnr number
--- @return number  1-indexed first body line (after the folded header block, if any)
local function body_start_line(bufnr)
  local range = vim.b[bufnr].himalaya_header_fold_range
  if range then
    return range[2] + 2
  end
  return 1
end

--- Splice converted HTML lines into the reading buffer's body in place of
--- whatever's there now, stashing the replaced lines so a later M.toggle()
--- (or a second M.prefer_if_available(), which no-ops once this has run)
--- can restore them. Shared by M.toggle()'s switch-to-html branch and
--- M.prefer_if_available()'s auto-upgrade.
--- @param bufnr number
--- @param converted string[]
local function apply_html_view(bufnr, converted)
  local start = body_start_line(bufnr)
  local orig_body = vim.api.nvim_buf_get_lines(bufnr, start - 1, -1, false)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, start - 1, -1, false, converted)
  vim.bo[bufnr].modifiable = false
  vim.b[bufnr].himalaya_html_view = true
  vim.b[bufnr].himalaya_html_view_orig_body = orig_body
end

--- Toggle the reading buffer's body between its original plain-text
--- rendering and an HTML-derived text view, converted from the message's
--- HTML part on first toggle (cached on the buffer so re-toggling is
--- instant, matching image.lua's toggle() precedent for this buffer).
--- @param bufnr? number
function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if vim.b[bufnr].himalaya_html_view then
    local orig = vim.b[bufnr].himalaya_html_view_orig_body
    if orig then
      local start = body_start_line(bufnr)
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, start - 1, -1, false, orig)
      vim.bo[bufnr].modifiable = false
    end
    vim.b[bufnr].himalaya_html_view = false
    vim.b[bufnr].himalaya_html_view_orig_body = nil
    return
  end

  local account = vim.b[bufnr].himalaya_account
  local folder = vim.b[bufnr].himalaya_folder
  local id = vim.b[bufnr].himalaya_current_email_id
  if not (account and folder and id) then
    return
  end

  M.fetch_html(account, folder, id, function(html)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if not html then
      log.info('No HTML content in this message')
      return
    end
    M.convert(html, function(converted)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      if #converted == 0 then
        log.info('HTML content converted to nothing displayable')
        return
      end
      apply_html_view(bufnr, converted)
    end)
  end)
end

--- Silently upgrade a freshly-opened reading buffer to its HTML-converted
--- view, if it has one and hasn't already been toggled - matching how
--- webmail clients render multipart/alternative mail by default (RFC 2046
--- §5.1.4 orders alternative parts least-to-most-preferred, so a later
--- HTML part is the sender's own intended "best" rendering; USPS-style
--- senders also routinely leave the plain part sparse/generic compared to
--- the HTML, or omit it entirely). Unlike M.toggle(), failure is silent -
--- no HTML part, or a conversion that yields nothing, is the ordinary case
--- for plain-text mail and isn't worth a notification on every open.
--- @param bufnr number
function M.prefer_if_available(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].himalaya_html_view then
    return
  end
  local account = vim.b[bufnr].himalaya_account
  local folder = vim.b[bufnr].himalaya_folder
  local id = vim.b[bufnr].himalaya_current_email_id
  if not (account and folder and id) then
    return
  end

  -- Reused reading buffers (see email.lua's M.read()) get repopulated for a
  -- new email in place - reconfirm this is still the same email and it's
  -- still un-toggled before applying a slow async result to what might by
  -- then be a completely different message.
  local function still_current()
    return vim.api.nvim_buf_is_valid(bufnr)
      and not vim.b[bufnr].himalaya_html_view
      and vim.b[bufnr].himalaya_current_email_id == id
  end

  M.fetch_html(account, folder, id, function(html)
    if not html or not still_current() then
      return
    end
    M.convert(html, function(converted)
      if #converted == 0 or not still_current() then
        return
      end
      apply_html_view(bufnr, converted)
    end)
  end)
end

return M
