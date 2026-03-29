local M = {}

local function id_number(id)
  local n = tostring(id or ""):match("^RV%-(%d+)$")
  return tonumber(n) or 0
end

local function append_block(lines, key, text)
  table.insert(lines, key .. ":")
  local value = tostring(text or "")
  if value ~= "" then
    for line in (value .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, line)
    end
  end
end

function M.format(items)
  local sorted = {}
  for _, item in ipairs(items or {}) do
    table.insert(sorted, item)
  end
  table.sort(sorted, function(a, b)
    return id_number(a.id) < id_number(b.id)
  end)

  local lines = { "# Review Comments", "" }
  for _, item in ipairs(sorted) do
    table.insert(lines, "## " .. item.id)
    table.insert(lines, "file: " .. tostring(item.file or ""))
    table.insert(lines, "line: " .. tostring(item.line or ""))
    table.insert(lines, "end_line: " .. (item.end_line and tostring(item.end_line) or ""))
    table.insert(lines, "severity: " .. tostring(item.severity or ""))
    table.insert(lines, "status: " .. tostring(item.status or ""))
    table.insert(lines, "author: " .. (item.author or ""))
    table.insert(lines, "created_at: " .. tostring(item.created_at or ""))
    table.insert(lines, "updated_at: " .. tostring(item.updated_at or ""))
    table.insert(lines, "")
    append_block(lines, "issue", item.issue or "")
    table.insert(lines, "")
    append_block(lines, "requested_change", item.requested_change or "")
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
  end

  return table.concat(lines, "\n")
end

return M
