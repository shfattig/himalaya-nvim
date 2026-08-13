local keybinds = require('himalaya.keybinds')
local email = require('himalaya.domain.email')
local compose = require('himalaya.domain.email.compose')
local win = require('himalaya.ui.win')
local log = require('himalaya.log')

local M = {}

local EMAIL_PATTERN = '[%w.+_%-]+@[%w.%-]+%.[%w]+'

--- Find the email address on the current line, preferring one whose span
--- contains the cursor column, falling back to the first match on the line.
--- @return string?
local function address_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local first, pos = nil, 1
  while true do
    local s, e = line:find(EMAIL_PATTERN, pos)
    if not s then
      break
    end
    first = first or { s, e }
    if col >= s and col <= e then
      return line:sub(s, e)
    end
    pos = e + 1
  end
  return first and line:sub(first[1], first[2]) or nil
end

--- Navigate to the next or previous email in the listing and read it.
--- @param direction number  +1 for next, -1 for previous
local function navigate_email(direction)
  local winid, bufnr = win.find_by_buftype({ 'listing', 'thread-listing' })
  if not winid then
    return
  end
  vim.api.nvim_win_call(winid, function()
    local row = vim.api.nvim_win_get_cursor(winid)[1]
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local new_row = row + direction
    if new_row >= 1 and new_row <= line_count then
      vim.api.nvim_win_set_cursor(winid, { new_row, 0 })
      email.read()
    end
  end)
end

--- Set up the reading buffer: options, syntax, and keybinds.
--- @param bufnr number
function M.setup(bufnr)
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].filetype = 'mail'
  vim.bo[bufnr].modifiable = false

  vim.api.nvim_buf_call(bufnr, function()
    vim.wo.foldmethod = 'expr'
    vim.wo.foldexpr = "v:lua.require'himalaya.domain.email.thread'.foldexpr(v:lnum)"
  end)

  keybinds.define(bufnr, {
    { 'n', 'gw', compose.write, 'email-write' },
    { 'n', 'gr', compose.reply, 'email-reply' },
    { 'n', 'gR', compose.reply_all, 'email-reply-all' },
    { 'n', 'gf', compose.forward, 'email-forward' },
    {
      'n',
      'ga',
      function()
        require('himalaya.domain.account').select()
      end,
      'account-select',
    },
    { 'n', 'gA', email.download_attachments, 'email-download-attachments' },
    { 'n', 'gC', email.select_folder_then_copy, 'email-select-folder-then-copy' },
    { 'n', 'gM', email.select_folder_then_move, 'email-select-folder-then-move' },
    { 'n', 'gD', email.delete, 'email-delete' },
    { 'n', 'gb', email.open_browser, 'email-open-browser' },
    {
      'n',
      'gy',
      function()
        local addr = address_under_cursor()
        if not addr then
          log.info('No email address on this line')
          return
        end
        vim.fn.setreg('"', addr)
        vim.fn.setreg('+', addr)
        log.info('Yanked ' .. addr)
      end,
      'email-yank-address',
    },
    {
      'n',
      'gW',
      function()
        local addr = address_under_cursor()
        if not addr then
          log.info('No email address on this line')
          return
        end
        compose.write_to(addr)
      end,
      'email-write-to-address',
    },
    {
      'n',
      'gh',
      function()
        require('himalaya.domain.email.html_view').toggle()
      end,
      'email-toggle-html-text',
    },
    {
      'n',
      'gi',
      function()
        require('himalaya.domain.email.image').toggle()
      end,
      'email-render-image',
    },
    {
      'n',
      'gI',
      function()
        require('himalaya.domain.email.image').toggle_mode()
      end,
      'email-toggle-image-mode',
    },
    {
      'n',
      'gB',
      function()
        require('himalaya.domain.email.image').open_in_app()
      end,
      'email-open-image',
    },
    {
      'n',
      ']]',
      function()
        navigate_email(1)
      end,
      'email-next',
    },
    {
      'n',
      '[[',
      function()
        navigate_email(-1)
      end,
      'email-previous',
    },
    { 'n', '?', keybinds.show_help, 'help' },
  })

  keybinds.register_which_key_groups(bufnr, {
    { ']', 'Next' },
    { '[', 'Prev' },
  })

  local account = vim.b[bufnr].himalaya_account or ''
  local folder = vim.b[bufnr].himalaya_folder or ''
  local email_id = vim.b[bufnr].himalaya_current_email_id or ''
  local label = string.format('[%s] [%s] email %s', account, folder, email_id)
  local winid = win.find_by_bufnr(bufnr)
  if winid then
    vim.wo[winid].winbar = '%#HimalayaHead#' .. label:gsub('%%', '%%%%')
  end
end

return M
