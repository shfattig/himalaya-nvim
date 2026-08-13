local M = {}

-- Header names we can format structurally, keyed lowercase (RFC 5322 header
-- names are case-insensitive) and mapped to their display label.
local KNOWN = {
  ['date'] = 'Date',
  ['from'] = 'From',
  ['to'] = 'To',
  ['cc'] = 'Cc',
  ['subject'] = 'Subject',
  ['reply-to'] = 'Reply-To',
}
local ORDER = { 'Date', 'From', 'To', 'Cc', 'Subject', 'Reply-To' }

--- Parse the known header fields out of a plain-text `message read` buffer.
--- RFC 5322 guarantees the header block ends at the first blank line
--- regardless of which headers are present, so that boundary is reliable
--- even though we only recognize a handful of specific field names inside
--- it. Folded/continuation lines (starting with whitespace) are appended to
--- whichever known field they follow; continuations of unrecognized headers
--- are ignored.
--- @param lines string[]
--- @return table<string,string> known  display label -> value
--- @return number blank_idx  1-indexed line number of the blank separator (or #lines+1 if absent)
function M.parse(lines)
  local blank_idx = #lines + 1
  for i, l in ipairs(lines) do
    if l == '' then
      blank_idx = i
      break
    end
  end

  local known = {}
  local current_key = nil
  for i = 1, blank_idx - 1 do
    local line = lines[i]
    if line:match('^%s') then
      if current_key then
        known[current_key] = known[current_key] .. ' ' .. vim.trim(line)
      end
    else
      local name, value = line:match('^([%w%-]+):%s*(.*)$')
      if name and KNOWN[name:lower()] then
        current_key = KNOWN[name:lower()]
        known[current_key] = vim.trim(value)
      else
        current_key = nil
      end
    end
  end

  return known, blank_idx
end

--- Build reading-buffer lines: a structured summary of known header fields,
--- followed by the full original header block (foldable by the caller) and
--- the message body. When no known fields are found, the summary is
--- omitted but the header block is still returned intact for folding.
--- @param lines string[]
--- @return string[] out
--- @return number? fold_start  1-indexed start of the raw header block within `out`
--- @return number? fold_end  1-indexed end of the raw header block within `out`
function M.render(lines)
  local known, blank_idx = M.parse(lines)

  local out = {}
  for _, key in ipairs(ORDER) do
    if known[key] and known[key] ~= '' then
      table.insert(out, string.format('%-8s %s', key .. ':', known[key]))
    end
  end

  local fold_start, fold_end
  if blank_idx > 1 then
    fold_start = #out + 1
    for i = 1, blank_idx - 1 do
      table.insert(out, lines[i])
    end
    fold_end = #out
  end

  for i = blank_idx, #lines do
    table.insert(out, lines[i])
  end

  return out, fold_start, fold_end
end

return M
