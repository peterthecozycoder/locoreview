local M = {}

local fs = require("locoreview.fs")
local git = require("locoreview.git")
local store = require("locoreview.store")
local ui = require("locoreview.ui")
local util = require("locoreview.util")

local last_filter = nil

local function default_filter(item)
  return item.status == "open"
end

function M.populate(items, filter)
  local root = git.repo_root()
  local matcher = filter or default_filter
  local entries = {}

  for _, item in ipairs(items or {}) do
    if matcher(item) then
      local filename = item.file
      if filename:sub(1, 1) ~= "/" then
        filename = root .. "/" .. filename
      end
      table.insert(entries, {
        filename = filename,
        lnum = item.line,
        end_lnum = item.end_line,
        text = string.format("[%s][%s][%s] %s", item.id, item.severity, item.status, util.truncate(item.issue, 80)),
      })
    end
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

  local entries = M.populate(items, last_filter or default_filter)
  if vim.api.nvim_win_is_valid(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end
  return entries
end

return M
