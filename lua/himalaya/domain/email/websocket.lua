--- Minimal RFC 6455 WebSocket client over vim.uv TCP.
--- Only implements what's needed for localhost CDP communication.

local M = {}

--- Build an HTTP upgrade request.
local function build_upgrade(host, port, path, key)
  return table.concat({
    'GET ' .. path .. ' HTTP/1.1',
    'Host: ' .. host .. ':' .. port,
    'Upgrade: websocket',
    'Connection: Upgrade',
    'Sec-WebSocket-Version: 13',
    'Sec-WebSocket-Key: ' .. key,
    '',
    '',
  }, '\r\n')
end

--- Mask payload with a 4-byte key per RFC 6455.
local function mask_payload(data, mask_key)
  local bytes = { data:byte(1, #data) }
  local mk = { mask_key:byte(1, 4) }
  for i = 1, #bytes do
    bytes[i] = bit.bxor(bytes[i], mk[((i - 1) % 4) + 1])
  end
  return string.char(unpack(bytes))
end

--- Build a masked text frame (FIN=1, opcode=0x1).
local function build_text_frame(text)
  local mask_key = vim.uv.random(4)
  local len = #text
  local header
  if len <= 125 then
    header = string.char(0x81, bit.bor(len, 0x80))
  elseif len <= 65535 then
    header = string.char(0x81, bit.bor(126, 0x80), bit.rshift(len, 8), bit.band(len, 0xFF))
  else
    -- 64-bit length: Lua numbers can handle up to 2^53
    header = string.char(
      0x81,
      bit.bor(127, 0x80),
      0,
      0,
      0,
      0,
      bit.band(bit.rshift(len, 24), 0xFF),
      bit.band(bit.rshift(len, 16), 0xFF),
      bit.band(bit.rshift(len, 8), 0xFF),
      bit.band(len, 0xFF)
    )
  end
  return header .. mask_key .. mask_payload(text, mask_key)
end

--- Build a close frame (FIN=1, opcode=0x8).
local function build_close_frame()
  local mask_key = vim.uv.random(4)
  -- Empty close frame: 2-byte header + 4-byte mask key, no payload
  return string.char(0x88, 0x80) .. mask_key
end

--- Connection object
local Conn = {}
Conn.__index = Conn

--- Send a text message.
function Conn:send(text, callback)
  if self.closed then
    if callback then
      callback('connection closed')
    end
    return
  end
  local frame = build_text_frame(text)
  self.tcp:write(frame, callback)
end

--- Receive one complete text message.
--- Calls callback(err, message) with the next complete message.
function Conn:recv(callback)
  if self.closed then
    callback('connection closed')
    return
  end
  table.insert(self.recv_queue, callback)
  self:_drain()
end

--- Try to parse and deliver messages from the buffer.
function Conn:_drain()
  while #self.recv_queue > 0 and #self.buf > 0 do
    local frame_len, payload = self:_try_parse()
    if not frame_len then
      return
    end -- need more data

    self.buf = self.buf:sub(frame_len + 1)
    if payload then
      local cb = table.remove(self.recv_queue, 1)
      cb(nil, payload)
    end
    -- If payload is nil (close/ping frame), loop to try next frame
  end
end

--- Try to parse one frame from self.buf.
--- Returns frame_len, payload on success (payload=nil for control frames).
--- Returns nil if buffer is incomplete.
function Conn:_try_parse()
  local buf = self.buf
  if #buf < 2 then
    return nil
  end

  local b1 = buf:byte(1)
  local b2 = buf:byte(2)
  local opcode = bit.band(b1, 0x0F)
  local payload_len = bit.band(b2, 0x7F)
  local header_len = 2

  if payload_len == 126 then
    if #buf < 4 then
      return nil
    end
    payload_len = bit.lshift(buf:byte(3), 8) + buf:byte(4)
    header_len = 4
  elseif payload_len == 127 then
    if #buf < 10 then
      return nil
    end
    -- Read last 4 bytes (messages won't exceed 4GB)
    payload_len = bit.lshift(buf:byte(7), 24) + bit.lshift(buf:byte(8), 16) + bit.lshift(buf:byte(9), 8) + buf:byte(10)
    header_len = 10
  end

  local frame_len = header_len + payload_len
  if #buf < frame_len then
    return nil
  end

  -- Server frames are NOT masked per RFC 6455
  local payload = buf:sub(header_len + 1, frame_len)

  if opcode == 0x8 then
    -- Close frame
    self:close()
    return frame_len, nil
  elseif opcode == 0x9 then
    -- Ping — send pong
    self:send(payload)
    return frame_len, nil
  end

  -- Text (0x1) or binary (0x2) or continuation (0x0)
  return frame_len, payload
end

--- Close the connection.
function Conn:close()
  if self.closed then
    return
  end
  self.closed = true
  pcall(function()
    self.tcp:write(build_close_frame())
  end)
  pcall(function()
    if not self.tcp:is_closing() then
      self.tcp:read_stop()
      self.tcp:shutdown()
      self.tcp:close()
    end
  end)
  -- Drain remaining recv callbacks with error
  for _, cb in ipairs(self.recv_queue) do
    cb('connection closed')
  end
  self.recv_queue = {}
end

--- Connect to a WebSocket server.
--- callback(err, conn) is called on completion.
function M.connect(host, port, path, callback)
  local tcp = vim.uv.new_tcp()
  local conn = setmetatable({
    tcp = tcp,
    buf = '',
    recv_queue = {},
    closed = false,
    upgraded = false,
  }, Conn)

  tcp:connect(host, port, function(err)
    if err then
      callback('TCP connect failed: ' .. err)
      return
    end

    -- Send HTTP upgrade
    local key = vim.base64.encode(vim.uv.random(16))
    local req = build_upgrade(host, port, path, key)
    tcp:write(req)

    -- Start reading
    tcp:read_start(function(read_err, data)
      if read_err then
        if not conn.closed then
          conn.closed = true
          -- Notify pending recv callbacks
          for _, cb in ipairs(conn.recv_queue) do
            cb('read error: ' .. read_err)
          end
          conn.recv_queue = {}
        end
        return
      end

      if not data then
        -- EOF
        if not conn.closed then
          conn.closed = true
          for _, cb in ipairs(conn.recv_queue) do
            cb('connection closed')
          end
          conn.recv_queue = {}
        end
        return
      end

      if not conn.upgraded then
        conn.buf = conn.buf .. data
        local header_end = conn.buf:find('\r\n\r\n')
        if header_end then
          local header = conn.buf:sub(1, header_end - 1)
          if not header:match('^HTTP/1%.1 101') then
            conn.closed = true
            callback('WebSocket upgrade failed: ' .. header:match('^[^\r\n]+'))
            return
          end
          conn.upgraded = true
          conn.buf = conn.buf:sub(header_end + 4)
          callback(nil, conn)
          -- Drain any frames that arrived with the upgrade response
          conn:_drain()
        end
      else
        conn.buf = conn.buf .. data
        conn:_drain()
      end
    end)
  end)
end

return M
