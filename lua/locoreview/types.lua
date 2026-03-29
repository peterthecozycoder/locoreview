local M = {}

local util = require("locoreview.util")

M.STATUS = {
  open = "open",
  fixed = "fixed",
  blocked = "blocked",
  wontfix = "wontfix",
}

M.SEVERITY = {
  low = "low",
  medium = "medium",
  high = "high",
}

M.VALID_TRANSITIONS = {
  open = {
    fixed = true,
    blocked = true,
    wontfix = true,
  },
  fixed = {
    open = true,
  },
  blocked = {
    open = true,
  },
  wontfix = {
    open = true,
  },
}

local function is_status(value)
  return type(value) == "string" and M.STATUS[value] ~= nil
end

local function is_severity(value)
  return type(value) == "string" and M.SEVERITY[value] ~= nil
end

function M.new_item(fields)
  if type(fields) ~= "table" then
    return nil, "fields must be a table"
  end

  if not fields.file or fields.file == "" then
    return nil, "missing required field: file"
  end

  local line = tonumber(fields.line)
  if not line then
    return nil, "missing required field: line"
  end

  if not is_severity(fields.severity) then
    return nil, "missing or invalid required field: severity"
  end

  if not is_status(fields.status) then
    return nil, "missing or invalid required field: status"
  end

  if not fields.issue or fields.issue == "" then
    return nil, "missing required field: issue"
  end

  local created_at = fields.created_at or util.now_utc()
  local updated_at = fields.updated_at or created_at

  return {
    id = fields.id,
    file = fields.file,
    line = line,
    end_line = tonumber(fields.end_line),
    severity = fields.severity,
    status = fields.status,
    issue = fields.issue,
    requested_change = fields.requested_change or "",
    author = fields.author,
    created_at = created_at,
    updated_at = updated_at,
  }
end

function M.is_valid_transition(from, to)
  return M.VALID_TRANSITIONS[from] ~= nil and M.VALID_TRANSITIONS[from][to] == true
end

return M
