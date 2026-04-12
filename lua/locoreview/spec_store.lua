local M = {}

local fs          = require("locoreview.fs")
local spec_parser = require("locoreview.spec_parser")
local spec_types  = require("locoreview.spec_types")
local util        = require("locoreview.util")

-- ── JSON helpers ──────────────────────────────────────────────────────────────
-- Prefer vim.fn when running inside Neovim; fall back to a minimal pure-Lua
-- implementation so the module loads cleanly in headless test environments.

local function json_encode(tbl)
  if type(vim) == "table" and vim.fn and vim.fn.json_encode then
    return vim.fn.json_encode(tbl)
  end
  -- Minimal encoder sufficient for the sidecar format.
  local function enc(v)
    local t = type(v)
    if t == "nil" then
      return "null"
    elseif t == "boolean" then
      return tostring(v)
    elseif t == "number" then
      return tostring(v)
    elseif t == "string" then
      return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
    elseif t == "table" then
      -- Decide array vs object.
      local is_arr = #v > 0
      if is_arr then
        local parts = {}
        for _, item in ipairs(v) do
          table.insert(parts, enc(item))
        end
        return "[" .. table.concat(parts, ",") .. "]"
      else
        local parts = {}
        for k, val in pairs(v) do
          table.insert(parts, enc(tostring(k)) .. ":" .. enc(val))
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ",") .. "}"
      end
    end
    return "null"
  end
  return enc(tbl)
end

-- Pure-Lua recursive-descent JSON decoder.
-- Handles the sidecar format: nested objects with arbitrary string keys.
local function json_decode(s)
  if type(vim) == "table" and vim.fn and vim.fn.json_decode then
    local ok, result = pcall(vim.fn.json_decode, s)
    if ok and type(result) == "table" then return result end
    return nil
  end

  local pos = 1

  local function skip_ws()
    while pos <= #s and s:sub(pos,pos):match("%s") do pos = pos + 1 end
  end

  local function parse_value()
    skip_ws()
    if pos > #s then return nil end
    local ch = s:sub(pos, pos)

    if ch == '"' then
      -- String
      pos = pos + 1
      local buf = {}
      while pos <= #s do
        local c = s:sub(pos, pos)
        if c == '\\' then
          pos = pos + 1
          local e = s:sub(pos, pos)
          if     e == '"'  then table.insert(buf, '"')
          elseif e == '\\' then table.insert(buf, '\\')
          elseif e == 'n'  then table.insert(buf, '\n')
          elseif e == 'r'  then table.insert(buf, '\r')
          elseif e == 't'  then table.insert(buf, '\t')
          else table.insert(buf, e) end
          pos = pos + 1
        elseif c == '"' then
          pos = pos + 1
          break
        else
          table.insert(buf, c)
          pos = pos + 1
        end
      end
      return table.concat(buf)

    elseif ch == '{' then
      pos = pos + 1
      local obj = {}
      skip_ws()
      if s:sub(pos,pos) == '}' then pos = pos + 1; return obj end
      while true do
        skip_ws()
        local key = parse_value()
        skip_ws()
        if s:sub(pos,pos) == ':' then pos = pos + 1 end
        local val = parse_value()
        obj[key] = val
        skip_ws()
        local sep = s:sub(pos,pos)
        if sep == ',' then pos = pos + 1
        elseif sep == '}' then pos = pos + 1; break
        else break end
      end
      return obj

    elseif ch == '[' then
      pos = pos + 1
      local arr = {}
      skip_ws()
      if s:sub(pos,pos) == ']' then pos = pos + 1; return arr end
      while true do
        table.insert(arr, parse_value())
        skip_ws()
        local sep = s:sub(pos,pos)
        if sep == ',' then pos = pos + 1
        elseif sep == ']' then pos = pos + 1; break
        else break end
      end
      return arr

    elseif s:sub(pos, pos+3) == 'null'  then pos = pos + 4; return nil
    elseif s:sub(pos, pos+3) == 'true'  then pos = pos + 4; return true
    elseif s:sub(pos, pos+4) == 'false' then pos = pos + 5; return false

    else
      -- Number
      local num_s = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
      if num_s then
        pos = pos + #num_s
        return tonumber(num_s)
      end
    end
    return nil
  end

  local ok, result = pcall(parse_value)
  if ok and type(result) == "table" then return result end
  return nil
end

-- ── Sidecar path ─────────────────────────────────────────────────────────────

local _cached_sidecar_path = nil

local function sidecar_path()
  if _cached_sidecar_path then return _cached_sidecar_path end
  local root = fs.repo_root()
  if not root or root == "" then return nil end
  _cached_sidecar_path = root .. "/.git/locoreview_spec_state.json"
  return _cached_sidecar_path
end

-- ── Raw sidecar I/O ──────────────────────────────────────────────────────────

local function load_raw()
  local path = sidecar_path()
  if not path then return {} end
  local content = fs.read(path)
  if not content or content == "" then return {} end
  local decoded = json_decode(content)
  if type(decoded) == "table" then return decoded end
  return {}
end

local function save_raw(tbl)
  local path = sidecar_path()
  if not path then return false, "cannot determine sidecar path" end
  local encoded = json_encode(tbl)
  if not encoded then return false, "json encoding failed" end
  local ok = fs.write(path, encoded)
  if not ok then return false, "write failed" end
  return true
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- load(spec_path) → states_by_id, warnings
-- Parses the spec file and cross-references the sidecar. Returns a map of
-- item_id → SpecReviewState for items that are still present in the parsed spec.
-- Orphaned sidecar entries are discarded (stale detection per R56).
function M.load(spec_path)
  if not spec_path or spec_path == "" then
    return {}, { "spec_path is required" }
  end

  local parse_result = spec_parser.parse_file(spec_path)
  local raw = load_raw()

  -- Build a set of current item IDs for stale detection.
  local current_ids = {}
  for _, item in ipairs(parse_result.items) do
    current_ids[item.id] = item
  end

  local file_states = raw[spec_path]
  if type(file_states) ~= "table" then
    file_states = {}
  end

  local states     = {}
  local warnings   = {}
  local stale_count = 0

  for item_id, entry in pairs(file_states) do
    if not current_ids[item_id] then
      stale_count = stale_count + 1
    else
      local item = current_ids[item_id]
      -- Stale line_start check (R56).
      local saved_line = tonumber(entry.line_start)
      if saved_line and saved_line ~= item.line_start then
        stale_count = stale_count + 1
      else
        states[item_id] = {
          item_id    = item_id,
          status     = entry.status or "unreviewed",
          note       = entry.note or "",
          updated_at = entry.updated_at or util.now_utc(),
        }
      end
    end
  end

  if stale_count > 0 then
    table.insert(warnings, string.format(
      "[review] WARN: %d stale state %s discarded on load",
      stale_count, stale_count == 1 and "entry" or "entries"
    ))
  end

  -- Ensure every current item has a state record.
  for _, item in ipairs(parse_result.items) do
    if not states[item.id] then
      states[item.id] = {
        item_id    = item.id,
        status     = "unreviewed",
        note       = "",
        updated_at = util.now_utc(),
      }
    end
  end

  return {
    parse_result = parse_result,
    states       = states,
    warnings     = warnings,
  }, nil
end

-- save(spec_path, states_by_id) → ok, err
-- Persists a map of item_id → SpecReviewState to the sidecar JSON.
-- Also stores line_start for stale detection.
function M.save(spec_path, states, parse_result)
  if not spec_path or spec_path == "" then
    return false, "spec_path is required"
  end

  local raw = load_raw()

  local item_by_id = {}
  for _, item in ipairs(parse_result and parse_result.items or {}) do
    item_by_id[item.id] = item
  end

  local file_states = {}
  for item_id, state in pairs(states or {}) do
    local entry = item_by_id[item_id]
    file_states[item_id] = {
      status     = state.status or "unreviewed",
      note       = state.note or "",
      updated_at = state.updated_at or util.now_utc(),
      line_start = entry and entry.line_start,
    }
  end

  raw[spec_path] = file_states
  return save_raw(raw)
end

-- transition(states, id, new_status) → states, err
-- Validates and applies a state transition in place.
function M.transition(states, id, new_status)
  if not states[id] then
    return nil, string.format("item not found: %s", tostring(id))
  end
  local current = states[id].status
  if not spec_types.is_valid_transition(current, new_status) then
    return nil, string.format("invalid transition: %s -> %s", current, tostring(new_status))
  end
  states[id].status     = new_status
  states[id].updated_at = util.now_utc()
  return states, nil
end

return M
