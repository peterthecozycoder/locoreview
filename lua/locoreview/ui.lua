local M = {}

local util = require("locoreview.util")

function M.notify(msg, level)
  local prefix = "[review] "
  if type(vim) == "table" and vim.notify then
    vim.notify(prefix .. tostring(msg), level or vim.log.levels.INFO)
    return
  end

  io.stderr:write(prefix .. tostring(msg) .. "\n")
end

local function normalize_input(value)
  if not value then
    return nil
  end
  if util.trim(value) == "" then
    return nil
  end
  return value
end

function M.prompt_issue(callback, default)
  vim.ui.input({
    prompt = "Review issue: ",
    default = default,
  }, function(value)
    callback(normalize_input(value))
  end)
end

function M.prompt_requested_change(callback, default)
  vim.ui.input({
    prompt = "Requested change: ",
    default = default,
  }, function(value)
    callback(normalize_input(value))
  end)
end

function M.prompt_severity(default, callback)
  local options = { "low", "medium", "high" }
  vim.ui.select(options, {
    prompt = "Severity:",
    default = default,
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if not choice or choice == "" then
      callback(nil)
      return
    end
    callback(choice)
  end)
end

function M.prompt_git_ref(default, callback)
  vim.ui.input({
    prompt = "Git ref: ",
    default = default,
  }, function(value)
    callback(normalize_input(value))
  end)
end

function M.prompt_confirm(prompt, callback)
  vim.ui.select({ "yes", "no" }, {
    prompt = prompt or "Confirm:",
  }, function(choice)
    callback(choice == "yes")
  end)
end

return M
