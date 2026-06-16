--- CDP (Chrome DevTools Protocol) JSON-RPC client over WebSocket.

local M = {}

local Client = {}
Client.__index = Client

--- Create a new CDP client wrapping a WebSocket connection.
function M.new(ws_conn)
  local self = setmetatable({
    ws = ws_conn,
    next_id = 1,
    callbacks = {}, -- id → callback(err, result)
    listeners = {}, -- method → list of callbacks
  }, Client)
  self:_pump()
  return self
end

--- Send a CDP command.
--- callback(err, result) is called with the response.
function Client:send(method, params, callback)
  local id = self.next_id
  self.next_id = self.next_id + 1

  local msg = vim.json.encode({
    id = id,
    method = method,
    params = params or vim.empty_dict(),
  })

  if callback then
    self.callbacks[id] = callback
  end

  self.ws:send(msg, function(err)
    if err and callback then
      self.callbacks[id] = nil
      callback('send failed: ' .. tostring(err))
    end
  end)
end

--- Register a one-shot event listener.
--- callback(params) is called when the event fires, then removed.
function Client:once(method, callback)
  if not self.listeners[method] then
    self.listeners[method] = {}
  end
  table.insert(self.listeners[method], { cb = callback, once = true })
end

--- Register a persistent event listener.
function Client:on(method, callback)
  if not self.listeners[method] then
    self.listeners[method] = {}
  end
  table.insert(self.listeners[method], { cb = callback, once = false })
end

--- Remove all listeners for a method.
function Client:off(method)
  self.listeners[method] = nil
end

--- Continuously read messages from the WebSocket and dispatch them.
function Client:_pump()
  local function read_next()
    if self.ws.closed then
      return
    end
    self.ws:recv(function(err, data)
      if err then
        -- Connection gone — notify all pending callbacks
        for id, cb in pairs(self.callbacks) do
          self.callbacks[id] = nil
          cb('connection lost: ' .. tostring(err))
        end
        return
      end

      local ok, msg = pcall(vim.json.decode, data)
      if ok and msg then
        if msg.id then
          -- Response to a command
          local cb = self.callbacks[msg.id]
          if cb then
            self.callbacks[msg.id] = nil
            if msg.error then
              cb(msg.error.message or vim.json.encode(msg.error))
            else
              cb(nil, msg.result)
            end
          end
        elseif msg.method then
          -- Event
          local list = self.listeners[msg.method]
          if list then
            local keep = {}
            for _, entry in ipairs(list) do
              entry.cb(msg.params)
              if not entry.once then
                keep[#keep + 1] = entry
              end
            end
            if #keep > 0 then
              self.listeners[msg.method] = keep
            else
              self.listeners[msg.method] = nil
            end
          end
        end
      end

      read_next()
    end)
  end

  read_next()
end

--- Close the CDP client and underlying WebSocket.
function Client:close()
  self.ws:close()
end

return M
