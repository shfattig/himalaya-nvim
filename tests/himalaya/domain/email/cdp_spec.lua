describe('himalaya.domain.email.cdp', function()
  local cdp

  before_each(function()
    package.loaded['himalaya.domain.email.cdp'] = nil
    cdp = require('himalaya.domain.email.cdp')
  end)

  local function make_fake_ws()
    local ws = {
      closed = false,
      sent = {},
      recv_cbs = {},
    }
    function ws:send(text, callback)
      table.insert(self.sent, text)
      if callback then
        callback()
      end
    end
    function ws:recv(callback)
      table.insert(self.recv_cbs, callback)
    end
    function ws:close()
      self.closed = true
    end
    function ws:deliver(text)
      if #self.recv_cbs > 0 then
        local cb = table.remove(self.recv_cbs, 1)
        cb(nil, text)
      end
    end
    function ws:deliver_error(err)
      if #self.recv_cbs > 0 then
        local cb = table.remove(self.recv_cbs, 1)
        cb(err)
      end
    end
    return ws
  end

  describe('new', function()
    it('creates a client and starts pumping', function()
      local ws = make_fake_ws()
      local client = cdp.new(ws)
      assert.is_not_nil(client)
      assert.are.equal(1, #ws.recv_cbs)
    end)
  end)

  describe('send', function()
    it('sends JSON-RPC message with auto-incrementing id', function()
      local ws = make_fake_ws()
      local client = cdp.new(ws)

      client:send('Page.navigate', { url = 'about:blank' })
      client:send('Runtime.evaluate', { expression = '1+1' })

      assert.are.equal(2, #ws.sent)

      local msg1 = vim.json.decode(ws.sent[1])
      assert.are.equal(1, msg1.id)
      assert.are.equal('Page.navigate', msg1.method)
      assert.are.equal('about:blank', msg1.params.url)

      local msg2 = vim.json.decode(ws.sent[2])
      assert.are.equal(2, msg2.id)
      assert.are.equal('Runtime.evaluate', msg2.method)
    end)

    it('calls callback with result on success response', function()
      local ws = make_fake_ws()
      local client = cdp.new(ws)

      local result_err, result_data
      client:send('Page.navigate', { url = 'about:blank' }, function(err, result)
        result_err = err
        result_data = result
      end)

      ws:deliver(vim.json.encode({ id = 1, result = { frameId = 'abc' } }))

      assert.is_nil(result_err)
      assert.are.equal('abc', result_data.frameId)
    end)

    it('calls callback with error on error response', function()
      local ws = make_fake_ws()
      local client = cdp.new(ws)

      local result_err
      client:send('Bad.method', {}, function(err, _result)
        result_err = err
      end)

      ws:deliver(vim.json.encode({ id = 1, error = { message = 'Method not found' } }))

      assert.are.equal('Method not found', result_err)
    end)

    it('routes responses to correct callbacks by id', function()
      local ws = make_fake_ws()
      local client = cdp.new(ws)

      local results = {}
      client:send('Method.A', {}, function(_err, result)
        results.a = result
      end)
      client:send('Method.B', {}, function(_err, result)
        results.b = result
      end)

      ws:deliver(vim.json.encode({ id = 2, result = { val = 'B' } }))
      ws:deliver(vim.json.encode({ id = 1, result = { val = 'A' } }))

      assert.are.equal('A', results.a.val)
      assert.are.equal('B', results.b.val)
    end)
  end)

  describe('events', function()
    it('fires once listener and removes it', function()
      local ws = make_fake_ws()
      local client = cdp.new(ws)

      local fired = 0
      local params_received
      client:once('Page.loadEventFired', function(params)
        fired = fired + 1
        params_received = params
      end)

      ws:deliver(vim.json.encode({ method = 'Page.loadEventFired', params = { timestamp = 123 } }))
      assert.are.equal(1, fired)
      assert.are.equal(123, params_received.timestamp)

      ws:deliver(vim.json.encode({ method = 'Page.loadEventFired', params = { timestamp = 456 } }))
      assert.are.equal(1, fired)
    end)

    it('fires persistent on listener multiple times', function()
      local ws = make_fake_ws()
      local client = cdp.new(ws)

      local fired = 0
      client:on('Network.requestWillBeSent', function()
        fired = fired + 1
      end)

      ws:deliver(vim.json.encode({ method = 'Network.requestWillBeSent', params = {} }))
      ws:deliver(vim.json.encode({ method = 'Network.requestWillBeSent', params = {} }))
      ws:deliver(vim.json.encode({ method = 'Network.requestWillBeSent', params = {} }))

      assert.are.equal(3, fired)
    end)

    it('off removes all listeners for a method', function()
      local ws = make_fake_ws()
      local client = cdp.new(ws)

      local fired = 0
      client:on('Page.loadEventFired', function()
        fired = fired + 1
      end)

      ws:deliver(vim.json.encode({ method = 'Page.loadEventFired', params = {} }))
      assert.are.equal(1, fired)

      client:off('Page.loadEventFired')

      ws:deliver(vim.json.encode({ method = 'Page.loadEventFired', params = {} }))
      assert.are.equal(1, fired)
    end)

    it('ignores events with no listeners', function()
      local ws = make_fake_ws()
      cdp.new(ws)

      ws:deliver(vim.json.encode({ method = 'Unknown.event', params = {} }))
    end)

    it('mixes once and on listeners for same event', function()
      local ws = make_fake_ws()
      local client = cdp.new(ws)

      local once_count = 0
      local on_count = 0
      client:once('Page.loadEventFired', function()
        once_count = once_count + 1
      end)
      client:on('Page.loadEventFired', function()
        on_count = on_count + 1
      end)

      ws:deliver(vim.json.encode({ method = 'Page.loadEventFired', params = {} }))
      assert.are.equal(1, once_count)
      assert.are.equal(1, on_count)

      ws:deliver(vim.json.encode({ method = 'Page.loadEventFired', params = {} }))
      assert.are.equal(1, once_count)
      assert.are.equal(2, on_count)
    end)
  end)

  describe('connection loss', function()
    it('notifies pending callbacks on connection error', function()
      local ws = make_fake_ws()
      local client = cdp.new(ws)

      local result_err
      client:send('Page.navigate', {}, function(err, _result)
        result_err = err
      end)

      ws:deliver_error('connection reset')

      assert.truthy(result_err)
      assert.truthy(result_err:find('connection lost'))
    end)
  end)

  describe('close', function()
    it('closes the underlying WebSocket', function()
      local ws = make_fake_ws()
      local client = cdp.new(ws)

      client:close()

      assert.is_true(ws.closed)
    end)
  end)

  describe('send without callback', function()
    it('does not error when no callback is provided', function()
      local ws = make_fake_ws()
      local client = cdp.new(ws)
      client:send('Page.enable')
    end)

    it('ignores response when no callback was registered', function()
      local ws = make_fake_ws()
      local client = cdp.new(ws)

      client:send('Page.enable')

      ws:deliver(vim.json.encode({ id = 1, result = {} }))
    end)
  end)
end)
