-- Diagnostic tmux hook + nvim focus event logger for image hide/show debugging.
-- Usage:  :luafile /tmp/diag-hooks.lua
-- Teardown:  :lua DiagTeardown()
--
-- Logs to /tmp/image-nvim-diag.log  (same file for tmux hooks AND nvim autocmds)
-- Does NOT modify image.nvim source — purely additive, temporary.

local LOG = '/tmp/image-nvim-diag.log'
local HOOK_INDEX = 99 -- avoid conflicting with image.nvim's [0] hooks
local AUGROUP = 'DiagImageHooks'

-- All hooks to register: { scope_flag, hook_name }
-- scope_flag: '-g' for global (set-hook -g), '-gw' for window (set-hook -gw)
local HOOKS = {
  -- Global hooks
  { '-g', 'session-window-changed' },
  { '-g', 'after-select-window' },
  { '-g', 'after-select-pane' },
  { '-g', 'client-session-changed' },
  { '-g', 'client-focus-in' },
  { '-g', 'client-focus-out' },
  { '-g', 'after-resize-pane' },
  -- Window hooks
  { '-gw', 'pane-mode-changed' },
  { '-gw', 'window-layout-changed' },
  { '-gw', 'window-pane-changed' },
  { '-gw', 'pane-focus-in' },
  { '-gw', 'pane-focus-out' },
}

--- Run a tmux command using vim.system (bypasses &shell, no glob/quoting issues).
local function tmux(args)
  local cmd = { 'tmux' }
  for _, a in ipairs(args) do
    cmd[#cmd + 1] = a
  end
  return vim.system(cmd, { text = true }):wait()
end

-------------------------------------------------------------------------------
-- Step 1: Unregister existing image.nvim tmux hooks (to avoid interference)
-------------------------------------------------------------------------------
local function unregister_image_nvim_hooks()
  for _, entry in ipairs(HOOKS) do
    local scope, name = entry[1], entry[2]
    tmux({ 'set-hook', scope, '-u', name .. '[0]' })
  end
  print('[diag] Unregistered image.nvim tmux hooks (index [0])')
end

-------------------------------------------------------------------------------
-- Step 2: Register diagnostic tmux hooks
-------------------------------------------------------------------------------
local function register_tmux_hooks()
  -- Each hook calls the helper script with the hook name as its argument.
  -- The script queries tmux display-message for all format variables.
  -- This avoids all nested-quoting issues — tmux just sees:
  --   run-shell "/tmp/diag-hook.sh hookname"
  for _, entry in ipairs(HOOKS) do
    local scope, name = entry[1], entry[2]
    local hook_key = name .. '[' .. HOOK_INDEX .. ']'
    local hook_cmd = 'run-shell "/tmp/diag-hook.sh ' .. name .. '"'
    local r = tmux({ 'set-hook', scope, hook_key, hook_cmd })
    if r.code ~= 0 then
      print(string.format('[diag] WARN: failed to set hook %s: %s', hook_key, (r.stderr or ''):gsub('\n', ' ')))
    end
  end
  print(string.format('[diag] Registered %d tmux hooks (index [%d])', #HOOKS, HOOK_INDEX))
end

-------------------------------------------------------------------------------
-- Step 3: Register nvim FocusLost / FocusGained autocmds
-------------------------------------------------------------------------------
local function register_autocmds()
  vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  local tmux_pane = os.getenv('TMUX_PANE') or '(no TMUX_PANE)'

  local function log_focus(event)
    -- Query tmux for current state of THIS pane (bypass &shell via vim.system).
    -- Use pipe-delimited output to handle empty fields (e.g. pane_mode).
    local r = vim
      .system({
        'tmux',
        'display-message',
        '-p',
        '-t',
        tmux_pane,
        '#{window_id}|#{window_active}|#{session_attached}|#{pane_active}|#{pane_mode}|#{session_id}|#{window_zoomed_flag}|#{client_session}',
      }, { text = true })
      :wait()

    local fields = {}
    for field in ((r.stdout or ''):gsub('\n$', '') .. '|'):gmatch('([^|]*)|') do
      fields[#fields + 1] = field
    end

    local line = string.format(
      '%s NVIM:%-14s pane=%s win=%s win_active=%s sess_att=%s pane_active=%s mode=%q sess=%s zoomed=%s client_sess=%s',
      os.date('%H:%M:%S.') .. string.format('%03d', math.floor((vim.uv.hrtime() / 1e6) % 1000)),
      event,
      tmux_pane,
      fields[1] or '?',
      fields[2] or '?',
      fields[3] or '?',
      fields[4] or '?',
      fields[5] or '',
      fields[6] or '?',
      fields[7] or '?',
      fields[8] or '?'
    )

    local f = io.open(LOG, 'a')
    if f then
      f:write(line .. '\n')
      f:close()
    end
  end

  vim.api.nvim_create_autocmd('FocusLost', {
    group = AUGROUP,
    callback = function()
      log_focus('FocusLost')
    end,
  })

  vim.api.nvim_create_autocmd('FocusGained', {
    group = AUGROUP,
    callback = function()
      log_focus('FocusGained')
    end,
  })

  print('[diag] Registered FocusLost/FocusGained autocmds')
end

-------------------------------------------------------------------------------
-- Step 4: Teardown function
-------------------------------------------------------------------------------
function DiagTeardown()
  for _, entry in ipairs(HOOKS) do
    local scope, name = entry[1], entry[2]
    tmux({ 'set-hook', scope, '-u', name .. '[' .. HOOK_INDEX .. ']' })
  end
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  print(string.format('[diag] Teardown complete — hooks removed, log at %s', LOG))
end

-------------------------------------------------------------------------------
-- Step 5: Verify hooks registered
-------------------------------------------------------------------------------
local function verify_hooks()
  local r = vim.system({ 'tmux', 'show-hooks', '-g' }, { text = true }):wait()
  local rw = vim.system({ 'tmux', 'show-hooks', '-gw' }, { text = true }):wait()
  local count = 0
  for line in ((r.stdout or '') .. (rw.stdout or '')):gmatch('[^\n]+') do
    if line:find('%[' .. HOOK_INDEX .. '%]') then
      count = count + 1
    end
  end
  if count == #HOOKS then
    print(string.format('[diag] Verified: all %d hooks registered', count))
  else
    print(string.format('[diag] WARNING: only %d/%d hooks registered!', count, #HOOKS))
    print('[diag] Run:  tmux show-hooks -g && tmux show-hooks -gw')
  end
end

-------------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------------

local f = io.open(LOG, 'w')
if f then
  f:write(string.format('=== DIAG SESSION STARTED %s ===\n', os.date('%Y-%m-%d %H:%M:%S')))
  f:write(string.format('TMUX_PANE=%s  nvim_pid=%d\n', os.getenv('TMUX_PANE') or '?', vim.fn.getpid()))
  f:write('---\n')
  f:close()
end

unregister_image_nvim_hooks()
register_tmux_hooks()
register_autocmds()
verify_hooks()

print(string.format('[diag] Logging to %s — run :lua DiagTeardown() when done', LOG))
