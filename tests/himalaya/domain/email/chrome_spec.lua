describe('himalaya.domain.email.chrome', function()
  local chrome
  local spawned_args
  local spawn_handle
  local stderr_cb
  local spawn_exit_cb
  local autocmd_callbacks = {}

  local function make_fake_cdp_client()
    return {
      ws = { closed = false },
      close = function(self)
        self.ws.closed = true
      end,
      send = function() end,
    }
  end

  local orig_spawn, orig_new_pipe, orig_new_tcp, orig_create_autocmd

  before_each(function()
    spawned_args = nil
    stderr_cb = nil
    spawn_exit_cb = nil
    spawn_handle = {
      _closing = false,
      kill = function(self)
        self._closing = true
      end,
      close = function(self)
        self._closing = true
      end,
      is_closing = function(self)
        return self._closing
      end,
    }

    orig_spawn = vim.uv.spawn
    orig_new_pipe = vim.uv.new_pipe
    orig_new_tcp = vim.uv.new_tcp
    orig_create_autocmd = vim.api.nvim_create_autocmd

    for k in pairs(package.loaded) do
      if k:match('^himalaya') then
        package.loaded[k] = nil
      end
    end

    package.loaded['himalaya.config'] = {
      get = function()
        return {
          render_html = {
            binary = 'chrome-headless-shell',
            pixels_per_column = 8,
            device_scale_factor = 2,
            max_screenshot_height = 5000,
          },
        }
      end,
    }

    package.loaded['himalaya.log'] = {
      info = function() end,
      warn = function() end,
      err = function() end,
      debug = function() end,
    }

    package.loaded['himalaya.domain.email.websocket'] = {
      connect = function(_host, _port, _path, callback)
        local fake_ws = {
          closed = false,
          close = function(self)
            self.closed = true
          end,
          send = function() end,
          recv = function() end,
        }
        callback(nil, fake_ws)
      end,
    }

    package.loaded['himalaya.domain.email.cdp'] = {
      new = function(ws_conn)
        local client = make_fake_cdp_client()
        client.ws = ws_conn
        client.send = function(_self, _method, _params, cb)
          if cb then
            cb(nil, {})
          end
        end
        return client
      end,
    }

    local fake_stdout = {
      read_start = function() end,
      close = function() end,
      is_closing = function()
        return false
      end,
    }
    local fake_stderr = {
      read_start = function(_self, cb)
        stderr_cb = cb
      end,
      read_stop = function() end,
      close = function() end,
      is_closing = function()
        return false
      end,
    }

    vim.uv.spawn = function(cmd, opts, exit_cb)
      spawned_args = { cmd = cmd, args = opts.args }
      spawn_exit_cb = exit_cb
      return spawn_handle, 12345
    end

    local pipe_call = 0
    vim.uv.new_pipe = function()
      pipe_call = pipe_call + 1
      if pipe_call % 2 == 1 then
        return fake_stdout
      else
        return fake_stderr
      end
    end

    vim.uv.new_tcp = function()
      return {
        connect = function(_self, _host, _port, cb)
          cb(nil)
        end,
        write = function() end,
        read_start = function(_self, cb)
          local tab_response = vim.json.encode({
            webSocketDebuggerUrl = 'ws://127.0.0.1:9222/devtools/page/ABC',
          })
          local http_response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n' .. tab_response
          cb(nil, http_response)
        end,
        read_stop = function() end,
        close = function() end,
        is_closing = function()
          return false
        end,
      }
    end

    autocmd_callbacks = {}
    vim.api.nvim_create_autocmd = function(event, opts)
      table.insert(autocmd_callbacks, { event = event, callback = opts.callback })
      return #autocmd_callbacks
    end

    chrome = require('himalaya.domain.email.chrome')
  end)

  after_each(function()
    vim.uv.spawn = orig_spawn
    vim.uv.new_pipe = orig_new_pipe
    vim.uv.new_tcp = orig_new_tcp
    vim.api.nvim_create_autocmd = orig_create_autocmd
  end)

  describe('get_client', function()
    it('spawns chrome-headless-shell with correct args', function()
      chrome.get_client(function() end)
      assert.is_not_nil(spawned_args)
      assert.are.equal('chrome-headless-shell', spawned_args.cmd)
      assert.truthy(vim.tbl_contains(spawned_args.args, '--remote-debugging-port=0'))
      assert.truthy(vim.tbl_contains(spawned_args.args, '--no-sandbox'))
      assert.truthy(vim.tbl_contains(spawned_args.args, '--disable-gpu'))
    end)

    it('returns CDP client after parsing DevTools URL', function()
      local result_err, result_client
      chrome.get_client(function(err, client)
        result_err = err
        result_client = client
      end)

      assert.is_not_nil(stderr_cb)
      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc-123\n')

      assert.is_nil(result_err)
      assert.is_not_nil(result_client)
    end)

    it('queues multiple callbacks while starting', function()
      local results = {}
      chrome.get_client(function(err, client)
        table.insert(results, { err = err, client = client })
      end)
      chrome.get_client(function(err, client)
        table.insert(results, { err = err, client = client })
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      assert.are.equal(2, #results)
      assert.is_nil(results[1].err)
      assert.is_nil(results[2].err)
      assert.is_not_nil(results[1].client)
      assert.is_not_nil(results[2].client)
    end)

    it('reuses existing client on subsequent calls', function()
      local client1
      chrome.get_client(function(_err, client)
        client1 = client
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')
      assert.is_not_nil(client1)

      local client2
      chrome.get_client(function(_err, client)
        client2 = client
      end)

      assert.are.equal(client1, client2)
    end)
  end)

  describe('stop', function()
    it('kills the chrome process', function()
      chrome.get_client(function() end)
      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      chrome.stop()
      assert.is_true(spawn_handle._closing)
    end)

    it('is safe to call when not started', function()
      chrome.stop()
    end)

    it('closes the CDP client', function()
      local client
      chrome.get_client(function(_err, c)
        client = c
      end)
      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      chrome.stop()
      assert.is_true(client.ws.closed)
    end)
  end)

  describe('VimLeave autocmd', function()
    it('registers a VimLeave autocmd', function()
      local vim_leave = false
      for _, ac in ipairs(autocmd_callbacks) do
        if ac.event == 'VimLeave' then
          vim_leave = true
        end
      end
      assert.is_true(vim_leave)
    end)

    it('VimLeave callback calls stop', function()
      -- Start chrome so there is state to clean up
      chrome.get_client(function() end)
      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      -- Find and invoke the VimLeave callback
      for _, ac in ipairs(autocmd_callbacks) do
        if ac.event == 'VimLeave' then
          ac.callback()
        end
      end

      assert.is_true(spawn_handle._closing)
    end)
  end)

  describe('crash recovery', function()
    it('restarts Chrome when process has exited', function()
      local client1
      chrome.get_client(function(_err, c)
        client1 = c
      end)
      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')
      assert.is_not_nil(client1)

      spawn_exit_cb(1, 0)
      client1.ws.closed = true

      local pipe_count = 0
      local new_stderr_cb
      vim.uv.new_pipe = function()
        pipe_count = pipe_count + 1
        if pipe_count % 2 == 1 then
          return {
            read_start = function() end,
            close = function() end,
            is_closing = function()
              return false
            end,
          }
        else
          return {
            read_start = function(_self, cb)
              new_stderr_cb = cb
            end,
            read_stop = function() end,
            close = function() end,
            is_closing = function()
              return false
            end,
          }
        end
      end

      spawn_handle = {
        _closing = false,
        kill = function(self)
          self._closing = true
        end,
        close = function(self)
          self._closing = true
        end,
        is_closing = function(self)
          return self._closing
        end,
      }

      local client2
      chrome.get_client(function(_err, c)
        client2 = c
      end)

      assert.is_not_nil(new_stderr_cb)
      new_stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9333/devtools/browser/def\n')

      assert.is_not_nil(client2)
      assert.are_not.equal(client1, client2)
    end)
  end)

  describe('spawn failure', function()
    it('calls callback with error when spawn fails', function()
      vim.uv.spawn = function()
        return nil, 'ENOENT'
      end

      for k in pairs(package.loaded) do
        if k:match('^himalaya%.domain%.email%.chrome') then
          package.loaded[k] = nil
        end
      end
      chrome = require('himalaya.domain.email.chrome')

      local result_err
      chrome.get_client(function(err, _client)
        result_err = err
      end)

      assert.truthy(result_err)
      assert.truthy(result_err:find('failed to spawn'))
    end)
  end)

  describe('parse_devtools_url edge cases', function()
    it('ignores non-DevTools stderr output', function()
      local result_client
      chrome.get_client(function(_err, client)
        result_client = client
      end)

      stderr_cb(nil, '[WARNING] some chrome warning\n')
      assert.is_nil(result_client)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/xyz\n')
      assert.is_not_nil(result_client)
    end)
  end)

  describe('connect_tab error paths', function()
    it('calls callback with error when TCP connect to tab fails', function()
      vim.uv.new_tcp = function()
        return {
          connect = function(_self, _host, _port, cb)
            cb('ECONNREFUSED')
          end,
          write = function() end,
          read_start = function() end,
          read_stop = function() end,
          close = function() end,
          is_closing = function()
            return false
          end,
        }
      end

      local result_err
      chrome.get_client(function(err, _client)
        result_err = err
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      assert.truthy(result_err)
      assert.truthy(result_err:find('tab connect failed'))
    end)

    it('calls callback with error on read_err from tab HTTP request', function()
      vim.uv.new_tcp = function()
        return {
          connect = function(_self, _host, _port, cb)
            cb(nil)
          end,
          write = function() end,
          read_start = function(_self, cb)
            cb('ECONNRESET', nil)
          end,
          read_stop = function() end,
          close = function() end,
          is_closing = function()
            return false
          end,
        }
      end

      local result_err
      chrome.get_client(function(err, _client)
        result_err = err
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      assert.truthy(result_err)
      assert.truthy(result_err:find('tab read error'))
    end)

    it('calls callback with error on EOF with unparseable response body', function()
      vim.uv.new_tcp = function()
        return {
          connect = function(_self, _host, _port, cb)
            cb(nil)
          end,
          write = function() end,
          read_start = function(_self, cb)
            -- Send data that does NOT end with } so the inline path doesn't trigger
            cb(nil, 'HTTP/1.1 200 OK\r\n\r\nnot-json-at-all')
            cb(nil, nil) -- EOF triggers the EOF branch
          end,
          read_stop = function() end,
          close = function() end,
          is_closing = function()
            return false
          end,
        }
      end

      local result_err
      chrome.get_client(function(err, _client)
        result_err = err
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      assert.truthy(result_err)
      assert.truthy(result_err:find('invalid /json/new response'))
    end)

    it('calls callback with error on EOF with no body', function()
      vim.uv.new_tcp = function()
        return {
          connect = function(_self, _host, _port, cb)
            cb(nil)
          end,
          write = function() end,
          read_start = function(_self, cb)
            -- No \r\n\r\n separator, so body extraction fails
            cb(nil, 'HTTP/1.1 200 OK\r\nContent-Length: 0')
            cb(nil, nil) -- EOF
          end,
          read_stop = function() end,
          close = function() end,
          is_closing = function()
            return false
          end,
        }
      end

      local result_err
      chrome.get_client(function(err, _client)
        result_err = err
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      assert.truthy(result_err)
      assert.truthy(result_err:find('failed to parse'))
    end)

    it('calls callback with error on EOF when tab has no webSocketDebuggerUrl', function()
      vim.uv.new_tcp = function()
        return {
          connect = function(_self, _host, _port, cb)
            cb(nil)
          end,
          write = function() end,
          read_start = function(_self, cb)
            -- Send partial data (no trailing }) so inline path does not trigger
            local tab_response = vim.json.encode({ id = 'page1' })
            cb(nil, 'HTTP/1.1 200 OK\r\n\r\n' .. tab_response .. ' ')
            cb(nil, nil) -- EOF
          end,
          read_stop = function() end,
          close = function() end,
          is_closing = function()
            return false
          end,
        }
      end

      local result_err
      chrome.get_client(function(err, _client)
        result_err = err
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      assert.truthy(result_err)
      assert.truthy(result_err:find('invalid /json/new response'))
    end)

    it('calls callback with error on EOF when WS URL cannot be parsed', function()
      vim.uv.new_tcp = function()
        return {
          connect = function(_self, _host, _port, cb)
            cb(nil)
          end,
          write = function() end,
          read_start = function(_self, cb)
            -- Valid JSON with webSocketDebuggerUrl that doesn't match the ws:// pattern
            local tab_response = vim.json.encode({ webSocketDebuggerUrl = 'not-a-ws-url' })
            cb(nil, 'HTTP/1.1 200 OK\r\n\r\n' .. tab_response .. ' ')
            cb(nil, nil) -- EOF
          end,
          read_stop = function() end,
          close = function() end,
          is_closing = function()
            return false
          end,
        }
      end

      local result_err
      chrome.get_client(function(err, _client)
        result_err = err
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      assert.truthy(result_err)
      assert.truthy(result_err:find('cannot parse tab WS URL'))
    end)

    it('connects via EOF path with valid tab response', function()
      vim.uv.new_tcp = function()
        return {
          connect = function(_self, _host, _port, cb)
            cb(nil)
          end,
          write = function() end,
          read_start = function(_self, cb)
            local tab_response = vim.json.encode({
              webSocketDebuggerUrl = 'ws://127.0.0.1:9222/devtools/page/EOF1',
            })
            -- Append a space so the inline }$ check doesn't match
            cb(nil, 'HTTP/1.1 200 OK\r\n\r\n' .. tab_response .. ' ')
            cb(nil, nil) -- EOF
          end,
          read_stop = function() end,
          close = function() end,
          is_closing = function()
            return false
          end,
        }
      end

      local result_err, result_client
      chrome.get_client(function(err, client)
        result_err = err
        result_client = client
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      assert.is_nil(result_err)
      assert.is_not_nil(result_client)
    end)

    it('calls callback with error on EOF when WS connect fails', function()
      package.loaded['himalaya.domain.email.websocket'] = {
        connect = function(_host, _port, _path, callback)
          callback('ECONNREFUSED')
        end,
      }

      for k in pairs(package.loaded) do
        if k:match('^himalaya%.domain%.email%.chrome') then
          package.loaded[k] = nil
        end
      end
      chrome = require('himalaya.domain.email.chrome')

      vim.uv.new_tcp = function()
        return {
          connect = function(_self, _host, _port, cb)
            cb(nil)
          end,
          write = function() end,
          read_start = function(_self, cb)
            local tab_response = vim.json.encode({
              webSocketDebuggerUrl = 'ws://127.0.0.1:9222/devtools/page/X',
            })
            cb(nil, 'HTTP/1.1 200 OK\r\n\r\n' .. tab_response .. ' ')
            cb(nil, nil) -- EOF
          end,
          read_stop = function() end,
          close = function() end,
          is_closing = function()
            return false
          end,
        }
      end

      local result_err
      chrome.get_client(function(err, _client)
        result_err = err
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      assert.truthy(result_err)
      assert.truthy(result_err:find('WS connect failed'))
    end)

    it('calls callback with error on EOF when Page.enable fails', function()
      package.loaded['himalaya.domain.email.cdp'] = {
        new = function(ws_conn)
          local client = make_fake_cdp_client()
          client.ws = ws_conn
          client.send = function(_self, method, _params, cb)
            if method == 'Page.enable' and cb then
              cb('enable failed')
            end
          end
          return client
        end,
      }

      for k in pairs(package.loaded) do
        if k:match('^himalaya%.domain%.email%.chrome') then
          package.loaded[k] = nil
        end
      end
      chrome = require('himalaya.domain.email.chrome')

      vim.uv.new_tcp = function()
        return {
          connect = function(_self, _host, _port, cb)
            cb(nil)
          end,
          write = function() end,
          read_start = function(_self, cb)
            local tab_response = vim.json.encode({
              webSocketDebuggerUrl = 'ws://127.0.0.1:9222/devtools/page/Y',
            })
            cb(nil, 'HTTP/1.1 200 OK\r\n\r\n' .. tab_response .. ' ')
            cb(nil, nil) -- EOF
          end,
          read_stop = function() end,
          close = function() end,
          is_closing = function()
            return false
          end,
        }
      end

      local result_err
      chrome.get_client(function(err, _client)
        result_err = err
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      assert.truthy(result_err)
      assert.truthy(result_err:find('Page.enable failed'))
    end)

    it('calls callback with error when inline response has invalid JSON', function()
      vim.uv.new_tcp = function()
        return {
          connect = function(_self, _host, _port, cb)
            cb(nil)
          end,
          write = function() end,
          read_start = function(_self, cb)
            cb(nil, 'HTTP/1.1 200 OK\r\n\r\n{bad json}')
          end,
          read_stop = function() end,
          close = function() end,
          is_closing = function()
            return false
          end,
        }
      end

      local result_err
      chrome.get_client(function(err, _client)
        result_err = err
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      assert.truthy(result_err)
      assert.truthy(result_err:find('invalid /json/new response'))
    end)

    it('calls callback with error when inline response has no webSocketDebuggerUrl', function()
      vim.uv.new_tcp = function()
        return {
          connect = function(_self, _host, _port, cb)
            cb(nil)
          end,
          write = function() end,
          read_start = function(_self, cb)
            local tab_response = vim.json.encode({ id = 'page1' })
            cb(nil, 'HTTP/1.1 200 OK\r\n\r\n' .. tab_response)
          end,
          read_stop = function() end,
          close = function() end,
          is_closing = function()
            return false
          end,
        }
      end

      local result_err
      chrome.get_client(function(err, _client)
        result_err = err
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      assert.truthy(result_err)
      assert.truthy(result_err:find('invalid /json/new response'))
    end)

    it('calls callback with error when inline response WS URL cannot be parsed', function()
      vim.uv.new_tcp = function()
        return {
          connect = function(_self, _host, _port, cb)
            cb(nil)
          end,
          write = function() end,
          read_start = function(_self, cb)
            local tab_response = vim.json.encode({ webSocketDebuggerUrl = 'not-a-ws-url' })
            cb(nil, 'HTTP/1.1 200 OK\r\n\r\n' .. tab_response)
          end,
          read_stop = function() end,
          close = function() end,
          is_closing = function()
            return false
          end,
        }
      end

      local result_err
      chrome.get_client(function(err, _client)
        result_err = err
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      assert.truthy(result_err)
      assert.truthy(result_err:find('cannot parse tab WS URL'))
    end)

    it('calls callback with error when WS connect fails', function()
      package.loaded['himalaya.domain.email.websocket'] = {
        connect = function(_host, _port, _path, callback)
          callback('ECONNREFUSED')
        end,
      }

      -- Need to reload chrome to pick up new websocket mock
      for k in pairs(package.loaded) do
        if k:match('^himalaya%.domain%.email%.chrome') then
          package.loaded[k] = nil
        end
      end
      chrome = require('himalaya.domain.email.chrome')

      local result_err
      chrome.get_client(function(err, _client)
        result_err = err
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      assert.truthy(result_err)
      assert.truthy(result_err:find('WS connect failed'))
    end)

    it('calls callback with error when Page.enable fails', function()
      package.loaded['himalaya.domain.email.cdp'] = {
        new = function(ws_conn)
          local client = make_fake_cdp_client()
          client.ws = ws_conn
          client.send = function(_self, method, _params, cb)
            if method == 'Page.enable' and cb then
              cb('enable failed')
            end
          end
          return client
        end,
      }

      for k in pairs(package.loaded) do
        if k:match('^himalaya%.domain%.email%.chrome') then
          package.loaded[k] = nil
        end
      end
      chrome = require('himalaya.domain.email.chrome')

      local result_err
      chrome.get_client(function(err, _client)
        result_err = err
      end)

      stderr_cb(nil, 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/abc\n')

      assert.truthy(result_err)
      assert.truthy(result_err:find('Page.enable failed'))
    end)

    it('handles stderr err/EOF gracefully', function()
      local result_err
      chrome.get_client(function(err, _client)
        result_err = err
      end)

      -- stderr error or EOF should not crash
      stderr_cb('read error', nil)
      stderr_cb(nil, nil)

      -- No client should have been returned, but no crash
      assert.is_nil(result_err)
    end)
  end)
end)
