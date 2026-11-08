local M = {}

local fs = require("locoreview.fs")
local git = require("locoreview.git")
local store = require("locoreview.store")
local ui = require("locoreview.ui")
local util = require("locoreview.util")

local last_filter = nil
local SEVERITY_ORDER = { high = 1, medium = 2, low = 3 }

local function default_filter(item)
  return item.status == "open"
end

function M.populate(items, filter)
  local root = git.repo_root()
  if not root or root == "" then
    local err = "could not determine repository root"
    ui.notify(err, vim.log.levels.ERROR)
    return nil, err
  end
  local matcher = filter or default_filter
  local matched = {}

  for _, item in ipairs(items or {}) do
    if matcher(item) then
      table.insert(matched, item)
    end
  end

  table.sort(matched, function(a, b)
    local sa = SEVERITY_ORDER[a.severity] or 99
    local sb = SEVERITY_ORDER[b.severity] or 99
    if sa ~= sb then
      return sa < sb
    end
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.line < b.line
  end)

  local entries = {}
  local review_path = fs.review_file_path()
  local review_lines = {}
  if review_path then
    local content = fs.read(review_path) or ""
    local row = 0
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
      row = row + 1
      local id = line:match("^##%s+(RV%-%d+)%s*$")
      if id then review_lines[id] = row end
    end
  end
  for _, item in ipairs(matched) do
    local filename = item.file
    if filename:sub(1, 1) ~= "/" then
      filename = root .. "/" .. filename
    end
    local old = item.line_ref == "old"
    table.insert(entries, {
      filename = old and review_path or filename,
      lnum = old and (review_lines[item.id] or 1) or item.line,
      end_lnum = not old and item.end_line or nil,
      text = string.format("[%s][%s][%s] %s", item.id, item.severity, item.status, util.truncate(item.issue, 80)),
    })
  end

  vim.fn.setqflist({}, " ", {
    title = "locoreview.nvim",
    items = entries,
  })
  last_filter = matcher
  return entries
end

function M.refresh()
  local current_win = vim.api.nvim_get_current_win()
  local path = fs.review_file_path()
  if not path then
    ui.notify("unable to resolve review file path", vim.log.levels.ERROR)
    return nil, "unable to resolve review file path"
  end

  local items, err = store.load(path)
  if not items then
    ui.notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  local entries, populate_err = M.populate(items, last_filter or default_filter)
  if not entries then
    return nil, populate_err
  end
  if vim.api.nvim_win_is_valid(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end
  return entries
end

return M
