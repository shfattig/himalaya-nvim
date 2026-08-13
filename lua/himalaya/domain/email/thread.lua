local M = {}

--- @param line string
--- @param lnum? number
--- @param bufnr? number
function M.fold(line, lnum, bufnr)
  local range = bufnr and vim.b[bufnr].himalaya_header_fold_range
  if range and lnum and lnum >= range[1] and lnum <= range[2] then
    return '1'
  end
  if line:sub(1, 1) == '>' then
    return '1'
  end
  return nil
end

function M.foldexpr(lnum)
  local bufnr = vim.api.nvim_get_current_buf()
  return M.fold(vim.fn.getline(lnum), lnum, bufnr) or '0'
end

return M
