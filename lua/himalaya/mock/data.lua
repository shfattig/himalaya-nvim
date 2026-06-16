local M = {}

--- Resolve the fixtures directory path relative to this file.
local function fixtures_dir()
  local info = debug.getinfo(1, 'S')
  local src = info.source:gsub('^@', '')
  local plugin_root = vim.fn.fnamemodify(src, ':h:h:h:h')
  return plugin_root .. '/tests/fixtures'
end

local _fixtures_dir = nil
local function get_fixtures_dir()
  if not _fixtures_dir then
    _fixtures_dir = fixtures_dir()
  end
  return _fixtures_dir
end

--- Read a file and return its contents, or nil on failure.
local function read_file(path)
  local f = io.open(path, 'r')
  if not f then
    return nil
  end
  local content = f:read('*a')
  f:close()
  return content
end

--- Read and decode a JSON fixture file.
local function read_json(relative_path)
  local content = read_file(get_fixtures_dir() .. '/' .. relative_path)
  if not content then
    return nil
  end
  local ok, data = pcall(vim.json.decode, content)
  if not ok then
    return nil
  end
  return data
end

--- Read a plain text fixture file.
local function read_plain(relative_path)
  return read_file(get_fixtures_dir() .. '/' .. relative_path)
end

--- @return table[]
function M.accounts()
  return read_json('json/account-list.json') or {}
end

--- @return table[]
function M.folders()
  return read_json('json/folder-list.json') or {}
end

--- Return envelopes for a folder, paginated.
--- @param folder string
--- @param page_size number
--- @param page number
--- @param filter function|nil
--- @return table[]
function M.envelopes(folder, page_size, page, filter)
  local envs
  if folder == 'INBOX' or folder == '' then
    envs = read_json('json/envelope-list-inbox.json')
  elseif folder == 'Sent' then
    envs = read_json('json/envelope-list-sent.json')
  elseif folder == 'Drafts' then
    envs = read_json('json/envelope-list-drafts.json')
  end
  envs = envs or {}

  if filter then
    local filtered = {}
    for _, e in ipairs(envs) do
      if filter(e) then
        filtered[#filtered + 1] = e
      end
    end
    envs = filtered
  end

  local start = (page - 1) * page_size + 1
  local result = {}
  for i = start, math.min(#envs, start + page_size - 1) do
    result[#result + 1] = envs[i]
  end
  return result
end

--- Return thread edges for a folder.
--- Each edge is {parent_env, child_env, depth}.
--- @param folder string
--- @return table[]
function M.thread_edges(folder)
  if folder ~= 'INBOX' and folder ~= '' then
    return {}
  end
  return read_json('json/envelope-thread-inbox.json') or {}
end

--- Return a mock email body.
--- @param id string|number
--- @return string
function M.message_body(id)
  id = tostring(tonumber(id) or id)
  local content = read_plain('plain/message-read-' .. id .. '.txt')
  return content or 'Message not found.\n'
end

--- Return a compose template for a new email.
--- @return string
function M.write_template()
  return read_plain('plain/template-write.txt') or 'From: \nTo: \nSubject: \n\n'
end

--- Return a reply template.
--- @param id string|number
--- @return string
function M.reply_template(id)
  id = tostring(tonumber(id) or id)
  local content = read_plain('plain/template-reply-' .. id .. '.txt')
  return content or M.write_template()
end

--- Return a reply-all template.
--- @param id string|number
--- @return string
function M.reply_all_template(id)
  id = tostring(tonumber(id) or id)
  local content = read_plain('plain/template-reply-all-' .. id .. '.txt')
  return content or M.reply_template(id)
end

--- Return a forward template.
--- @param id string|number
--- @return string
function M.forward_template(id)
  id = tostring(tonumber(id) or id)
  local content = read_plain('plain/template-forward-' .. id .. '.txt')
  return content or M.write_template()
end

return M
