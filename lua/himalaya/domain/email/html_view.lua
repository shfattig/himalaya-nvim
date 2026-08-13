-- himalaya v2 removed `message export` entirely with no CLI replacement
-- (see image.lua's own dead HTML-export codepath), so there's no way to
-- get HTML onto disk for a headless-browser screenshot pipeline anymore.
-- But `message read --json` still hands back the HTML part's raw text
-- inline (parts[i].body.Html), which is enough to render something far
-- more useful than raw markup: a plain-text approximation, converted with
-- a small self-contained parser. No pandoc/w3m/etc - none are installed,
-- and adding one is a system-level (nixos) decision, not a plugin one.
local request = require('himalaya.request')
local account_state = require('himalaya.state.account')
local log = require('himalaya.log')

local M = {}

local account_flag = account_state.flag

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

--- @param bufnr number
--- @return number  1-indexed first body line (after the folded header block, if any)
local function body_start_line(bufnr)
  local range = vim.b[bufnr].himalaya_header_fold_range
  if range then
    return range[2] + 2
  end
  return 1
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
    local converted = M.to_text(html)
    if #converted == 0 then
      log.info('HTML content converted to nothing displayable')
      return
    end
    local start = body_start_line(bufnr)
    local orig_body = vim.api.nvim_buf_get_lines(bufnr, start - 1, -1, false)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, start - 1, -1, false, converted)
    vim.bo[bufnr].modifiable = false
    vim.b[bufnr].himalaya_html_view = true
    vim.b[bufnr].himalaya_html_view_orig_body = orig_body
  end)
end

return M
