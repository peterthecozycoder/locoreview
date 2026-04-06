local M = {}

local fs = require("locoreview.fs")
local types = require("locoreview.types")
local ITEM_HEADER_PATTERN = "^##%s+RV%-%d%d%d%d%s*$"
local ITEM_ID_PATTERN = "^##%s+(RV%-%d%d%d%d)%s*$"
local SEPARATOR_PATTERN = "^%-%-%-%s*$"

local function split_lines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local cleaned = line:gsub("\r$", "")
    table.insert(lines, cleaned)
  end
  return lines
end

local function trim_blank_edges(value)
  local lines = split_lines(value or "")
  while #lines > 0 and lines[1]:match("^%s*$") do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines, #lines)
  end
  return table.concat(lines, "\n")
end

local function parse_scalar_line(line)
  local key, value = line:match("^([%a_]+):%s*(.-)%s*$")
  if not key then
    return nil
  end
  return key, value
end

local function parse_item(lines, start_i)
  local header = lines[start_i]
  local id = header:match(ITEM_ID_PATTERN)
  if not id then
    return nil, nil, string.format("line %d: malformed item header", start_i)
  end

  local item = { id = id }
  local i = start_i + 1

  while i <= #lines and lines[i]:match("^%s*$") do
    i = i + 1
  end

  while i <= #lines do
    local line = lines[i]
    if line:match("^issue:%s*$") then
      i = i + 1
      break
    end
    if line:match(ITEM_HEADER_PATTERN) or line:match(SEPARATOR_PATTERN) then
      return nil, nil, string.format("line %d: missing required field: issue", i)
    end

    local key, value = parse_scalar_line(line)
    if key then
      item[key] = value
    end
    i = i + 1
  end

  local issue_lines = {}
  while i <= #lines and not lines[i]:match("^requested_change:%s*$") do
    if lines[i]:match(ITEM_HEADER_PATTERN) or lines[i]:match(SEPARATOR_PATTERN) then
      break
    end
    table.insert(issue_lines, lines[i])
    i = i + 1
  end

  item.issue = trim_blank_edges(table.concat(issue_lines, "\n"))
  item.requested_change = ""

  if i <= #lines and lines[i]:match("^requested_change:%s*$") then
    i = i + 1
    local requested_change_lines = {}
    while i <= #lines do
      if lines[i]:match(SEPARATOR_PATTERN) then
        i = i + 1
        break
      end
      if lines[i]:match(ITEM_HEADER_PATTERN) then
        break
      end
      table.insert(requested_change_lines, lines[i])
      i = i + 1
    end
    item.requested_change = trim_blank_edges(table.concat(requested_change_lines, "\n"))
  end

  if not item.file or item.file == "" then
    return nil, nil, string.format("%s: missing required field: file", id)
  end
  if not item.line or item.line == "" then
    return nil, nil, string.format("%s: missing required field: line", id)
  end
  item.line = tonumber(item.line)
  if not item.line then
    return nil, nil, string.format("%s: invalid line", id)
  end

  if item.end_line == "" then
    item.end_line = nil
  elseif item.end_line ~= nil then
    item.end_line = tonumber(item.end_line)
  end

  if item.author == "" then
    item.author = nil
  end

  if not item.severity or item.severity == "" then
    return nil, nil, string.format("%s: missing required field: severity", id)
  end
  if not types.SEVERITY[item.severity] then
    return nil, nil, string.format("%s: unknown severity: %s", id, item.severity)
  end

  if not item.status or item.status == "" then
    return nil, nil, string.format("%s: missing required field: status", id)
  end
  if not types.STATUS[item.status] then
    return nil, nil, string.format("%s: unknown status: %s", id, item.status)
  end

  if item.issue == "" then
    return nil, nil, string.format("%s: missing required field: issue", id)
  end

  -- Normalize line_ref: if not "old", default to "new"
  if item.line_ref ~= "old" then
    item.line_ref = "new"
  end

  local validated, err = types.new_item(item)
  if not validated then
    return nil, nil, string.format("%s: %s", id, err)
  end
  validated.id = item.id

  return validated, i
end

function M.parse(content)
  if not content or content == "" then
    return {}
  end

  local lines = split_lines(content:gsub("\r\n", "\n"))
  local i = 1
  while i <= #lines and lines[i]:match("^%s*$") do
    i = i + 1
  end

  if i > #lines or lines[i] ~= "# Review Comments" then
    return nil, "missing required header: # Review Comments"
  end

  local items = {}
  local seen = {}
  i = i + 1

  while i <= #lines do
    if lines[i]:match("^%s*$") or lines[i]:match(SEPARATOR_PATTERN) then
      i = i + 1
    elseif lines[i]:match(ITEM_HEADER_PATTERN) then
      local item, next_i, err = parse_item(lines, i)
      if not item then
        return nil, err
      end
      if seen[item.id] then
        return nil, string.format("duplicate id: %s", item.id)
      end
      seen[item.id] = true
      table.insert(items, item)
      i = next_i
    else
      i = i + 1
    end
  end

  return items
end

function M.parse_file(path)
  local content = fs.read(path)
  if not content then
    return nil, string.format("unable to read file: %s", tostring(path))
  end

  return M.parse(content)
end

return M
