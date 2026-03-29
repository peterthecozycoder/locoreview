local M = {}

local function open_items(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    if item.status == "open" then
      table.insert(out, item)
    end
  end
  return out
end

function M.build_prompt(items, repo_root, review_file_path)
  local lines = {
    "Repository: " .. tostring(repo_root),
    "Review file: " .. tostring(review_file_path),
    "",
    "Open review items:",
  }

  local has_items = false
  for _, item in ipairs(open_items(items)) do
    has_items = true
    table.insert(lines, string.format("- %s %s:%d [%s] %s", item.id, item.file, item.line, item.severity, item.issue:gsub("\n.*", "")))
    if item.requested_change and item.requested_change ~= "" then
      table.insert(lines, "  requested_change: " .. item.requested_change:gsub("\n.*", ""))
    end
  end

  if not has_items then
    table.insert(lines, "- none")
  end

  return table.concat(lines, "\n")
end

function M.resolve_cmd(agent_cmd)
  if type(agent_cmd) == "function" then
    return agent_cmd()
  end
  return tostring(agent_cmd)
end

function M.run(items, repo_root, review_file_path, cfg)
  local prompt = M.build_prompt(items, repo_root, review_file_path)
  local cmd = M.resolve_cmd(cfg.cmd)
  local full_cmd = cmd .. " " .. vim.fn.shellescape(prompt)

  if cfg.open_in_split then
    vim.cmd("botright split")
    vim.cmd("terminal " .. full_cmd)
    return true
  end

  vim.fn.system(full_cmd)
  return vim.v.shell_error == 0, prompt
end

return M
