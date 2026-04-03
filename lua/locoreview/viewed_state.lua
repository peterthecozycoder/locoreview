-- viewed_state.lua
-- Persists per-file "viewed" status in .git/locoreview_viewed.json
-- (inside .git/ so it is gitignored by default and stays local to each worktree).
--
-- Schema of the JSON file:
--   { "<relative-file-path>": { "viewed": bool, "diff_hash": "<sha256>" }, … }
--
-- Auto-reset: when a file's current diff_hash differs from the stored hash
-- the entry is flipped to viewed=false by sync().

local M = {}

local fs  = require("locoreview.fs")
local git = require("locoreview.git")

local function state_path()
  local root = git.repo_root()
  if not root then return nil end
  return root .. "/.git/locoreview_viewed.json"
end

local function load()
  local path = state_path()
  if not path then return {} end
  local content = fs.read(path)
  if not content or content == "" then return {} end
  local ok, decoded = pcall(vim.fn.json_decode, content)
  if ok and type(decoded) == "table" then return decoded end
  return {}
end

local function save(tbl)
  local path = state_path()
  if not path then return false end
  local ok, encoded = pcall(vim.fn.json_encode, tbl)
  if not ok then return false end
  return fs.write(path, encoded)
end

-- Compare the stored diff_hash for each file against the current one.
-- Any file whose hash changed is reset to viewed=false.
-- Returns the (possibly updated) state table.
-- file_diffs: array of FileDiff from git_diff.parse()
function M.sync(file_diffs)
  local tbl = load()
  local changed = false
  for _, fd in ipairs(file_diffs or {}) do
    local entry = tbl[fd.file]
    if entry and entry.viewed and entry.diff_hash ~= fd.diff_hash then
      tbl[fd.file] = { viewed = false }
      changed = true
    end
  end
  if changed then save(tbl) end
  return tbl
end

-- Mark a file as viewed, storing the current diff_hash so future changes
-- can be detected automatically.
function M.mark_viewed(file, diff_hash)
  local tbl = load()
  tbl[file] = { viewed = true, diff_hash = diff_hash }
  save(tbl)
end

-- Mark a file as not viewed.
function M.mark_unviewed(file)
  local tbl = load()
  if tbl[file] then
    tbl[file] = { viewed = false }
  end
  save(tbl)
end

function M.is_viewed(file)
  local tbl = load()
  return tbl[file] and tbl[file].viewed == true
end

-- Return the full state table (used by pr_view for batch lookups).
function M.load()
  return load()
end

return M
