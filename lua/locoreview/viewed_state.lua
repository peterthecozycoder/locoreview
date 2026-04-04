-- viewed_state.lua
-- Persists per-file "mood" (review state) in .git/locoreview_viewed.json
-- (inside .git/ so it is gitignored by default and stays local to each worktree).
--
-- Persisted moods (stored in JSON):
--   untouched   – never reviewed
--   in_progress – cursor has visited but not explicitly marked
--   reviewed    – explicitly marked done (was "viewed" in v1)
--   generated   – auto-detected as generated/lockfile/dist
--
-- Session-only state (not persisted, reset on buffer open):
--   snoozed     – deferred for later; stored in memory only
--
-- Computed moods (derived on demand, not stored):
--   blocked     – has open high-severity comments
--   risky       – large diff with zero comments
--
-- Legacy JSON format (viewed: bool) is normalised transparently on read.

local M = {}

local fs  = require("locoreview.fs")
local git = require("locoreview.git")

-- ── Persistence ──────────────────────────────────────────────────────────────

local function state_path()
  local root = git.repo_root()
  if not root then return nil end
  return root .. "/.git/locoreview_viewed.json"
end

local function load_raw()
  local path = state_path()
  if not path then return {} end
  local content = fs.read(path)
  if not content or content == "" then return {} end
  local ok, decoded = pcall(vim.fn.json_decode, content)
  if ok and type(decoded) == "table" then return decoded end
  return {}
end

local function save_raw(tbl)
  local path = state_path()
  if not path then return false end
  local ok, encoded = pcall(vim.fn.json_encode, tbl)
  if not ok then return false end
  return fs.write(path, encoded)
end

-- Normalise a raw entry to always have both .mood and .viewed (legacy compat).
local function normalise(entry)
  if not entry then
    return { mood = "untouched", viewed = false }
  end
  local e = vim.deepcopy(entry)
  if not e.mood then
    e.mood = (e.viewed == true) and "reviewed" or "untouched"
  end
  -- Keep .viewed in sync for code that still checks it directly
  e.viewed = (e.mood == "reviewed")
  return e
end

-- ── Session-only snooze ───────────────────────────────────────────────────────

local _snooze_set = {}

function M.snooze(file)
  _snooze_set[file] = true
end

function M.unsnooze(file)
  _snooze_set[file] = nil
end

function M.is_snoozed(file)
  return _snooze_set[file] == true
end

function M.get_snooze_set()
  return _snooze_set
end

function M.clear_snooze()
  _snooze_set = {}
end

-- ── Generated-file detection ──────────────────────────────────────────────────

local DEFAULT_GENERATED_PATTERNS = {
  "%.lock$",
  "go%.sum$",
  "package%-lock%.json$",
  "yarn%.lock$",
  "pnpm%-lock%.yaml$",
  "Cargo%.lock$",
  "Gemfile%.lock$",
  "Podfile%.lock$",
  "composer%.lock$",
  "^dist/",
  "^build/",
  "^vendor/",
  "^%.bundle/",
  "%.snap$",
  "%.min%.js$",
  "%.min%.css$",
  "%.pb%.go$",
  "%.generated%.",
  "_generated%.",
  "/__snapshots__/",
}

function M.is_generated(file, extra_patterns)
  local patterns = extra_patterns or DEFAULT_GENERATED_PATTERNS
  for _, pat in ipairs(patterns) do
    if file:match(pat) then return true end
  end
  return false
end

-- ── State mutations ───────────────────────────────────────────────────────────

-- Set mood directly (persisted).
function M.set_mood(file, mood, diff_hash)
  local tbl = load_raw()
  local existing = tbl[file] or {}
  tbl[file] = {
    mood      = mood,
    viewed    = (mood == "reviewed"),
    diff_hash = diff_hash or existing.diff_hash,
  }
  save_raw(tbl)
end

-- Mark file as reviewed (was mark_viewed).
function M.mark_reviewed(file, diff_hash)
  M.set_mood(file, "reviewed", diff_hash)
end

-- Backwards-compat alias.
function M.mark_viewed(file, diff_hash)
  M.mark_reviewed(file, diff_hash)
end

-- Reset file to untouched (was mark_unviewed).
function M.mark_unviewed(file)
  local tbl = load_raw()
  if tbl[file] then
    tbl[file] = { mood = "untouched", viewed = false }
  end
  save_raw(tbl)
end

-- Upgrade untouched → in_progress; never downgrade reviewed.
function M.mark_in_progress(file)
  local tbl = load_raw()
  local entry = tbl[file]
  local current = entry and (entry.mood or (entry.viewed and "reviewed" or "untouched")) or "untouched"
  if current == "untouched" then
    tbl[file] = { mood = "in_progress", viewed = false, diff_hash = entry and entry.diff_hash }
    save_raw(tbl)
  end
end

-- ── State reads ───────────────────────────────────────────────────────────────

function M.is_viewed(file)
  local tbl = load_raw()
  local entry = normalise(tbl[file])
  return entry.mood == "reviewed"
end

function M.get_mood(file)
  local tbl = load_raw()
  return normalise(tbl[file]).mood
end

-- Return the full normalised state table (used by pr_view for batch lookups).
-- Each entry has: { mood, viewed (bool), diff_hash }
function M.load()
  local raw = load_raw()
  local out = {}
  for file, entry in pairs(raw) do
    out[file] = normalise(entry)
  end
  return out
end

-- Compare stored diff_hash against current; reset any changed file to untouched.
-- Returns the normalised state table.
function M.sync(file_diffs)
  local tbl = load_raw()
  local changed = false
  for _, fd in ipairs(file_diffs or {}) do
    local entry = tbl[fd.file]
    if entry then
      local mood = entry.mood or (entry.viewed and "reviewed" or "untouched")
      local stored_hash = entry.diff_hash
      if (mood == "reviewed" or mood == "in_progress") and stored_hash ~= fd.diff_hash then
        tbl[fd.file] = { mood = "untouched", viewed = false }
        changed = true
      end
    end
  end
  if changed then save_raw(tbl) end
  -- Return normalised
  local out = {}
  for file, entry in pairs(tbl) do
    out[file] = normalise(entry)
  end
  return out
end

return M
