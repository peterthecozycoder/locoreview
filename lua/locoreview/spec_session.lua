-- spec_session.lua
-- Session lifecycle for spec review: owns the in-memory session state table.
-- Delegates I/O to spec_store and parsing to spec_parser.

local M = {}

local spec_store  = require("locoreview.spec_store")
local util        = require("locoreview.util")

-- ── Session state ─────────────────────────────────────────────────────────────
-- One session is active at a time. All fields are nil when no session is open.

local _session = {
  spec_path    = nil,   -- absolute path to the spec file
  parse_result = nil,   -- SpecParseResult
  states       = nil,   -- table: item_id → SpecReviewState
  cursor       = nil,   -- index into parse_result.items (1-based)
}

local function reset()
  _session.spec_path    = nil
  _session.parse_result = nil
  _session.states       = nil
  _session.cursor       = nil
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function items()
  return _session.parse_result and _session.parse_result.items or {}
end

local function is_unreviewed(item)
  local state = _session.states[item.id]
  return not state or state.status == "unreviewed"
end

local function find_first_unreviewed(start_idx)
  local list = items()
  start_idx = start_idx or 1
  for i = start_idx, #list do
    if is_unreviewed(list[i]) then return i end
  end
  for i = 1, start_idx - 1 do
    if is_unreviewed(list[i]) then return i end
  end
  return nil
end

local function persist()
  local ok, err = spec_store.save(_session.spec_path, _session.states, _session.parse_result)
  return ok, err
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- open(spec_path) → ok, err
-- Parses the spec file and loads any existing sidecar state.
-- Positions cursor at the first unreviewed item.
function M.open(spec_path)
  if not spec_path or spec_path == "" then
    return nil, "spec_path is required"
  end

  reset()

  local result, err = spec_store.load(spec_path)
  if err then
    return nil, err
  end

  _session.spec_path    = spec_path
  _session.parse_result = result.parse_result
  _session.states       = result.states
  _session.cursor       = find_first_unreviewed(1) or 1

  -- Merge stale-state warnings (from store) + parse warnings into one list.
  local all_warnings = {}
  for _, w in ipairs(result.warnings or {}) do
    table.insert(all_warnings, w)
  end
  for _, w in ipairs((result.parse_result and result.parse_result.warnings) or {}) do
    table.insert(all_warnings, w)
  end

  return {
    parse_result       = result.parse_result,
    states             = result.states,
    warnings           = all_warnings,
    unparsed_sections  = result.parse_result and result.parse_result.unparsed_sections or {},
    cursor             = _session.cursor,
  }, nil
end

-- close() — tear down the session.
function M.close()
  reset()
end

-- is_open() → bool
function M.is_open()
  return _session.spec_path ~= nil
end

-- current_item() → SpecItem | nil
function M.current_item()
  local list = items()
  if _session.cursor and list[_session.cursor] then
    return list[_session.cursor]
  end
  return nil
end

-- current_state() → SpecReviewState | nil
function M.current_state()
  local item = M.current_item()
  if not item then return nil end
  return _session.states[item.id]
end

-- next() → SpecItem | nil
-- Advances cursor to the next item (wraps). Returns the new current item.
function M.next()
  local list = items()
  if #list == 0 then return nil end
  _session.cursor = (_session.cursor % #list) + 1
  return list[_session.cursor]
end

-- prev() → SpecItem | nil
-- Moves cursor to the previous item (wraps). Returns the new current item.
function M.prev()
  local list = items()
  if #list == 0 then return nil end
  _session.cursor = ((_session.cursor - 2) % #list) + 1
  return list[_session.cursor]
end

-- next_unreviewed() → SpecItem | nil
-- Advances to the next unreviewed item starting after current cursor.
function M.next_unreviewed()
  local list = items()
  if #list == 0 then return nil end
  local start = (_session.cursor % #list) + 1
  local idx = find_first_unreviewed(start)
  if idx then
    _session.cursor = idx
    return list[idx]
  end
  return nil
end

-- mark(new_status) → ok, err
-- Applies a state transition to the current item and persists.
function M.mark(new_status)
  if not _session.states then
    return nil, "no active session"
  end
  local item = M.current_item()
  if not item then
    return nil, "no current item"
  end
  local next_states, err = spec_store.transition(_session.states, item.id, new_status)
  if err then
    return nil, err
  end
  _session.states = next_states
  local ok, werr = persist()
  if not ok then
    return nil, werr or "persist failed"
  end
  return true, nil
end

-- set_note(text) → ok, err
-- Attaches (or replaces) a note on the current item without changing status.
function M.set_note(text)
  if not _session.states then
    return nil, "no active session"
  end
  local item = M.current_item()
  if not item then
    return nil, "no current item"
  end
  local state = _session.states[item.id]
  if not state then
    return nil, "state not found for item: " .. item.id
  end
  state.note       = text or ""
  state.updated_at = util.now_utc()

  local ok, err = persist()
  if not ok then
    -- Per R24: state change is already in memory; note failure is reported separately.
    return nil, err or "note persist failed"
  end
  return true, nil
end

-- summary() → table
-- Returns aggregate counts useful for display.
function M.summary()
  local list    = items()
  local states  = _session.states or {}
  local total   = #list

  local counts_by_status = {
    unreviewed = 0,
    reviewed   = 0,
    unclear    = 0,
    blocked    = 0,
  }
  local counts_by_type = {}
  local unclear_items  = {}

  for _, item in ipairs(list) do
    local state  = states[item.id]
    local status = state and state.status or "unreviewed"

    counts_by_status[status] = (counts_by_status[status] or 0) + 1

    local t = item.type
    if not counts_by_type[t] then
      counts_by_type[t] = { unreviewed = 0, reviewed = 0, unclear = 0, blocked = 0 }
    end
    counts_by_type[t][status] = (counts_by_type[t][status] or 0) + 1

    if status == "unclear" then
      table.insert(unclear_items, item)
    end
  end

  return {
    total           = total,
    by_status       = counts_by_status,
    by_type         = counts_by_type,
    unclear_items   = unclear_items,
    review_debt     = counts_by_status.unclear + counts_by_status.blocked,
  }
end

-- jump_to_section(section_name) → first item in section | nil
-- Moves cursor to the first item in the named section.
function M.jump_to_section(section_name)
  local list = items()
  for i, item in ipairs(list) do
    if item.section == section_name then
      _session.cursor = i
      return item
    end
  end
  return nil
end

-- items_for_section(section_name) → SpecItem[]
function M.items_for_section(section_name)
  local out = {}
  for _, item in ipairs(items()) do
    if item.section == section_name then
      table.insert(out, item)
    end
  end
  return out
end

-- all_items() → SpecItem[]
function M.all_items()
  return items()
end

-- all_states() → table (item_id → SpecReviewState)
function M.all_states()
  return _session.states or {}
end

-- get_parse_result() → SpecParseResult | nil
function M.get_parse_result()
  return _session.parse_result
end

-- expose for tests
M._reset = reset

return M
