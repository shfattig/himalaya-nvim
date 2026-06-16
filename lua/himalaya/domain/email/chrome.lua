--- Chrome daemon lifecycle manager.
--- Spawns chrome-headless-shell once and reuses it via CDP for all renders.

local config = require('himalaya.config')
local log = require('himalaya.log')
local websocket = require('himalaya.domain.email.websocket')
local cdp = require('himalaya.domain.email.cdp')

local M = {}

-- Singleton state
local state = {
  handle = nil, -- vim.uv process handle
  pid = nil,
  client = nil, -- cdp client
  port = nil,
  ws_path = nil,
  starting = false,
  callbacks = {}, -- queued get_client callbacks while starting
}

--- Kill the Chrome process.
function M.stop()
  if state.client then
    pcall(function()
      state.client:close()
    end)
    state.client = nil
  end
  if state.handle and not state.handle:is_closing() then
    state.handle:kill('sigterm')
    state.handle:close()
  end
  state.handle = nil
  state.pid = nil
  state.port = nil
  state.ws_path = nil
  state.starting = false
  state.callbacks = {}
end

--- Check if Chrome is alive.
local function is_alive()
  return state.handle ~= nil and not state.handle:is_closing()
end

--- Parse the DevTools WS URL from Chrome's stderr output.
--- Returns port, path or nil.
local function parse_devtools_url(line)
  local port, path = line:match('ws://127%.0%.0%.1:(%d+)(/.+)')
  if port then
    return tonumber(port), path
  end
  return nil
end

--- Create a new browser tab and connect via WebSocket.
--- callback(err, cdp_client)
local function connect_tab(callback)
  -- PUT /json/new to create a tab
  log.debug('[chrome] connect_tab: PUT /json/new on port %d', state.port)
  local called = false
  local function finish(err, client)
    if called then
      return
    end
    called = true
    callback(err, client)
  end

  -- Timeout: if connect_tab hasn't called back in 10s, something is stuck.
  local timer = vim.uv.new_timer()
  timer:start(10000, 0, function()
    timer:close()
    finish('connect_tab timed out (10s)')
  end)

  local function finish_and_stop_timer(err, client)
    if not timer:is_closing() then
      timer:close()
    end
    finish(err, client)
  end

  --- Parse /json/new response body and connect WebSocket to the tab.
  local function handle_response(body)
    local ok, tab = pcall(vim.json.decode, body)
    if not ok or not tab.webSocketDebuggerUrl then
      log.debug('[chrome] /json/new: invalid response body: %s', body:sub(1, 200))
      finish_and_stop_timer('invalid /json/new response: ' .. body:sub(1, 120))
      return
    end
    local ws_port, ws_path = parse_devtools_url(tab.webSocketDebuggerUrl)
    if not ws_port then
      finish_and_stop_timer('cannot parse tab WS URL')
      return
    end
    log.debug('[chrome] connecting WS to port %d path %s', ws_port, ws_path)
    websocket.connect('127.0.0.1', ws_port, ws_path, function(ws_err, conn)
      if ws_err then
        finish_and_stop_timer('WS connect failed: ' .. ws_err)
        return
      end
      local client = cdp.new(conn)
      client:send('Page.enable', nil, function(enable_err)
        if enable_err then
          finish_and_stop_timer('Page.enable failed: ' .. tostring(enable_err))
          return
        end
        log.debug('[chrome] CDP client ready')
        finish_and_stop_timer(nil, client)
      end)
    end)
  end

  local tcp = vim.uv.new_tcp()
  tcp:connect('127.0.0.1', state.port, function(err)
    if err then
      finish_and_stop_timer('tab connect failed: ' .. err)
      return
    end
    local req = 'PUT /json/new HTTP/1.1\r\nHost: 127.0.0.1:' .. state.port .. '\r\nContent-Length: 0\r\n\r\n'
    tcp:write(req)

    local buf = ''
    tcp:read_start(function(read_err, data)
      if read_err or not data then
        tcp:read_stop()
        if not tcp:is_closing() then
          tcp:close()
        end
        if not data and #buf > 0 then
          local body = buf:match('\r\n\r\n(.+)')
          if not body then
            finish_and_stop_timer('failed to parse /json/new response')
          else
            handle_response(body)
          end
        elseif read_err then
          finish_and_stop_timer('tab read error: ' .. read_err)
        end
        return
      end
      buf = buf .. data
      if buf:find('\r\n\r\n') and buf:find('}%s*$') then
        tcp:read_stop()
        if not tcp:is_closing() then
          tcp:close()
        end
        local body = buf:match('\r\n\r\n(.+)')
        handle_response(body)
      end
    end)
  end)
end

--- Spawn Chrome and connect.
local function start(callback)
  local cfg = config.get()
  local bin = cfg.render_html and cfg.render_html.binary or 'chrome-headless-shell'

  log.debug('[chrome] starting %s', bin)
  state.starting = true
  table.insert(state.callbacks, callback)

  local stderr_buf = ''
  local stdout = vim.uv.new_pipe()
  local stderr = vim.uv.new_pipe()

  local handle, pid
  handle, pid = vim.uv.spawn(bin, {
    args = { '--remote-debugging-port=0', '--no-sandbox', '--disable-gpu' },
    stdio = { nil, stdout, stderr },
  }, function(code, signal)
    -- Chrome exited
    log.debug('chrome-headless-shell exited (code=%d signal=%d)', code, signal)
    state.handle = nil
    state.pid = nil
    state.client = nil
    state.port = nil
    state.starting = false
  end)

  if not handle then
    state.starting = false
    local cbs = state.callbacks
    state.callbacks = {}
    for _, cb in ipairs(cbs) do
      cb('failed to spawn ' .. bin .. ': ' .. tostring(pid))
    end
    return
  end

  state.handle = handle
  state.pid = pid

  stdout:read_start(function() end) -- drain stdout

  stderr:read_start(function(err, data)
    if err or not data then
      return
    end
    stderr_buf = stderr_buf .. data
    log.debug('[chrome] stderr: %s', data:gsub('\n', '\\n'))
    if state.port then
      return
    end -- already parsed

    local port, ws_path = parse_devtools_url(stderr_buf)
    if port then
      log.debug('[chrome] parsed DevTools port=%d path=%s', port, ws_path)
      state.port = port
      state.ws_path = ws_path
      stderr:read_stop()
      if not stderr:is_closing() then
        stderr:close()
      end
      if not stdout:is_closing() then
        stdout:close()
      end

      -- Connect to a tab
      connect_tab(function(tab_err, client)
        state.starting = false
        if tab_err then
          local cbs = state.callbacks
          state.callbacks = {}
          for _, cb in ipairs(cbs) do
            cb(tab_err)
          end
          return
        end
        state.client = client
        local cbs = state.callbacks
        state.callbacks = {}
        for _, cb in ipairs(cbs) do
          cb(nil, client)
        end
      end)
    end
  end)
end

--- Get or start the Chrome daemon. Returns a CDP client.
--- callback(err, client)
function M.get_client(callback)
  -- Already running and connected
  if state.client and is_alive() and not state.client.ws.closed then
    callback(nil, state.client)
    return
  end

  -- Dead or disconnected — clean up
  if not is_alive() or (state.client and state.client.ws.closed) then
    M.stop()
  end

  -- Already starting — queue
  if state.starting then
    table.insert(state.callbacks, callback)
    return
  end

  start(callback)
end

-- Kill Chrome on VimLeave
vim.api.nvim_create_autocmd('VimLeave', {
  callback = function()
    M.stop()
  end,
})

return M
