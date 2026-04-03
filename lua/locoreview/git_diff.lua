-- git_diff.lua
-- Parses `git diff <base>...HEAD` into structured per-file data.
--
-- FileDiff shape:
--   file      string  – current (new) path relative to repo root
--   old_file  string  – old path (same as file unless renamed)
--   status    string  – "modified"|"added"|"deleted"|"renamed"|"binary"
--   stats     {added=N, removed=N}
--   diff_hash string  – sha256 of the raw diff text for this file
--   hunks     []Hunk
--
-- Hunk shape:
--   header    string  – the @@ … @@ line
--   old_start, old_count, new_start, new_count   integers
--   lines     []DiffLine
--
-- DiffLine shape:
--   type      string  – "add"|"remove"|"context"
--   text      string  – the raw diff line (including the +/-/space prefix)
--   old_line  integer|nil  – 1-indexed line in the old file
--   new_line  integer|nil  – 1-indexed line in the new file

local M = {}

local config = require("locoreview.config")
local git    = require("locoreview.git")

local function run(cmd)
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, table.concat(out or {}, "\n")
  end
  return out
end

-- Parse "@@ -old_start[,old_count] +new_start[,new_count] @@ ..."
-- Returns nil if the line does not match the hunk header pattern.
local function parse_hunk_header(line)
  local os, oc, ns, nc = line:match("^@@ %-(%d+),(%d+) %+(%d+),(%d+) @@")
  if os then
    return { old_start=tonumber(os), old_count=tonumber(oc), new_start=tonumber(ns), new_count=tonumber(nc) }
  end
  local os2, oc2, ns2 = line:match("^@@ %-(%d+),(%d+) %+(%d+) @@")
  if os2 then
    return { old_start=tonumber(os2), old_count=tonumber(oc2), new_start=tonumber(ns2), new_count=1 }
  end
  local os3, ns3, nc3 = line:match("^@@ %-(%d+) %+(%d+),(%d+) @@")
  if os3 then
    return { old_start=tonumber(os3), old_count=1, new_start=tonumber(ns3), new_count=tonumber(nc3) }
  end
  local os4, ns4 = line:match("^@@ %-(%d+) %+(%d+) @@")
  if os4 then
    return { old_start=tonumber(os4), old_count=1, new_start=tonumber(ns4), new_count=1 }
  end
  return nil
end

-- Flush the current in-progress file into `files`.
local function flush(files, current, current_hunk, raw_for_hash)
  if not current then return end
  if current_hunk then
    current_hunk._old = nil
    current_hunk._new = nil
    table.insert(current.hunks, current_hunk)
  end
  current.diff_hash = vim.fn.sha256(table.concat(raw_for_hash, "\n"))
  if current.file ~= "" then
    table.insert(files, current)
  end
end

-- Run `git diff --unified=3 <base_ref>...HEAD` and parse the output.
-- Returns a list of FileDiff tables, or nil + error string.
function M.parse(base_ref)
  local cfg = config.get()
  base_ref = base_ref or git.base_branch(cfg)

  local raw, err = run({
    "git", "diff", "--unified=3", base_ref .. "...HEAD",
  })
  if not raw then
    return nil, err or "git diff failed"
  end

  local files        = {}
  local current      = nil   -- FileDiff being built
  local current_hunk = nil   -- Hunk being built
  local in_header    = false -- true while parsing file header (before first @@)
  local raw_for_hash = {}    -- raw diff lines for the current file

  for _, line in ipairs(raw) do
    -- ── New file section ────────────────────────────────────────────────────
    if line:match("^diff %-%-git ") then
      flush(files, current, current_hunk, raw_for_hash)
      current_hunk = nil
      raw_for_hash = { line }
      in_header    = true

      -- Extract paths from "diff --git a/X b/Y" (non-greedy for a/ part)
      local a_path, b_path = line:match("^diff %-%-git a/(.-) b/(.+)$")
      current = {
        file     = b_path or "",
        old_file = a_path or b_path or "",
        status   = "modified",
        stats    = { added = 0, removed = 0 },
        hunks    = {},
        diff_hash = "",
      }

    elseif current then
      table.insert(raw_for_hash, line)

      -- ── Transition from header → hunk mode on @@ ─────────────────────────
      if in_header and line:match("^@@ ") then
        in_header = false
        -- fall through immediately to hunk-header processing below
      end

      -- ── File header parsing ───────────────────────────────────────────────
      if in_header then
        if line:match("^new file mode") then
          current.status = "added"
        elseif line:match("^deleted file mode") then
          current.status = "deleted"
        elseif line:match("^rename from ") then
          current.status   = "renamed"
          current.old_file = line:sub(13)   -- "rename from " = 12 chars
        elseif line:match("^rename to ") then
          current.file = line:sub(11)       -- "rename to "   = 10 chars
        elseif line:match("^Binary files") then
          current.status = "binary"
        elseif line:match("^%-%-%- ") then
          -- "--- a/path" → strip "--- " (4) then optional "a/" prefix
          local path = line:sub(5)
          if path:match("^a/") then path = path:sub(3) end
          if path ~= "/dev/null" then current.old_file = path end
        elseif line:match("^%+%+%+ ") then
          -- "+++ b/path" → strip "+++ " (4) then optional "b/" prefix
          local path = line:sub(5)
          if path:match("^b/") then path = path:sub(3) end
          if path ~= "/dev/null" then current.file = path end
        end

      -- ── Hunk header ───────────────────────────────────────────────────────
      elseif line:match("^@@ ") then
        if current_hunk then
          current_hunk._old = nil
          current_hunk._new = nil
          table.insert(current.hunks, current_hunk)
        end
        local hh = parse_hunk_header(line)
        if hh then
          current_hunk = {
            header    = line,
            old_start = hh.old_start, old_count = hh.old_count,
            new_start = hh.new_start, new_count = hh.new_count,
            lines     = {},
            _old      = hh.old_start,
            _new      = hh.new_start,
          }
        else
          current_hunk = nil
        end

      -- ── Hunk content ──────────────────────────────────────────────────────
      elseif current_hunk and not line:match("^\\") then
        local ch = line:sub(1, 1)
        if ch == "+" then
          table.insert(current_hunk.lines, {
            type     = "add",
            text     = line,
            old_line = nil,
            new_line = current_hunk._new,
          })
          current_hunk._new          = current_hunk._new + 1
          current.stats.added        = current.stats.added + 1
        elseif ch == "-" then
          table.insert(current_hunk.lines, {
            type     = "remove",
            text     = line,
            old_line = current_hunk._old,
            new_line = nil,
          })
          current_hunk._old          = current_hunk._old + 1
          current.stats.removed      = current.stats.removed + 1
        elseif ch == " " then
          table.insert(current_hunk.lines, {
            type     = "context",
            text     = line,
            old_line = current_hunk._old,
            new_line = current_hunk._new,
          })
          current_hunk._old = current_hunk._old + 1
          current_hunk._new = current_hunk._new + 1
        end
      end
    end
  end

  flush(files, current, current_hunk, raw_for_hash)
  return files
end

return M
