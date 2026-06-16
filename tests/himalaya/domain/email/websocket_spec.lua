describe('himalaya.domain.email.websocket', function()
  local ws

  before_each(function()
    package.loaded['himalaya.domain.email.websocket'] = nil
    ws = require('himalaya.domain.email.websocket')
  end)

  describe('frame parsing via connect', function()
    local fake_tcp_instance
    local read_callback
    local connect_callback
    local orig_new_tcp

    before_each(function()
      orig_new_tcp = vim.uv.new_tcp
      fake_tcp_instance = {
        _written = {},
        connect = function(_self, _host, _port, cb)
          connect_callback = cb
        end,
        write = function(self, data, cb)
          table.insert(self._written, data)
          if cb then
            cb()
          end
        end,
        read_start = function(_self, cb)
          read_callback = cb
        end,
        read_stop = function() end,
        shutdown = function() end,
        close = function() end,
        is_closing = function()
          return false
        end,
      }

      vim.uv.new_tcp = function()
        return fake_tcp_instance
      end
    end)

    after_each(function()
      vim.uv.new_tcp = orig_new_tcp
    end)

    it('calls callback with connection on successful upgrade', function()
      local result_err, result_conn
      ws.connect('127.0.0.1', 9222, '/devtools/page/1', function(err, conn)
        result_err = err
        result_conn = conn
      end)

      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n')

      assert.is_nil(result_err)
      assert.is_not_nil(result_conn)
    end)

    it('calls callback with error on non-101 response', function()
      local result_err
      ws.connect('127.0.0.1', 9222, '/devtools/page/1', function(err, _conn)
        result_err = err
      end)

      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 400 Bad Request\r\n\r\n')

      assert.truthy(result_err)
      assert.truthy(result_err:find('upgrade failed'))
    end)

    it('calls callback with error on TCP connect failure', function()
      local result_err
      ws.connect('127.0.0.1', 9222, '/path', function(err, _conn)
        result_err = err
      end)

      connect_callback('ECONNREFUSED')

      assert.truthy(result_err)
      assert.truthy(result_err:find('TCP connect failed'))
    end)

    it('receives a text frame after upgrade', function()
      local conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, c)
        conn = c
      end)
      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\n\r\n')
      assert.is_not_nil(conn)

      local recv_err, recv_msg
      conn:recv(function(err, msg)
        recv_err = err
        recv_msg = msg
      end)

      local payload = 'hello'
      local frame = string.char(0x81, #payload) .. payload
      read_callback(nil, frame)

      assert.is_nil(recv_err)
      assert.are.equal('hello', recv_msg)
    end)

    it('receives a frame with 16-bit length', function()
      local conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, c)
        conn = c
      end)
      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\n\r\n')

      local recv_msg
      conn:recv(function(_err, msg)
        recv_msg = msg
      end)

      local payload = string.rep('x', 200)
      local frame = string.char(0x81, 126, 0, 200) .. payload
      read_callback(nil, frame)

      assert.are.equal(200, #recv_msg)
    end)

    it('handles partial frames across multiple TCP reads', function()
      local conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, c)
        conn = c
      end)
      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\n\r\n')

      local recv_msg
      conn:recv(function(_err, msg)
        recv_msg = msg
      end)

      local payload = 'hello world'
      local frame = string.char(0x81, #payload) .. payload
      read_callback(nil, frame:sub(1, 2))
      assert.is_nil(recv_msg)

      read_callback(nil, frame:sub(3))
      assert.are.equal('hello world', recv_msg)
    end)

    it('handles multiple frames in a single TCP read', function()
      local conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, c)
        conn = c
      end)
      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\n\r\n')

      local msgs = {}
      conn:recv(function(_err, msg)
        table.insert(msgs, msg)
      end)
      conn:recv(function(_err, msg)
        table.insert(msgs, msg)
      end)

      local frame1 = string.char(0x81, 2) .. 'ab'
      local frame2 = string.char(0x81, 2) .. 'cd'
      read_callback(nil, frame1 .. frame2)

      assert.are.equal(2, #msgs)
      assert.are.equal('ab', msgs[1])
      assert.are.equal('cd', msgs[2])
    end)

    it('send returns error when connection is closed', function()
      local conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, c)
        conn = c
      end)
      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\n\r\n')

      conn:close()

      local send_err
      conn:send('test', function(err)
        send_err = err
      end)
      assert.are.equal('connection closed', send_err)
    end)

    it('recv returns error when connection is closed', function()
      local conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, c)
        conn = c
      end)
      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\n\r\n')

      conn:close()

      local recv_err
      conn:recv(function(err, _msg)
        recv_err = err
      end)
      assert.are.equal('connection closed', recv_err)
    end)

    it('drains pending recv callbacks on EOF', function()
      local conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, c)
        conn = c
      end)
      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\n\r\n')

      local recv_err
      conn:recv(function(err, _msg)
        recv_err = err
      end)

      read_callback(nil, nil)

      assert.truthy(recv_err)
      assert.truthy(recv_err:find('closed'))
    end)

    it('drains pending recv callbacks on read error', function()
      local conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, c)
        conn = c
      end)
      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\n\r\n')

      local recv_err
      conn:recv(function(err, _msg)
        recv_err = err
      end)

      read_callback('ECONNRESET', nil)

      assert.truthy(recv_err)
      assert.truthy(recv_err:find('read error'))
    end)

    it('handles close frame from server', function()
      local conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, c)
        conn = c
      end)
      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\n\r\n')

      local recv_err
      conn:recv(function(err, _msg)
        recv_err = err
      end)

      local close_frame = string.char(0x88, 0)
      read_callback(nil, close_frame)

      assert.is_true(conn.closed)
      assert.truthy(recv_err)
    end)

    it('close is idempotent', function()
      local conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, c)
        conn = c
      end)
      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\n\r\n')

      conn:close()
      conn:close()
      assert.is_true(conn.closed)
    end)

    it('buffers upgrade response arriving in chunks', function()
      local result_conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, conn)
        result_conn = conn
      end)
      connect_callback(nil)

      read_callback(nil, 'HTTP/1.1 101 Switching')
      assert.is_nil(result_conn)

      read_callback(nil, ' Protocols\r\nUpgrade: websocket\r\n\r\n')
      assert.is_not_nil(result_conn)
    end)

    it('delivers frames that arrive with the upgrade response', function()
      local conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, c)
        conn = c
      end)
      connect_callback(nil)

      local recv_msg
      local payload = 'early'
      local frame = string.char(0x81, #payload) .. payload
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\n\r\n' .. frame)
      assert.is_not_nil(conn)

      conn:recv(function(_err, msg)
        recv_msg = msg
      end)
      assert.are.equal('early', recv_msg)
    end)

    it('send writes a frame to TCP on a live connection', function()
      local conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, c)
        conn = c
      end)
      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\n\r\n')
      assert.is_not_nil(conn)

      -- Record how many writes happened before send (upgrade request is already written)
      local writes_before = #fake_tcp_instance._written

      local send_err
      conn:send('hello', function(err)
        send_err = err
      end)

      assert.is_nil(send_err)
      assert.is_true(#fake_tcp_instance._written > writes_before)
    end)

    it('send without callback on a live connection does not error', function()
      local conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, c)
        conn = c
      end)
      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\n\r\n')

      local writes_before = #fake_tcp_instance._written
      conn:send('no-callback')
      assert.is_true(#fake_tcp_instance._written > writes_before)
    end)

    it('send without callback on closed connection does not error', function()
      local conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, c)
        conn = c
      end)
      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\n\r\n')

      conn:close()
      -- Should not raise; no callback means the early return just exits silently
      conn:send('test')
    end)

    it('receives a frame with 64-bit length header', function()
      local conn
      ws.connect('127.0.0.1', 9222, '/path', function(_err, c)
        conn = c
      end)
      connect_callback(nil)
      read_callback(nil, 'HTTP/1.1 101 Switching Protocols\r\n\r\n')

      local recv_msg
      conn:recv(function(_err, msg)
        recv_msg = msg
      end)

      -- Payload larger than 65535 to trigger the 64-bit length branch
      local payload = string.rep('x', 70000)
      local len = #payload
      local header = string.char(
        0x81,
        127,
        0,
        0,
        0,
        0,
        bit.band(bit.rshift(len, 24), 0xFF),
        bit.band(bit.rshift(len, 16), 0xFF),
        bit.band(bit.rshift(len, 8), 0xFF),
        bit.band(len, 0xFF)
      )
      local frame = header .. payload
      read_callback(nil, frame)

      assert.are.equal(70000, #recv_msg)
    end)
  end)
end)
