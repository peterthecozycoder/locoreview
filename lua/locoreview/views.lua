-- views.lua
-- Shared refresh of all review-related views.

local M = {}

function M.refresh(items)
  local qf = require("locoreview.qf")
  local signs = require("locoreview.signs")
  local pr_view = require("locoreview.pr_view")

  qf.refresh()

  if signs.refresh then
    signs.refresh(items)
  end

  if pr_view.is_open and pr_view.is_open() and pr_view.refresh then
    pr_view.refresh()
  end
end

return M
