local M = {}

function M.deepcopy(value)
  if type(value) ~= "table" then
    return value
  end

  local out = {}
  for k, v in pairs(value) do
    out[k] = M.deepcopy(v)
  end
  return out
end

function M.trim(value)
  if value == nil then
    return ""
  end

  return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.now_utc()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function M.truncate(str, max)
  local s = tostring(str or ""):gsub("\n.*", "")
  if #s <= max then
    return s
  end
  return s:sub(1, max - 3) .. "..."
end

return M
