local M = {}

local formatter = require("locoreview.formatter")
local fs = require("locoreview.fs")
local parser = require("locoreview.parser")
local types = require("locoreview.types")
local util = require("locoreview.util")


function M.load(path)
  local target = path or fs.review_file_path()
  if not target then
    return nil, "unable to resolve review file path"
  end

  local content = fs.read(target)
  if content == nil then
    return nil, "unable to read review file"
  end

  return parser.parse(content)
end

function M.save(path, items)
  local target = path or fs.review_file_path()
  if not target then
    return nil, "unable to resolve review file path"
  end

  local content = formatter.format(items or {})
  local ok = fs.write(target, content)
  if not ok then
    return nil, "failed to write review file"
  end
  return true
end

function M.next_id(items)
  local max_id = 0
  for _, item in ipairs(items or {}) do
    local n = tostring(item.id or ""):match("^RV%-(%d+)$")
    local parsed = tonumber(n)
    if parsed and parsed > max_id then
      max_id = parsed
    end
  end
  return string.format("RV-%04d", max_id + 1)
end

function M.insert(items, fields)
  local next = util.deepcopy(items or {})
  local ts = util.now_utc()
  local item_data = util.deepcopy(fields or {})
  item_data.id = M.next_id(next)
  item_data.created_at = item_data.created_at or ts
  item_data.updated_at = ts
  local new_item, err = types.new_item(item_data)
  if not new_item then
    return nil, err
  end
  table.insert(next, new_item)
  return next, new_item
end

function M.update(items, id, fields)
  local next = util.deepcopy(items or {})
  for _, item in ipairs(next) do
    if item.id == id then
      for key, value in pairs(fields or {}) do
        item[key] = value
      end
      item.updated_at = util.now_utc()
      local validated, err = types.new_item(item)
      if not validated then
        return nil, err
      end
      validated.id = id
      for key, value in pairs(validated) do
        item[key] = value
      end
      return next, item
    end
  end
  return nil, string.format("item not found: %s", tostring(id))
end

function M.delete(items, id)
  local next = util.deepcopy(items or {})
  for i, item in ipairs(next) do
    if item.id == id then
      table.remove(next, i)
      return next
    end
  end
  return nil, string.format("item not found: %s", tostring(id))
end

function M.delete_by_statuses(items, statuses)
  local status_set = {}
  for _, status in ipairs(statuses or {}) do
    if type(status) == "string" and status ~= "" then
      status_set[status] = true
    end
  end

  if next(status_set) == nil then
    return util.deepcopy(items or {}), 0
  end

  local next_items = {}
  local removed = 0
  for _, item in ipairs(items or {}) do
    if status_set[item.status] then
      removed = removed + 1
    else
      table.insert(next_items, util.deepcopy(item))
    end
  end
  return next_items, removed
end

function M.transition(items, id, new_status)
  local next = util.deepcopy(items or {})
  for _, item in ipairs(next) do
    if item.id == id then
      if not types.is_valid_transition(item.status, new_status) then
        return nil, string.format("invalid transition: %s -> %s", item.status, tostring(new_status))
      end
      item.status = new_status
      item.updated_at = util.now_utc()
      return next, item
    end
  end
  return nil, string.format("item not found: %s", tostring(id))
end

function M.find_by_location(items, file, line)
  local lnum = tonumber(line) or 0
  for _, item in ipairs(items or {}) do
    if item.status == "open" and item.file == file then
      if item.end_line and lnum >= item.line and lnum <= item.end_line then
        return item
      end
      if item.line == lnum then
        return item
      end
    end
  end
  return nil
end

return M
