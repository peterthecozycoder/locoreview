local M = {}

function M.is_available()
  local ok = pcall(require, "diffview")
  return ok
end

function M.open_diff(base_branch)
  vim.cmd("DiffviewOpen " .. base_branch .. "...HEAD")
end

function M.open_file_history()
  vim.cmd("DiffviewFileHistory %")
end

return M
