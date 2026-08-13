local request = require('himalaya.request')
local log = require('himalaya.log')
local account_state = require('himalaya.state.account')
local win = require('himalaya.ui.win')

local M = {}

local account_flag = account_state.flag

local function context_email_id()
  return require('himalaya.domain.email').context_email_id()
end

--- Set buffer content, replacing carriage returns and trailing blank line.
--- @param content string
local function set_buffer_content(content)
  vim.bo.modifiable = true
  vim.cmd('silent! %d')
  local lines = vim.split(content:gsub('\r', ''), '\n')
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  -- Remove trailing empty line (matches VimScript `$d`)
  local last = vim.api.nvim_buf_line_count(0)
  if last > 1 and vim.api.nvim_buf_get_lines(0, last - 1, last, false)[1] == '' then
    vim.api.nvim_buf_set_lines(0, last - 1, last, false, {})
  end
end

--- Append a signature to the given buffer (blank line + signature lines).
--- @param bufnr number
--- @param sig string
local function append_signature(bufnr, sig)
  local lines = vim.split(sig, '\n')
  local last = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, last, last, false, { '' })
  vim.api.nvim_buf_set_lines(bufnr, last + 1, last + 1, false, lines)
end

--- Internal: open a write/reply/forward buffer with template content.
--- @param msg string buffer name suffix
--- @param content string template content
--- @param account? string account to stamp on buffer
--- @param folder? string folder to stamp on buffer
--- @param reply_id? string email ID being replied to
--- @param mode? string compose mode ('write', 'reply', 'reply_all', 'forward')
local function open_write_buffer(msg, content, account, folder, reply_id, mode)
  local bufname = string.format('Himalaya/%s', msg)
  -- Prefer the reading window so the listing stays visible
  local reading_win = win.find_by_name('Himalaya/read email')
  if reading_win then
    vim.api.nvim_set_current_win(reading_win)
    vim.cmd(string.format('silent! edit %s', vim.fn.fnameescape(bufname)))
  else
    local listing_winid = vim.api.nvim_get_current_win()
    local buf = vim.fn.bufnr(bufname)
    if buf == -1 then
      buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, bufname)
    end
    win.open_split(buf, listing_winid)
  end
  if account then
    vim.b.himalaya_account = account
  end
  if folder then
    vim.b.himalaya_folder = folder
  end
  if reply_id then
    vim.b.himalaya_reply_id = reply_id
  end
  set_buffer_content(content)
  local cfg = require('himalaya.config').get()
  local sig = cfg.signature
  if type(sig) == 'table' then
    sig = sig[account]
  end
  if type(sig) == 'string' and sig ~= '' then
    append_signature(vim.api.nvim_get_current_buf(), sig)
  end
  vim.bo.filetype = 'himalaya-email-writing'
  vim.bo.modified = false
  require('himalaya.events').emit('ComposeOpened', {
    account = account,
    folder = folder,
    mode = mode or 'write',
    bufnr = vim.api.nvim_get_current_buf(),
    reply_id = reply_id,
  })
end

--- Compose a new email. If template is provided, use it; otherwise fetch from CLI.
--- @param template? string
function M.write(template)
  local context = require('himalaya.state.context')
  local account, folder = context.resolve()
  if template then
    open_write_buffer('edit', template, account, folder, nil, 'write')
  else
    -- himalaya v2 replaced the `template` subcommand family with an
    -- arg-based composer (message compose/reply/forward). Called with no
    -- --to/--subject/--body, `message compose` still prints a minimal
    -- editable RFC 5322 skeleton to stdout instead of sending anything (no
    -- --send passed) - that's what preserves the "fetch a template, edit
    -- it, :w to send" flow this buffer-based UI depends on.
    request.plain({
      cmd = 'message compose %s',
      args = { account_flag(account) },
      msg = 'Fetching new template',
      on_data = function(data)
        open_write_buffer('write', data, account, folder, nil, 'write')
      end,
    })
  end
end

--- Compose a new email pre-addressed to a given recipient (e.g. an address
--- picked off a header line in the reading buffer).
--- @param addr string
function M.write_to(addr)
  local context = require('himalaya.state.context')
  local account, folder = context.resolve()
  request.plain({
    cmd = 'message compose %s --to %q',
    args = { account_flag(account), addr },
    msg = 'Fetching new template',
    on_data = function(data)
      open_write_buffer('write', data, account, folder, nil, 'write')
    end,
  })
end

--- Reply to current email.
function M.reply()
  local context = require('himalaya.state.context')
  local account, folder = context.resolve()
  local id = context_email_id()
  request.plain({
    cmd = 'message reply %s --mailbox %q %s',
    args = { account_flag(account), folder, id },
    msg = 'Fetching reply template',
    on_data = function(data)
      open_write_buffer(string.format('reply [%s]', id), data, account, folder, id, 'reply')
    end,
  })
end

--- Reply-all to current email.
-- himalaya v2's `message reply` has no reply-all equivalent at all (no
-- --all/-A flag, no way to pull in the original Cc list) - it only
-- "optionally derives recipients from Reply-To/From" per its own --help.
-- Falling back to the same single-recipient reply rather than refusing
-- outright, since a narrower Cc list is still useful and this isn't a
-- fully broken subsystem like thread view or HTML export - just log
-- clearly so the narrowed behavior isn't a silent surprise.
function M.reply_all()
  local context = require('himalaya.state.context')
  local account, folder = context.resolve()
  local id = context_email_id()
  log.warn('Reply-all is narrowed to reply: himalaya v2 has no --all equivalent, original Cc recipients are dropped')
  request.plain({
    cmd = 'message reply %s --mailbox %q %s',
    args = { account_flag(account), folder, id },
    msg = 'Fetching reply template',
    on_data = function(data)
      open_write_buffer(string.format('reply all [%s]', id), data, account, folder, id, 'reply_all')
    end,
  })
end

--- Forward current email.
function M.forward()
  local context = require('himalaya.state.context')
  local account, folder = context.resolve()
  local id = context_email_id()
  request.plain({
    cmd = 'message forward %s --mailbox %q %s',
    args = { account_flag(account), folder, id },
    msg = 'Fetching forward template',
    on_data = function(data)
      open_write_buffer(string.format('forward [%s]', id), data, account, folder, nil, 'forward')
    end,
  })
end

--- Save current buffer content as draft.
--- Skipped if the email was already sent via :w.
--- @param bufnr? number  buffer handle (defaults to current buffer)
function M.save_draft(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.b[bufnr].himalaya_sent then
    return
  end
  vim.bo.modified = false
end

--- Send the current compose buffer (triggered by :w).
--- @param bufnr? number  buffer handle (defaults to current buffer)
function M.send(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.b[bufnr].himalaya_sent then
    log.info('Email already sent from this buffer')
    return
  end

  local account = vim.b[bufnr].himalaya_account or ''
  local folder = vim.b[bufnr].himalaya_folder or 'INBOX'
  local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n') .. '\n'
  local reply_id = vim.b[bufnr].himalaya_reply_id

  request.plain({
    -- himalaya v2's `message send` still accepts a raw RFC 5322 message
    -- via stdin (same as the old `template send`), just under the new
    -- subcommand name.
    cmd = 'message send %s',
    args = { account_flag(account) },
    stdin = content,
    msg = 'Sending email',
    on_data = function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.b[bufnr].himalaya_sent = true
        vim.bo[bufnr].modified = false
      end
      log.info('Send [OK]')
      require('himalaya.events').emit('EmailSent', {
        account = account,
        folder = folder,
        reply_id = reply_id,
      })

      -- Add "answered" flag only for replies. Best-effort and silent:
      -- confirmed against a real Gmail account that its backend has no
      -- \Answered-equivalent label at all (unlike seen/flagged, which map
      -- to Gmail's own read/starred state) - `flag add --flag answered`
      -- fails outright there every time, regardless of syntax. The reply
      -- itself already sent successfully by this point, so a failure here
      -- shouldn't be surfaced as if the reply failed.
      if reply_id and reply_id ~= '' then
        request.plain({
          cmd = 'flag add %s --mailbox %q --flag answered %s',
          args = { account_flag(account), folder, reply_id },
          msg = 'Adding answered flag',
          silent = true,
        })
      end
    end,
  })
end

--- Process draft: prompt for (d)raft, (q)uit, (c)ancel.
--- Called from BufHidden so the compose buffer may already be hidden.
--- Skips the prompt if the email was already sent via :w.
--- @param bufnr? number  buffer handle (defaults to current buffer)
function M.process_draft(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.b[bufnr].himalaya_sent then
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.b[bufnr].himalaya_sent = false
    end
    return
  end
  local ok, err = pcall(function()
    local account = vim.b[bufnr].himalaya_account or ''

    while true do
      local choice = vim.fn.input('(d)raft, (q)uit or (c)ancel? ')
      choice = choice:lower():sub(1, 1)
      vim.cmd('redraw | echo')

      if choice == 'd' then
        local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n') .. '\n'
        -- "drafts" is a well-known folder alias resolved by the himalaya CLI
        -- (case-insensitive, "draft" also works).  The core library maps it to
        -- FolderKind::Drafts which each backend resolves to the real folder name
        -- (e.g. "Drafts", "INBOX.Drafts", "[Gmail]/Drafts") using IMAP
        -- special-use attributes or user-configured folder.aliases in the
        -- himalaya TOML config.  No need to make this configurable in the plugin.
        -- himalaya v2's `message add` is the raw-RFC5322-via-stdin append
        -- command now (--mailbox is mandatory, unlike the old --folder).
        request.plain({
          cmd = 'message add --mailbox drafts %s',
          args = { account_flag(account) },
          stdin = content,
          msg = 'Saving draft',
        })
        require('himalaya.events').emit('DraftSaved', { account = account })
        return
      elseif choice == 'q' or choice == '' then
        return
      elseif choice == 'c' then
        -- Re-display the hidden compose buffer instead of creating a new one
        vim.cmd('botright split')
        vim.api.nvim_win_set_buf(0, bufnr)
        return
      end
    end
  end)

  if not ok then
    log.err(tostring(err))
  end
end

return M
