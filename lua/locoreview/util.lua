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

function M.format_age(iso_date)
  if not iso_date then
    return ""
  end
  local y, mo, d, h, mi, s = iso_date:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return ""
  end
  local then_t = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  })
  local diff = os.difftime(os.time(), then_t)
  if diff < 60 then
    return "just now"
  elseif diff < 3600 then
    return math.floor(diff / 60) .. "m ago"
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. "h ago"
  else
    return math.floor(diff / 86400) .. "d ago"
  end
end

return M
