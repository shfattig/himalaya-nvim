local config = require('himalaya.config')

local M = {}

-- Lowercase, matching both `himalaya flag add/remove --flag <FLAG>`'s
-- possible values and the `envelope search` query DSL's `flag <...>`
-- keyword. ('deleted' isn't a valid --flag value in v2, so it's dropped
-- from the old v1-era list this replaced.)
local default_flags = { 'seen', 'answered', 'flagged', 'draft' }

function M.complete_list()
  local cfg = config.get()
  local all = vim.list_extend(vim.deepcopy(default_flags), cfg.custom_flags)
  return all
end

--- Normalize one flags-array entry to a lowercase name, whether it's a
--- bare string (older responses / simple test fixtures) or himalaya v2's
--- real `{raw = "\\Seen", iana = "seen"}` table shape.
--- @param entry string|table
--- @return string
function M.flag_name(entry)
  local name = type(entry) == 'table' and (entry.iana or entry.raw or '') or entry
  return (name:gsub('^\\', '')):lower()
end

--- Case-insensitively check whether a flags array contains the given name.
--- @param flags table[]|string[]
--- @param name string
--- @return boolean
function M.has(flags, name)
  name = name:lower()
  for _, f in ipairs(flags or {}) do
    if M.flag_name(f) == name then
      return true
    end
  end
  return false
end

--- Check whether an envelope is confirmed unseen (has flags but no Seen flag).
--- Returns false when flags are nil (unknown state ≠ unseen).
--- @param env table
--- @return boolean
function M.is_unseen(env)
  local flags = env.flags
  if not flags then
    return false
  end
  return not M.has(flags, 'seen')
end

--- Check whether an envelope has the Seen flag.
--- @param env table
--- @return boolean
function M.is_seen(env)
  return not M.is_unseen(env)
end

--- Count unseen envelopes in a flat list.
--- @param envelopes table[]
--- @return number
function M.count_unseen(envelopes)
  local n = 0
  for _, env in ipairs(envelopes) do
    if M.is_unseen(env) then
      n = n + 1
    end
  end
  return n
end

--- Count unseen envelopes in a list of display rows (where each row has an .env field).
--- @param rows table[]
--- @return number
function M.count_unseen_rows(rows)
  local n = 0
  for _, row in ipairs(rows) do
    if M.is_unseen(row.env) then
      n = n + 1
    end
  end
  return n
end

--- Log a per-page flag summary when vim.g.himalaya_debug is set.
--- @param label string  caller context (e.g. 'on_list_with:page_data')
--- @param envelopes table[]  flat envelope list (each has .flags or nil)
function M.debug_flags(label, envelopes)
  if not vim.g.himalaya_debug then
    return
  end
  local total = #envelopes
  local nil_flags, unseen, seen = 0, 0, 0
  for _, env in ipairs(envelopes) do
    if not env.flags then
      nil_flags = nil_flags + 1
    else
      if M.has(env.flags, 'seen') then
        seen = seen + 1
      else
        unseen = unseen + 1
      end
    end
  end
  local log = require('himalaya.log')
  log.debug('[flags] %s: total=%d seen=%d unseen=%d unknown=%d', label, total, seen, unseen, nil_flags)
end

--- Like debug_flags but for display rows (each row has .env).
--- @param label string
--- @param rows table[]
function M.debug_flags_rows(label, rows)
  if not vim.g.himalaya_debug then
    return
  end
  local envs = {}
  for _, row in ipairs(rows) do
    envs[#envs + 1] = row.env
  end
  M.debug_flags(label, envs)
end

return M
