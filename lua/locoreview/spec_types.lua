local M = {}

local util = require("locoreview.util")

M.STATUS = {
  unreviewed = "unreviewed",
  reviewed   = "reviewed",
  unclear    = "unclear",
  blocked    = "blocked",
}

M.VALID_TRANSITIONS = {
  unreviewed = { reviewed = true, unclear = true, blocked = true },
  reviewed   = { unreviewed = true },
  unclear    = { unreviewed = true, reviewed = true },
  blocked    = { unreviewed = true },
}

function M.is_valid_transition(from, to)
  return M.VALID_TRANSITIONS[from] ~= nil and M.VALID_TRANSITIONS[from][to] == true
end

-- Construct a validated SpecItem. Returns item, nil on success or nil, err on failure.
function M.new_item(fields)
  if type(fields) ~= "table" then
    return nil, "fields must be a table"
  end
  if not fields.id or fields.id == "" then
    return nil, "missing required field: id"
  end
  if not fields.type or fields.type == "" then
    return nil, "missing required field: type"
  end
  if not fields.section or fields.section == "" then
    return nil, "missing required field: section"
  end
  if not tonumber(fields.line_start) then
    return nil, "missing required field: line_start"
  end
  return {
    id          = fields.id,
    type        = fields.type,
    text        = fields.text or "",
    section     = fields.section,
    line_start  = tonumber(fields.line_start),
    line_end    = tonumber(fields.line_end) or tonumber(fields.line_start),
    source_path = fields.source_path or "",
    schema_name = fields.schema_name or "default_spec",
    checked     = fields.checked == true,
  }
end

-- Construct a validated SpecReviewState. Returns state, nil on success or nil, err.
function M.new_state(fields)
  if type(fields) ~= "table" then
    return nil, "fields must be a table"
  end
  if not fields.item_id or fields.item_id == "" then
    return nil, "missing required field: item_id"
  end
  local status = fields.status or "unreviewed"
  if not M.STATUS[status] then
    return nil, "invalid status: " .. tostring(status)
  end
  return {
    item_id    = fields.item_id,
    status     = status,
    note       = fields.note or "",
    updated_at = fields.updated_at or util.now_utc(),
  }
end

return M
