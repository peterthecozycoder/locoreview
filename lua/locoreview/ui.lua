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

function M.show_comments(items)
  if #items == 0 then
    M.notify("no comments on this line")
    return
  end
  local lines = {}
  for _, item in ipairs(items) do
    table.insert(lines, string.format("## %s · %s · %s", item.id, item.status, item.severity))
    vim.list_extend(lines, vim.split(item.issue, "\n", { plain = true }))
    if item.requested_change and item.requested_change ~= "" then
      vim.list_extend(lines, { "", "Requested change:" })
      vim.list_extend(lines, vim.split(item.requested_change, "\n", { plain = true }))
    end
    table.insert(lines, "")
  end
  return vim.lsp.util.open_floating_preview(lines, "markdown", { border = "rounded", focusable = true })
end

-- One scratch editor for both add and edit. A failed save leaves the draft open.
function M.edit_comment(item, on_submit)
  return require("locoreview.composer").open(item, on_submit)
end

return M
