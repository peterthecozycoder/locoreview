local M = {}


function M.notify(msg, level)
  local prefix = "[review] "
  if type(vim) == "table" and vim.notify then
    vim.notify(prefix .. tostring(msg), level or vim.log.levels.INFO)
    return
  end

  io.stderr:write(prefix .. tostring(msg) .. "\n")
end

function M.prompt_confirm(prompt, callback)
  vim.ui.select({ "yes", "no" }, {
    prompt = prompt or "Confirm:",
  }, function(choice)
    callback(choice == "yes")
  end)
end

-- One scratch editor for both add and edit. A failed save leaves the draft open.
function M.edit_comment(item, on_submit)
  return require("locoreview.composer").open(item, on_submit)
end

return M
