-- pr_view.lua
-- Cozy single-scroll PR diff view with review rhythm modes.
--
-- Architecture:
--   One scratch buffer holds all diffs as a continuous document.
--   Each file section is wrapped in a manual fold (separator → last diff line).
--   The file header line sits ABOVE the fold so it is always visible.
--   Reviewed files start with their fold collapsed.
--   Comment badges from review.md are overlaid as virtual text.
--   All actions are buffer-local keymaps.
--
-- Rhythm modes (replaces old focus levels):
--   overview  – all files visible, no dimming (default)
--   focus     – one file at a time; rhythm-next advances; snoozed files skipped
--   sweep     – dim fully-reviewed files; only pending work visible

local M = {}

local config       = require("locoreview.config")
local fs           = require("locoreview.fs")
local git          = require("locoreview.git")
local git_diff     = require("locoreview.git_diff")
local store        = require("locoreview.store")
local ui           = require("locoreview.ui")
local viewed_state = require("locoreview.viewed_state")

-- ── Module state ─────────────────────────────────────────────────────────────

local state = {
  buf               = nil,
  tabpage           = nil,
  line_map          = {},
  fold_ranges       = {},
  file_header_lnums = {},
  hunk_header_lnums = {},
  file_diffs        = {},
  base_ref          = nil,
  timer             = nil,
  timer_end         = nil,
  session_start     = nil,          -- os.time() when PR view was opened
  -- Sticky header float
  sticky_win        = nil,
  sticky_buf        = nil,
  sticky_autocmd    = nil,
  -- Rhythm mode
  rhythm_mode       = "overview",   -- "overview" | "focus" | "sweep"
  rhythm_queue      = {},
  rhythm_file_idx   = 1,
  rhythm_advance_lhs = nil,
  saved_ui          = {},
  -- Dimming namespaces
  dim_ns            = nil,
  -- Hunk spotlight
  hunk_spot_ns      = nil,
  active_file       = nil,
  active_hunk_lnum  = nil,
  -- Hunk context collapse
  hunk_ctx_ns       = nil,
  hunk_ctx_marks    = {},
  -- Heat map
  heat_ns           = nil,
  -- Action hint bar
  hint_win          = nil,
  hint_buf          = nil,
  hint_autocmd      = nil,
  -- Tint namespace
  tint_ns           = nil,
  -- Cursor persistence
  saved_cursor      = nil,
  saved_anchor      = nil,
  pending_cursor    = nil,
  pending_anchor    = nil,
  -- Debounce timer for in_progress marking
  _ip_timer         = nil,
}

local NS_NAME = "locoreview_pr"
local ns      = nil

local function ensure_ns()
  if not ns then ns = vim.api.nvim_create_namespace(NS_NAME) end
  return ns
end

-- ── Highlight groups ──────────────────────────────────────────────────────────

local function setup_hl()
  local defs = {
    -- Cozy header card
    LocoHeaderBorder      = { link = "NonText" },
    LocoHeaderTitle       = { link = "Title" },
    LocoHeaderMood        = { link = "String" },
    LocoHeaderMascot      = { link = "Special" },
    LocoHeaderProgress    = { link = "Normal" },
    LocoHeaderProgressBar = { link = "Statement" },
    LocoHeaderChecklist   = { link = "Comment" },
    LocoHeaderQuiet       = { link = "Comment" },

    -- File headers
    LocoFileHeader    = { link = "Normal" },
    LocoFileViewed    = { link = "Comment" },
    LocoFileDir       = { link = "NonText" },
    LocoFileName      = { link = "Identifier" },
    LocoFileActive    = { link = "CursorLine" },

    -- Hunk headers and spotlight
    LocoHunkHeader    = { link = "Special" },
    LocoHunkActive    = { link = "CursorLine" },
    LocoHunkDim       = { link = "Comment" },
    LocoHunkGutter    = { link = "DiagnosticSignHint" },

    -- File mood dots
    LocoMoodUntouched  = { link = "Comment" },
    LocoMoodInProgress = { link = "DiagnosticSignInfo" },
    LocoMoodReviewed   = { link = "DiagnosticSignOk" },
    LocoMoodSnoozed    = { link = "DiagnosticSignWarn" },
    LocoMoodBlocked    = { link = "DiagnosticSignError" },
    LocoMoodGenerated  = { link = "Comment" },
    LocoMoodRisky      = { link = "DiagnosticSignWarn" },

    -- Diff
    LocoComment       = { link = "DiagnosticVirtualTextInfo" },
    LocoCommentOld    = { link = "DiagnosticVirtualTextWarn" },
    LocoCommentChip   = { link = "DiagnosticVirtualTextInfo" },
    LocoDiffSep       = { link = "NonText" },
    LocoBinaryNote    = { link = "Comment" },
    LocoStatsDim      = { link = "NonText" },

    -- Sections and progress
    LocoSectionHeader  = { link = "NonText" },
    LocoProgressBar    = { link = "Statement" },
    LocoTimerWarn      = { link = "DiagnosticSignError" },
    LocoSuccess        = { link = "DiagnosticSignOk" },

    -- Heat map
    LocoHeatLow       = { link = "DiagnosticSignWarn" },
    LocoHeatHigh      = { link = "DiagnosticSignError" },

    -- Sweep dim
    LocoSweepDim      = { link = "Comment" },
  }
  for name, attrs in pairs(defs) do
    vim.api.nvim_set_hl(0, name, attrs)
  end
end

-- ── Fold text ─────────────────────────────────────────────────────────────────

_G._locoreview_pr_foldtext = function()
  local n = vim.v.foldend - vim.v.foldstart + 1
  return string.format("  .. %d lines folded ..", n)
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function load_review_items()
  local path = fs.review_file_path()
  if not path then return {} end
  local items, _ = store.load(path)
  return items or {}
end

local function run_system_list(cmd)
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then return nil, table.concat(out or {}, "\n") end
  return out
end

local function current_branch_name()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--abbrev-ref", "HEAD" })
  if vim.v.shell_error == 0 and out and out[1] and out[1] ~= "" then
    return out[1]
  end
  return state.base_ref or "HEAD"
end

local function get_entry_mood(entry)
  if not entry then return "untouched" end
  return entry.mood or (entry.viewed and "reviewed" or "untouched")
end

local function build_comment_map(items)
  local map = {}
  for _, item in ipairs(items or {}) do
    map[item.file] = map[item.file] or { new = {}, old = {} }
    local bucket = (item.line_ref == "old") and map[item.file].old or map[item.file].new
    bucket[item.line] = bucket[item.line] or {}
    table.insert(bucket[item.line], item)
  end
  return map
end

local function comment_count_for(file, comment_map)
  local count = 0
  if comment_map[file] then
    for _, bucket in pairs(comment_map[file]) do
      for _, items in pairs(bucket) do
        count = count + #items
      end
    end
  end
  return count
end

-- Effective mood: session > generated > computed (blocked/risky) > persisted
local function get_file_effective_mood(file, vst, comment_map, fd)
  if viewed_state.is_snoozed(file) then return "snoozed" end

  local mood = get_entry_mood(vst[file])
  if mood == "reviewed" then return "reviewed" end

  local cfg = config.get()

  if viewed_state.is_generated(file, cfg.pr_view and cfg.pr_view.generated_patterns) then
    return "generated"
  end

  if comment_map and comment_map[file] then
    for _, bucket in pairs(comment_map[file]) do
      for _, items in pairs(bucket) do
        for _, item in ipairs(items) do
          if item.status == "open" and item.severity == "high" then
            return "blocked"
          end
        end
      end
    end
  end

  if fd then
    local threshold = (cfg.pr_view and cfg.pr_view.risky_threshold) or 150
    if (fd.stats.added + fd.stats.removed) >= threshold
        and comment_count_for(file, comment_map) == 0 then
      return "risky"
    end
  end

  return mood
end

local MOOD_DOT = {
  untouched   = "○",
  in_progress = "◑",
  reviewed    = "●",
  snoozed     = "⏸",
  blocked     = "⊗",
  generated   = "⌁",
  risky       = "⚠",
}

local MOOD_HL = {
  untouched   = "LocoMoodUntouched",
  in_progress = "LocoMoodInProgress",
  reviewed    = "LocoMoodReviewed",
  snoozed     = "LocoMoodSnoozed",
  blocked     = "LocoMoodBlocked",
  generated   = "LocoMoodGenerated",
  risky       = "LocoMoodRisky",
}

-- ── Rendering ─────────────────────────────────────────────────────────────────

local SEP = "  " .. string.rep(".", 24)

local HEADER_PHASES = { "structure", "naming", "edge cases", "tests", "polish" }

local HEADER_QUIET_PHRASES = {
  "small observations still count",
  "clean code reveals itself slowly",
  "one careful pass is enough",
  "follow the sharp edges first",
  "leave the code gentler than you found it",
  "good reviews make future work lighter",
  "take the next file, not the whole PR",
}

local function select_header_mood(progress_pct)
  if progress_pct >= 100 then return "ready to land" end
  if progress_pct >= 95 then return "quiet pass" end
  if progress_pct >= 84 then return "tying loose ends" end
  if progress_pct >= 72 then return "lamplight review" end
  if progress_pct >= 60 then return "checking the edges" end
  if progress_pct >= 48 then return "following the thread" end
  if progress_pct >= 34 then return "deep in the diff" end
  if progress_pct >= 20 then return "steady pace" end
  if progress_pct >= 10 then return "mapping the terrain" end
  return "settling in"
end

local function select_header_mascot(progress_pct, mood)
  if mood == "ready to land" then return "✦_✦" end
  if progress_pct >= 82 then return "ᵔᴗᵔ" end
  if progress_pct >= 56 then return "^_^" end
  if progress_pct >= 28 then return "•_•" end
  return "·ᴗ·"
end

local function select_quiet_phrase(reviewed_count, total_count)
  local minute_seed = math.floor((state.session_start or os.time()) / 60)
  local idx = ((reviewed_count + total_count + minute_seed) % #HEADER_QUIET_PHRASES) + 1
  return HEADER_QUIET_PHRASES[idx]
end

local function render_phase_checklist(progress_pct)
  local total = #HEADER_PHASES
  local complete = math.floor((progress_pct / 100) * total)
  if progress_pct >= 100 then complete = total end
  local active_idx = math.min(total, complete + 1)

  local items = {}
  for i, phase in ipairs(HEADER_PHASES) do
    local mark = "[ ]"
    if i <= complete then
      mark = "[x]"
    elseif i == active_idx and progress_pct < 100 then
      mark = "[~]"
    end
    table.insert(items, mark .. " " .. phase)
  end
  return table.concat(items, "  ")
end

local function timer_status_text()
  if state.timer_end == nil then return nil end
  local remaining = state.timer_end - os.time()
  if remaining > 0 then
    return string.format("%02d:%02d left", math.floor(remaining / 60), remaining % 60)
  end
  return "time's up"
end

local function build_header_model(file_diffs, review_items, file_moods)
  local reviewed_count, snoozed_count = 0, 0
  for _, fd in ipairs(file_diffs) do
    if file_moods[fd.file] == "reviewed" then
      reviewed_count = reviewed_count + 1
    end
    if viewed_state.is_snoozed(fd.file) then
      snoozed_count = snoozed_count + 1
    end
  end

  local total = #file_diffs
  local pct   = total > 0 and math.floor(reviewed_count / total * 100) or 0
  local bar_len = 22
  local filled = total > 0 and math.floor(reviewed_count / total * bar_len) or 0
  local progress_bar = "[" .. string.rep("=", filled) .. string.rep("-", bar_len - filled) .. "]"

  local mood   = select_header_mood(pct)
  local mascot = select_header_mascot(pct, mood)
  local comments = #(review_items or {})

  local mood_parts = {
    mascot .. " " .. mood,
    comments .. " comment" .. (comments == 1 and "" or "s"),
  }
  if snoozed_count > 0 then
    table.insert(mood_parts, snoozed_count .. " snoozed")
  end
  if state.rhythm_mode ~= "overview" then
    table.insert(mood_parts, state.rhythm_mode)
  end
  local timer_text = timer_status_text()
  if timer_text then
    table.insert(mood_parts, timer_text)
  end

  local branch = current_branch_name()
  local target = state.base_ref or "working tree"

  return {
    mascot        = mascot,
    title_line    = string.format("PR Review  %s -> %s", branch, target),
    mood_line     = table.concat(mood_parts, "  ·  "),
    progress_bar  = progress_bar,
    progress_line = string.format("progress %s  %d%%  (%d/%d reviewed)", progress_bar, pct, reviewed_count, total),
    checklist_line = "phases  " .. render_phase_checklist(pct),
    quiet_line    = "quiet  " .. select_quiet_phrase(reviewed_count, total),
  }
end

local function display_width(text)
  if vim.fn and type(vim.fn.strdisplaywidth) == "function" then
    local ok, width = pcall(vim.fn.strdisplaywidth, text)
    if ok and type(width) == "number" then
      return width
    end
  end
  return #text
end

local function pad_right(text, width)
  local w = display_width(text)
  if w >= width then return text end
  return text .. string.rep(" ", width - w)
end

local function render_header_block(model)
  local content = {
    model.title_line,
    model.mood_line,
    model.progress_line,
    model.checklist_line,
    model.quiet_line,
  }
  local content_types = {
    "header_title",
    "header_mood",
    "header_progress",
    "header_checklist",
    "header_quiet",
  }

  local inner_w = 68
  for _, line in ipairs(content) do
    inner_w = math.max(inner_w, display_width(line))
  end

  local border = "  +" .. string.rep("-", inner_w + 2) .. "+"
  local lines  = { border }
  local meta   = { { type = "header_border" } }

  for i, raw in ipairs(content) do
    table.insert(lines, "  | " .. pad_right(raw, inner_w) .. " |")
    local line_meta = {
      type = content_types[i],
      content_col = 4,
      content_len = #raw,
    }
    if content_types[i] == "header_mood" then
      line_meta.mascot_col = 4
      line_meta.mascot_len = #model.mascot
    elseif content_types[i] == "header_progress" then
      local bar_start = raw:find(model.progress_bar, 1, true)
      if bar_start then
        line_meta.bar_col = 4 + bar_start - 1
        line_meta.bar_len = #model.progress_bar
      end
    end
    table.insert(meta, line_meta)
  end

  table.insert(lines, border)
  table.insert(meta, { type = "header_border" })
  return lines, meta
end

-- Gentle section header
local function make_section_header(label, count)
  return string.format("  %s (%d)", label, count)
end

-- File header text + position metadata for inline highlights.
-- Returns: text, meta_positions
local function make_file_header(fd, mood)
  local dot  = MOOD_DOT[mood] or "○"
  local dir  = vim.fn.fnamemodify(fd.file, ":h")
  local name = vim.fn.fnamemodify(fd.file, ":t")

  local path_display, dir_byte_len
  if dir == "." then
    path_display  = name
    dir_byte_len  = 0
  else
    path_display  = dir .. "/" .. name
    dir_byte_len  = #dir + 1   -- include the "/"
  end

  local status = fd.status or "modified"

  -- Layout: "  [dot]  [path]   [status]"
  -- Col 0-1 : "  "   (2 bytes)
  -- Col 2-4 : dot    (3 bytes — all our dots are 3-byte UTF-8)
  -- Col 5-6 : "  "   (2 bytes)
  -- Col 7+  : path   (#path_display bytes)
  -- Then "   " + status
  local text = "  " .. dot .. "  " .. path_display .. "   " .. status

  local path_col   = 7                          -- 0-indexed byte col of path start
  local name_col   = path_col + dir_byte_len     -- byte col of filename within path
  local status_col = path_col + #path_display + 3

  return text, {
    dot_col    = 2,
    dot_len    = 3,
    path_col   = path_col,
    dir_len    = dir_byte_len,
    name_col   = name_col,
    name_len   = #name,
    status_col = status_col,
    status_len = #status,
    fd         = fd,
  }
end

-- Main render: fills state.buf and returns ancillary structures.
local function render(file_diffs, review_items, vst)
  local buf = state.buf

  local lines             = {}
  local line_map          = {}
  local fold_ranges       = {}
  local file_header_lnums = {}
  local hunk_header_lnums = {}

  local comment_map = build_comment_map(review_items)

  -- Pre-compute effective mood for every file
  local file_moods = {}
  for _, fd in ipairs(file_diffs) do
    file_moods[fd.file] = get_file_effective_mood(fd.file, vst, comment_map, fd)
  end

  local header_model = build_header_model(file_diffs, review_items, file_moods)
  local header_lines, header_meta = render_header_block(header_model)
  for i, line in ipairs(header_lines) do
    table.insert(lines, line)
    line_map[#lines] = header_meta[i]
  end
  table.insert(lines, "")
  line_map[#lines] = { type = "gap" }
  table.insert(lines, "")
  line_map[#lines] = { type = "gap" }

  -- Split into reviewed vs to-review
  local first_unreviewed_idx = nil
  for fi, fd in ipairs(file_diffs) do
    if file_moods[fd.file] ~= "reviewed" then
      first_unreviewed_idx = fi
      break
    end
  end
  local reviewed_count = first_unreviewed_idx and (first_unreviewed_idx - 1) or #file_diffs

  -- Helper: append file section (hunks + separator)
  local function append_file_section(fi, fd, is_reviewed)
    local mood   = file_moods[fd.file]
    local text, hdr_pos = make_file_header(fd, mood)
    table.insert(lines, text)
    local header_lnum = #lines
    line_map[header_lnum] = vim.tbl_extend("force", hdr_pos, {
      file      = fd.file,
      type      = "file_header",
      file_idx  = fi,
      mood      = mood,
      is_viewed = is_reviewed,   -- backwards compat
    })
    table.insert(file_header_lnums, header_lnum)

    local fold_start = #lines + 1

    table.insert(lines, SEP)
    line_map[#lines] = { file = fd.file, type = "separator", file_idx = fi }

    if fd.status == "binary" then
      table.insert(lines, "  (binary file – diff not available)")
      line_map[#lines] = { file = fd.file, type = "binary_note", file_idx = fi }
    else
      for hi, hunk in ipairs(fd.hunks) do
        table.insert(lines, hunk.header)
        local hh_lnum = #lines
        line_map[hh_lnum] = { file = fd.file, type = "hunk_header",
                               hunk_idx = hi, file_idx = fi }
        table.insert(hunk_header_lnums, hh_lnum)

        for _, dl in ipairs(hunk.lines) do
          table.insert(lines, dl.text)
          local lnum = #lines
          line_map[lnum] = {
            file     = fd.file,
            type     = dl.type,
            old_line = dl.old_line,
            new_line = dl.new_line,
            hunk_idx = hi,
            file_idx = fi,
          }
        end

        if hi < #fd.hunks then
          table.insert(lines, "")
          line_map[#lines] = { file = fd.file, type = "blank", file_idx = fi }
        end
      end
    end

    local fold_stop = #lines
    if fold_start <= fold_stop then
      table.insert(fold_ranges, {
        start     = fold_start,
        stop      = fold_stop,
        file      = fd.file,
        file_idx  = fi,
        is_viewed = is_reviewed,
      })
    end

    -- Breathing room between files
    table.insert(lines, "")
    line_map[#lines] = { type = "gap" }
  end

  -- ── REVIEWED section ──────────────────────────────────────────────────────
  if reviewed_count > 0 then
    table.insert(lines, make_section_header("reviewed", reviewed_count))
    line_map[#lines] = { type = "section_header", section = "reviewed" }
    local fold_start = #lines + 1

    for fi, fd in ipairs(file_diffs) do
      if file_moods[fd.file] ~= "reviewed" then break end
      append_file_section(fi, fd, true)
    end

    local fold_stop = #lines
    if fold_start <= fold_stop then
      table.insert(fold_ranges, {
        start = fold_start, stop = fold_stop,
        file = nil, is_viewed = true, section = "reviewed",
      })
    end
  end

  -- ── TO REVIEW section ─────────────────────────────────────────────────────
  if first_unreviewed_idx then
    local unreviewed_count = #file_diffs - first_unreviewed_idx + 1
    table.insert(lines, make_section_header("to review", unreviewed_count))
    line_map[#lines] = { type = "section_header", section = "unviewed" }

    for fi, fd in ipairs(file_diffs) do
      if fi < first_unreviewed_idx then goto continue end
      append_file_section(fi, fd, false)
      ::continue::
    end

    -- "Done for now" banner when everything non-snoozed is handled
    local all_handled = true
    for _, fd in ipairs(file_diffs) do
      local m = file_moods[fd.file]
      if m ~= "reviewed" and m ~= "snoozed" and m ~= "generated" then
        all_handled = false
        break
      end
    end
    if all_handled and #file_diffs > 0 then
      local snoozed_n = 0
      for _, fd in ipairs(file_diffs) do
        if viewed_state.is_snoozed(fd.file) then snoozed_n = snoozed_n + 1 end
      end
      local done_text = "  ✦  all caught up — " .. reviewed_count .. " reviewed"
      if snoozed_n > 0 then done_text = done_text .. ", " .. snoozed_n .. " snoozed" end
      table.insert(lines, "")
      line_map[#lines] = { type = "gap" }
      table.insert(lines, done_text)
      line_map[#lines] = { type = "done_summary" }
    end
  end

  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  return line_map, fold_ranges, file_header_lnums, hunk_header_lnums
end

-- ── Decorations ───────────────────────────────────────────────────────────────

local function apply_highlights(line_map)
  local buf = state.buf
  local n   = ensure_ns()
  vim.api.nvim_buf_clear_namespace(buf, n, 0, -1)

  for lnum, meta in pairs(line_map) do
    local l0 = lnum - 1
    local t  = meta.type

    if t == "header_border" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoHeaderBorder", l0, 0, -1)

    elseif t == "header_title" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoHeaderTitle", l0, 0, -1)

    elseif t == "header_mood" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoHeaderMood", l0, 0, -1)
      if meta.mascot_col and meta.mascot_len and meta.mascot_len > 0 then
        vim.api.nvim_buf_set_extmark(buf, n, l0, meta.mascot_col, {
          end_col  = meta.mascot_col + meta.mascot_len,
          hl_group = "LocoHeaderMascot",
          priority = 190,
        })
      end

    elseif t == "header_progress" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoHeaderProgress", l0, 0, -1)
      if meta.bar_col and meta.bar_len and meta.bar_len > 0 then
        vim.api.nvim_buf_set_extmark(buf, n, l0, meta.bar_col, {
          end_col  = meta.bar_col + meta.bar_len,
          hl_group = "LocoHeaderProgressBar",
          priority = 190,
        })
      end

    elseif t == "header_checklist" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoHeaderChecklist", l0, 0, -1)

    elseif t == "header_quiet" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoHeaderQuiet", l0, 0, -1)

    elseif t == "progress" then
      local hl = "LocoProgressBar"
      if state.timer_end then
        local rem = state.timer_end - os.time()
        if rem > 0 and rem <= 120 then hl = "LocoTimerWarn" end
      end
      vim.api.nvim_buf_add_highlight(buf, n, hl, l0, 0, -1)

    elseif t == "section_header" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoSectionHeader", l0, 0, -1)

    elseif t == "file_header" then
      local base_hl = (meta.mood == "reviewed") and "LocoFileViewed" or "LocoFileHeader"
      vim.api.nvim_buf_add_highlight(buf, n, base_hl, l0, 0, -1)

      -- Mood dot colour (cols 2–4, 3 bytes)
      vim.api.nvim_buf_set_extmark(buf, n, l0, meta.dot_col or 2, {
        end_col  = (meta.dot_col or 2) + (meta.dot_len or 3),
        hl_group = MOOD_HL[meta.mood] or "LocoMoodUntouched",
        priority = 170,
      })

      -- Dim directory prefix
      if meta.dir_len and meta.dir_len > 0 and meta.path_col then
        vim.api.nvim_buf_set_extmark(buf, n, l0, meta.path_col, {
          end_col  = meta.path_col + meta.dir_len,
          hl_group = "LocoFileDir",
          priority = 160,
        })
      end

      -- Keep filename as the visual anchor
      if meta.name_col and meta.name_len and meta.name_len > 0 then
        vim.api.nvim_buf_set_extmark(buf, n, l0, meta.name_col, {
          end_col  = meta.name_col + meta.name_len,
          hl_group = "LocoFileName",
          priority = 170,
        })
      end

      -- Dim status pill
      if meta.status_col and meta.status_len and meta.status_len > 0 then
        vim.api.nvim_buf_set_extmark(buf, n, l0, meta.status_col, {
          end_col  = meta.status_col + meta.status_len,
          hl_group = "LocoStatsDim",
          priority = 160,
        })
      end

      -- Right-aligned diff stats
      if meta.fd then
        local stats = string.format("+%d  -%d", meta.fd.stats.added, meta.fd.stats.removed)
        vim.api.nvim_buf_set_extmark(buf, n, l0, 0, {
          virt_text     = { { stats, "LocoStatsDim" } },
          virt_text_pos = "right_align",
          priority      = 100,
        })
      end

    elseif t == "separator" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoDiffSep", l0, 0, -1)

    elseif t == "hunk_header" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoHunkHeader", l0, 0, -1)

    elseif t == "add" then
      vim.api.nvim_buf_add_highlight(buf, n, "DiffAdd", l0, 0, -1)

    elseif t == "remove" then
      vim.api.nvim_buf_add_highlight(buf, n, "DiffDelete", l0, 0, -1)

    elseif t == "binary_note" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoBinaryNote", l0, 0, -1)

    elseif t == "done_summary" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoSuccess", l0, 0, -1)
    end
  end
end

local function apply_comment_badges(line_map, comment_map)
  local buf = state.buf
  local n   = ensure_ns()

  -- Inline diff line badges
  for lnum, meta in pairs(line_map) do
    local items = nil
    if meta.file and (meta.type == "add" or meta.type == "context") and meta.new_line then
      local fc = comment_map[meta.file]
      items = fc and fc.new and fc.new[meta.new_line]
    elseif meta.file and meta.type == "remove" and meta.old_line then
      local fc = comment_map[meta.file]
      items = fc and fc.old and fc.old[meta.old_line]
    end

    if items and #items > 0 then
      local is_old = meta.type == "remove"
      local badges = {}
      for _, item in ipairs(items) do
        local preview = item.issue:sub(1, 45)
        if #item.issue > 45 then preview = preview .. "…" end
        table.insert(badges, item.id .. ": " .. preview)
      end
      vim.api.nvim_buf_set_extmark(buf, n, lnum - 1, 0, {
        virt_text     = { { "  💬 " .. table.concat(badges, " | "),
                           is_old and "LocoCommentOld" or "LocoComment" } },
        virt_text_pos = "eol",
      })
    end
  end

  -- Comment count chip on file header lines
  for _, header_lnum in ipairs(state.file_header_lnums) do
    local header_meta = state.line_map[header_lnum]
    if header_meta and header_meta.file then
      local count = comment_count_for(header_meta.file, comment_map)
      if count > 0 then
        vim.api.nvim_buf_set_extmark(buf, n, header_lnum - 1, 0, {
          virt_text     = { { "  💬 " .. count, "LocoCommentChip" } },
          virt_text_pos = "eol",
          priority      = 90,
        })
      end
    end
  end
end

local function apply_heat_map(comment_map)
  local heat_ns = state.heat_ns or vim.api.nvim_create_namespace("locoreview_pr_heat")
  state.heat_ns = heat_ns
  vim.api.nvim_buf_clear_namespace(state.buf, heat_ns, 0, -1)

  for _, lnum in ipairs(state.file_header_lnums) do
    local file = state.line_map[lnum] and state.line_map[lnum].file
    if file then
      local count = comment_count_for(file, comment_map)
      if count > 0 then
        local hl = count >= 3 and "LocoHeatHigh" or "LocoHeatLow"
        vim.api.nvim_buf_set_extmark(state.buf, heat_ns, lnum - 1, 0, {
          sign_text     = "▌",
          sign_hl_group = hl,
        })
      end
    end
  end
end

-- Hunk spotlight: subtle tint on active hunk, dim other hunks in same file.
local function apply_hunk_spotlight(active_hunk_lnum)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end

  local spot_ns = state.hunk_spot_ns or vim.api.nvim_create_namespace("locoreview_pr_spot")
  state.hunk_spot_ns = spot_ns

  local hdim_ns = vim.api.nvim_create_namespace("locoreview_pr_hdim2")

  vim.api.nvim_buf_clear_namespace(state.buf, spot_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(state.buf, hdim_ns, 0, -1)

  if not active_hunk_lnum then return end

  local active_meta = state.line_map[active_hunk_lnum]
  if not active_meta then return end

  local a_hunk = active_meta.hunk_idx
  local a_file = active_meta.file_idx

  -- Gutter mark on hunk header
  vim.api.nvim_buf_set_extmark(state.buf, spot_ns, active_hunk_lnum - 1, 0, {
    sign_text     = "▌",
    sign_hl_group = "LocoHunkGutter",
  })

  -- Subtle tint on all lines of active hunk; dim other hunks in same file
  for lnum, meta in pairs(state.line_map) do
    if meta.file_idx == a_file and meta.hunk_idx then
      if meta.hunk_idx == a_hunk then
        vim.api.nvim_buf_set_extmark(state.buf, spot_ns, lnum - 1, 0, {
          line_hl_group = "LocoHunkActive",
          priority      = 50,
        })
      else
        vim.api.nvim_buf_set_extmark(state.buf, hdim_ns, lnum - 1, 0, {
          hl_group = "LocoHunkDim",
          priority = 55,
        })
      end
    end
  end
end

-- Active-file background tint on the file header line.
local function apply_active_file_tint(active_file)
  local tint_ns = state.tint_ns or vim.api.nvim_create_namespace("locoreview_pr_tint")
  state.tint_ns = tint_ns
  vim.api.nvim_buf_clear_namespace(state.buf, tint_ns, 0, -1)
  if not active_file then return end

  for lnum, meta in pairs(state.line_map) do
    if meta.type == "file_header" and meta.file == active_file then
      local end_col = 0
      if meta.status_col and meta.status_len then
        end_col = meta.status_col + meta.status_len
      elseif meta.name_col and meta.name_len then
        end_col = meta.name_col + meta.name_len
      end
      vim.api.nvim_buf_set_extmark(state.buf, tint_ns, lnum - 1, 0, {
        end_col  = end_col > 0 and end_col or nil,
        hl_group = "LocoFileActive",
        priority = 40,
      })
    end
  end
end

-- ── Folds ─────────────────────────────────────────────────────────────────────

local function setup_folds(win, fold_ranges)
  vim.api.nvim_win_call(win, function()
    vim.cmd("setlocal foldmethod=manual")
    vim.cmd("setlocal foldtext=v:lua._locoreview_pr_foldtext()")
    vim.cmd("setlocal foldlevel=99")
    vim.cmd("normal! zE")
    for _, fr in ipairs(fold_ranges) do
      if fr.start <= fr.stop then
        vim.cmd(string.format("%d,%dfold", fr.start, fr.stop))
        if fr.is_viewed then
          vim.api.nvim_win_set_cursor(0, { fr.start, 0 })
          vim.cmd("normal! zc")
        end
      end
    end
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
  end)
end

-- ── Window helpers ────────────────────────────────────────────────────────────

local function is_alive()
  return state.tabpage ~= nil and vim.api.nvim_tabpage_is_valid(state.tabpage)
end

local function get_win()
  if not is_alive() then return nil end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
    if vim.api.nvim_win_get_buf(win) == state.buf then return win end
  end
  return nil
end

-- ── Cursor / meta helpers ─────────────────────────────────────────────────────

local function meta_at_cursor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return state.line_map[lnum], lnum
end

local function line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return #lines
end

local function clamp_cursor_target(target)
  if not (target and target[1]) then return nil end
  local max_lnum = math.max(1, line_count(state.buf))
  local lnum = math.min(math.max(target[1], 1), max_lnum)
  local col = math.max(target[2] or 0, 0)
  return { lnum, col }
end

local function capture_cursor_anchor(meta, lnum, col)
  local anchor = {
    lnum = lnum,
    col  = col or 0,
  }
  if meta and meta.file then
    anchor.file     = meta.file
    anchor.type     = meta.type
    anchor.hunk_idx = meta.hunk_idx
    anchor.old_line = meta.old_line
    anchor.new_line = meta.new_line
  end
  return anchor
end

local function capture_cursor_anchor_from_win(win)
  if not win then return nil end
  local cur = vim.api.nvim_win_get_cursor(win)
  local lnum = cur[1]
  local col  = cur[2] or 0
  local meta = state.line_map[lnum]
  return capture_cursor_anchor(meta, lnum, col)
end

local function queue_cursor_restore(meta, lnum, col)
  if not lnum then return end
  local anchor = capture_cursor_anchor(meta, lnum, col)
  state.pending_anchor = anchor
  state.pending_cursor = { lnum, col or 0 } -- backwards-compat fallback
end

local function resolve_anchor_to_cursor(anchor)
  if not anchor then return nil end
  local col = anchor.col or 0

  if anchor.file and anchor.type then
    -- Best effort: same concrete diff line.
    if anchor.type == "add" or anchor.type == "remove" or anchor.type == "context" then
      for lnum, meta in pairs(state.line_map) do
        if meta.file == anchor.file and meta.type == anchor.type then
          local old_ok = (anchor.old_line == nil) or (meta.old_line == anchor.old_line)
          local new_ok = (anchor.new_line == nil) or (meta.new_line == anchor.new_line)
          if old_ok and new_ok then
            return { lnum, col }
          end
        end
      end
    end

    if anchor.type == "hunk_header" and anchor.hunk_idx then
      for _, lnum in ipairs(state.hunk_header_lnums) do
        local meta = state.line_map[lnum]
        if meta and meta.file == anchor.file and meta.hunk_idx == anchor.hunk_idx then
          return { lnum, col }
        end
      end
    end
  end

  -- Fallback: same file header.
  if anchor.file then
    for _, lnum in ipairs(state.file_header_lnums) do
      local meta = state.line_map[lnum]
      if meta and meta.file == anchor.file then
        return { lnum, 0 }
      end
    end
  end

  if anchor.lnum then
    return clamp_cursor_target({ anchor.lnum, col })
  end
  return nil
end

local function diff_hash_for(file)
  for _, fd in ipairs(state.file_diffs) do
    if fd.file == file then return fd.diff_hash end
  end
  return ""
end

local function fold_range_for(file)
  for _, fr in ipairs(state.fold_ranges) do
    if fr.file == file then return fr end
  end
  return nil
end

local function hunk_header_lnum_at_lnum(lnum)
  local meta = state.line_map[lnum]
  if not meta or not meta.hunk_idx or not meta.file_idx then return nil end
  for i = #state.hunk_header_lnums, 1, -1 do
    local h  = state.hunk_header_lnums[i]
    local hm = state.line_map[h]
    if hm and hm.hunk_idx == meta.hunk_idx and hm.file_idx == meta.file_idx then
      return h
    end
  end
  return nil
end

local function hunk_header_lnum_at_cursor()
  return hunk_header_lnum_at_lnum(vim.api.nvim_win_get_cursor(0)[1])
end

-- ── Navigation ────────────────────────────────────────────────────────────────

local function navigate_files(direction)
  local lnum    = vim.api.nvim_win_get_cursor(0)[1]
  local headers = state.file_header_lnums
  if direction > 0 then
    for _, hl in ipairs(headers) do
      if hl > lnum then
        vim.api.nvim_win_set_cursor(0, { hl, 0 })
        return
      end
    end
  else
    for i = #headers, 1, -1 do
      if headers[i] < lnum then
        vim.api.nvim_win_set_cursor(0, { headers[i], 0 })
        return
      end
    end
  end
end

local function navigate_hunks(direction)
  local lnum  = vim.api.nvim_win_get_cursor(0)[1]
  local hunks = state.hunk_header_lnums
  if direction > 0 then
    for _, hl in ipairs(hunks) do
      if hl > lnum then
        vim.api.nvim_win_set_cursor(0, { hl, 0 })
        return
      end
    end
  else
    for i = #hunks, 1, -1 do
      if hunks[i] < lnum then
        vim.api.nvim_win_set_cursor(0, { hunks[i], 0 })
        return
      end
    end
  end
end

-- ── Sticky header float ───────────────────────────────────────────────────────

local function update_sticky_header()
  if not state.sticky_win or not vim.api.nvim_win_is_valid(state.sticky_win) then return end
  local win = get_win()
  if not win then return end

  local top = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)

  local header_lnum = nil
  for i = #state.file_header_lnums, 1, -1 do
    if state.file_header_lnums[i] <= top then
      header_lnum = state.file_header_lnums[i]
      break
    end
  end

  vim.api.nvim_buf_set_option(state.sticky_buf, "modifiable", true)
  vim.api.nvim_buf_clear_namespace(state.sticky_buf, ensure_ns(), 0, -1)
  if not header_lnum or header_lnum == top then
    local top_text = vim.api.nvim_buf_get_lines(state.buf, top - 1, top, false)[1]
    vim.api.nvim_buf_set_lines(state.sticky_buf, 0, -1, false, { top_text or "" })
  else
    local text = vim.api.nvim_buf_get_lines(state.buf, header_lnum - 1, header_lnum, false)[1]
    vim.api.nvim_buf_set_lines(state.sticky_buf, 0, -1, false, { text or "" })
    local meta = state.line_map[header_lnum]
    local hl   = (meta and meta.mood == "reviewed") and "LocoFileViewed" or "LocoFileHeader"
    vim.api.nvim_buf_add_highlight(state.sticky_buf, ensure_ns(), hl, 0, 0, -1)
  end
  vim.api.nvim_buf_set_option(state.sticky_buf, "modifiable", false)
end

local function create_sticky_header(win)
  if state.sticky_win and vim.api.nvim_win_is_valid(state.sticky_win) then return end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype",  "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

  local float_win = vim.api.nvim_open_win(buf, false, {
    relative  = "win",
    win       = win,
    row       = 0, col = 0,
    width     = vim.api.nvim_win_get_width(win),
    height    = 1,
    focusable = false,
    style     = "minimal",
    zindex    = 50,
  })
  state.sticky_win = float_win
  state.sticky_buf = buf
  state.sticky_autocmd = vim.api.nvim_create_autocmd("WinScrolled", {
    callback = function() update_sticky_header() end,
  })
end

-- ── Action hint bar ───────────────────────────────────────────────────────────

local HINT_CONTEXTS = {
  file_header = "  v reviewed  ·  s snooze  ·  <CR> expand  ·  go open  ·  d/<leader>a actions  ·  ? help",
  hunk_header = "  c comment  ·  zC collapse  ·  ]c next hunk  ·  v reviewed  ·  s snooze",
  diff        = "  c comment  ·  C quick note  ·  K show note  ·  v reviewed  ·  ]f next file",
  default     = "  ]f/[f files  ·  ]c/[c hunks  ·  <leader>F rhythm  ·  R refresh  ·  q close",
}

local function hint_text_for(meta)
  if not meta then return HINT_CONTEXTS.default end
  local t = meta.type
  if t == "file_header" then return HINT_CONTEXTS.file_header
  elseif t == "hunk_header" then return HINT_CONTEXTS.hunk_header
  elseif t == "add" or t == "remove" or t == "context" then return HINT_CONTEXTS.diff
  else return HINT_CONTEXTS.default
  end
end

local function update_hint_bar(meta)
  if not state.hint_win or not vim.api.nvim_win_is_valid(state.hint_win) then return end
  local text = hint_text_for(meta)
  vim.api.nvim_buf_set_option(state.hint_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.hint_buf, 0, -1, false, { text })
  vim.api.nvim_buf_set_option(state.hint_buf, "modifiable", false)
end

local function create_hint_bar(win)
  if not (config.get().pr_view and config.get().pr_view.action_hints ~= false) then return end
  if state.hint_win and vim.api.nvim_win_is_valid(state.hint_win) then return end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype",  "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

  local win_height = vim.api.nvim_win_get_height(win)
  local win_width  = vim.api.nvim_win_get_width(win)

  local hint_win = vim.api.nvim_open_win(buf, false, {
    relative  = "win",
    win       = win,
    row       = win_height - 1,
    col       = 0,
    width     = win_width,
    height    = 1,
    focusable = false,
    style     = "minimal",
    zindex    = 49,
  })

  vim.api.nvim_win_set_option(hint_win, "winhl", "Normal:StatusLine")

  state.hint_win = hint_win
  state.hint_buf = buf

  update_hint_bar(nil)
end

-- ── Hunk context collapse ─────────────────────────────────────────────────────

local function get_context_lnums_for_hunk(hunk_header_lnum)
  local meta = state.line_map[hunk_header_lnum]
  if not meta then return {} end
  local lnums = {}
  for lnum, lm in pairs(state.line_map) do
    if lm.hunk_idx == meta.hunk_idx
        and lm.file_idx == meta.file_idx
        and lm.type == "context" then
      table.insert(lnums, lnum)
    end
  end
  table.sort(lnums)
  return lnums
end

local function collapse_hunk_context(hunk_header_lnum)
  if state.hunk_ctx_marks[hunk_header_lnum] then return end
  local lnums = get_context_lnums_for_hunk(hunk_header_lnum)
  if #lnums == 0 then return end

  local ctx_ns = state.hunk_ctx_ns or vim.api.nvim_create_namespace("locoreview_pr_ctx")
  state.hunk_ctx_ns = ctx_ns

  local ids = {}
  for _, lnum in ipairs(lnums) do
    local id = vim.api.nvim_buf_set_extmark(state.buf, ctx_ns, lnum - 1, 0, { conceal = " " })
    table.insert(ids, id)
  end
  local last = lnums[#lnums]
  local id2 = vim.api.nvim_buf_set_extmark(state.buf, ctx_ns, last - 1, 0, {
    virt_lines = { { { "  [· " .. #lnums .. " context lines ·]", "Comment" } } },
  })
  table.insert(ids, id2)
  state.hunk_ctx_marks[hunk_header_lnum] = ids

  local win = get_win()
  if win then vim.api.nvim_win_set_option(win, "conceallevel", 2) end
end

local function expand_hunk_context(hunk_header_lnum)
  local ids = state.hunk_ctx_marks[hunk_header_lnum]
  if not ids then return end
  for _, id in ipairs(ids) do
    if state.hunk_ctx_ns then
      pcall(vim.api.nvim_buf_del_extmark, state.buf, state.hunk_ctx_ns, id)
    end
  end
  state.hunk_ctx_marks[hunk_header_lnum] = nil
  if not next(state.hunk_ctx_marks) then
    local win = get_win()
    if win then vim.api.nvim_win_set_option(win, "conceallevel", 0) end
  end
end

-- ── Rhythm mode (replaces focus modes) ───────────────────────────────────────

local function apply_dim_layer(except_file)
  local dim_ns = state.dim_ns or vim.api.nvim_create_namespace("locoreview_pr_dim")
  state.dim_ns = dim_ns
  vim.api.nvim_buf_clear_namespace(state.buf, dim_ns, 0, -1)

  for lnum, meta in pairs(state.line_map) do
    if meta.file and meta.file ~= except_file
        and meta.type ~= "section_header"
        and meta.type ~= "progress" then
      vim.api.nvim_buf_set_extmark(state.buf, dim_ns, lnum - 1, 0, {
        hl_group = "Comment",
        priority = 200,
      })
    end
  end
end

local function apply_sweep_dim()
  local dim_ns = state.dim_ns or vim.api.nvim_create_namespace("locoreview_pr_dim")
  state.dim_ns = dim_ns
  vim.api.nvim_buf_clear_namespace(state.buf, dim_ns, 0, -1)

  local vst = viewed_state.load()
  for lnum, meta in pairs(state.line_map) do
    if meta.file then
      local mood = get_entry_mood(vst[meta.file])
      if mood == "reviewed" and not viewed_state.is_snoozed(meta.file) then
        vim.api.nvim_buf_set_extmark(state.buf, dim_ns, lnum - 1, 0, {
          hl_group = "LocoSweepDim",
          priority = 200,
        })
      end
    end
  end
end

local function apply_rhythm_dims()
  if state.rhythm_mode == "focus" then
    local file = state.rhythm_queue[state.rhythm_file_idx]
    if file then apply_dim_layer(file) end
  elseif state.rhythm_mode == "sweep" then
    apply_sweep_dim()
  end
end

local function build_rhythm_queue()
  local vst         = viewed_state.load()
  local review_items = load_review_items()
  local comment_map  = build_comment_map(review_items)

  local priority = {
    blocked     = 0,
    risky       = 1,
    in_progress = 2,
    untouched   = 3,
    generated   = 4,
    snoozed     = 5,
    reviewed    = 6,
  }

  local items = {}
  for _, fd in ipairs(state.file_diffs) do
    local mood = get_file_effective_mood(fd.file, vst, comment_map, fd)
    table.insert(items, { file = fd.file, mood = mood, pri = priority[mood] or 99 })
  end
  table.sort(items, function(a, b) return a.pri < b.pri end)

  local queue = {}
  for _, item in ipairs(items) do
    table.insert(queue, item.file)
  end
  return queue
end

local rhythm_advance   -- forward declaration

local function resolve_rhythm_advance_lhs()
  local cfg = config.get().pr_view or {}
  if type(cfg.rhythm_advance_key) == "string" and cfg.rhythm_advance_key ~= "" then
    return cfg.rhythm_advance_key
  end
  if vim.g.mapleader == " " then
    return "<Tab>"
  end
  return "<Space>"
end

local function rhythm_advance_lhs()
  return state.rhythm_advance_lhs or resolve_rhythm_advance_lhs()
end

local function clear_rhythm_advance_map(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    state.rhythm_advance_lhs = nil
    return
  end
  local lhs = rhythm_advance_lhs()
  pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  state.rhythm_advance_lhs = nil
end

local function set_rhythm_advance_map(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local lhs = resolve_rhythm_advance_lhs()
  clear_rhythm_advance_map(buf)
  vim.keymap.set("n", lhs, rhythm_advance, { noremap = true, silent = true, buffer = buf })
  state.rhythm_advance_lhs = lhs
end

rhythm_advance = function()
  if state.rhythm_mode == "overview" then
    local key = vim.api.nvim_replace_termcodes(rhythm_advance_lhs(), true, false, true)
    vim.api.nvim_feedkeys(key, "n", false)
    return
  end

  local vst = viewed_state.load()

  -- Build a list of files to advance through
  local candidates = {}
  for _, file in ipairs(state.rhythm_queue) do
    local mood = get_entry_mood(vst[file])
    if state.rhythm_mode == "focus" then
      if not viewed_state.is_snoozed(file) then
        table.insert(candidates, file)
      end
    else  -- sweep
      if mood ~= "reviewed" and not viewed_state.is_snoozed(file) then
        table.insert(candidates, file)
      end
    end
  end

  if #candidates == 0 then
    ui.notify("all files handled", vim.log.levels.INFO)
    return
  end

  -- Find next candidate after current file
  local current_file = state.rhythm_queue[state.rhythm_file_idx]
  local next_file    = candidates[1]
  local found_current = false
  for _, f in ipairs(candidates) do
    if found_current then next_file = f; break end
    if f == current_file then found_current = true end
  end

  -- Find the header lnum for next_file
  for _, lnum in ipairs(state.file_header_lnums) do
    if state.line_map[lnum] and state.line_map[lnum].file == next_file then
      -- Update queue index
      for i, f in ipairs(state.rhythm_queue) do
        if f == next_file then state.rhythm_file_idx = i; break end
      end

      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      vim.cmd("normal! zz")

      if state.rhythm_mode == "focus" then
        apply_dim_layer(next_file)
      end
      return
    end
  end
end

local function cycle_rhythm()
  local modes = { "overview", "focus", "sweep" }
  local cur_idx = 1
  for i, m in ipairs(modes) do
    if m == state.rhythm_mode then cur_idx = i; break end
  end
  local next_mode = modes[(cur_idx % #modes) + 1]
  state.rhythm_mode = next_mode

  -- Clear existing dims
  if state.dim_ns and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, state.dim_ns, 0, -1)
  end

  local buf = state.buf

  if next_mode == "overview" then
    -- Restore UI chrome
    if state.saved_ui.laststatus  then vim.o.laststatus  = state.saved_ui.laststatus  end
    if state.saved_ui.showtabline then vim.o.showtabline = state.saved_ui.showtabline end
    state.saved_ui  = {}
    state.rhythm_queue = {}

    clear_rhythm_advance_map(buf)

    M.refresh()
    vim.api.nvim_echo({ { "  Rhythm: overview — scanning", "ModeMsg" } }, false, {})

  elseif next_mode == "focus" then
    state.saved_ui.laststatus  = vim.o.laststatus
    state.saved_ui.showtabline = vim.o.showtabline
    vim.o.laststatus  = 0
    vim.o.showtabline = 0

    state.rhythm_queue    = build_rhythm_queue()
    state.rhythm_file_idx = 1

    if #state.rhythm_queue > 0 then
      local first = state.rhythm_queue[1]
      apply_dim_layer(first)
      for _, lnum in ipairs(state.file_header_lnums) do
        if state.line_map[lnum] and state.line_map[lnum].file == first then
          vim.api.nvim_win_set_cursor(0, { lnum, 0 })
          vim.cmd("normal! zz")
          break
        end
      end
    end

    set_rhythm_advance_map(buf)

    M.refresh()
    vim.api.nvim_echo(
      { { "  Rhythm: focus — in flow  (" .. rhythm_advance_lhs() .. " next, s snooze)", "ModeMsg" } },
      false,
      {}
    )

  elseif next_mode == "sweep" then
    if state.saved_ui.laststatus  then vim.o.laststatus  = state.saved_ui.laststatus  end
    if state.saved_ui.showtabline then vim.o.showtabline = state.saved_ui.showtabline end
    state.saved_ui = {}

    state.rhythm_queue    = build_rhythm_queue()
    state.rhythm_file_idx = 1
    apply_sweep_dim()

    set_rhythm_advance_map(buf)

    M.refresh()
    vim.api.nvim_echo(
      { { "  Rhythm: sweep — wrapping up  (" .. rhythm_advance_lhs() .. " next unreviewed)", "ModeMsg" } },
      false,
      {}
    )
  end
end

-- ── File picker ───────────────────────────────────────────────────────────────

local function toggle_fold_at(lnum)
  local meta = state.line_map[lnum]
  if meta and meta.type == "file_header" then
    local fr = fold_range_for(meta.file)
    if fr then
      vim.api.nvim_win_set_cursor(0, { fr.start, 0 })
      vim.cmd("normal! za")
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    end
  else
    vim.cmd("normal! za")
  end
end

local function open_file_picker()
  local review_items = load_review_items()
  local comment_map  = build_comment_map(review_items)
  local vst          = viewed_state.load()

  local entries = {}
  for _, fd in ipairs(state.file_diffs) do
    local header_lnum = nil
    for _, lnum in ipairs(state.file_header_lnums) do
      if state.line_map[lnum] and state.line_map[lnum].file == fd.file then
        header_lnum = lnum
        break
      end
    end

    local mood         = get_file_effective_mood(fd.file, vst, comment_map, fd)
    local is_reviewed  = mood == "reviewed"
    local dot          = MOOD_DOT[mood] or "○"
    local count        = comment_count_for(fd.file, comment_map)
    local comment_str  = count > 0 and ("  💬 " .. count) or ""
    local snooze_str   = viewed_state.is_snoozed(fd.file) and "  ⏸" or ""
    local display      = dot .. " " .. fd.file .. "  +" .. fd.stats.added .. " -" .. fd.stats.removed
                         .. "  " .. (fd.status or "modified") .. comment_str .. snooze_str

    table.insert(entries, {
      display     = display,
      file        = fd.file,
      is_reviewed = is_reviewed,
      header_lnum = header_lnum,
      ord         = is_reviewed and 1 or 0,
      index       = #entries,
    })
  end

  table.sort(entries, function(a, b)
    if a.ord ~= b.ord then return a.ord < b.ord end
    return a.index < b.index
  end)

  vim.ui.select(entries, {
    prompt      = "Jump to file:",
    format_item = function(e) return e.display end,
  }, function(choice)
    if not choice or not choice.header_lnum then return end
    local win = get_win()
    if not win then return end
    vim.api.nvim_win_set_cursor(win, { choice.header_lnum, 0 })
    if choice.is_reviewed then
      toggle_fold_at(choice.header_lnum)
    end
  end)
end

-- ── Review actions ────────────────────────────────────────────────────────────

local function mark_reviewed_at_cursor()
  local meta, lnum = meta_at_cursor()
  if not meta or not meta.file then
    ui.notify("not on a diff line", vim.log.levels.WARN)
    return
  end

  local file = meta.file
  queue_cursor_restore(meta, lnum, 0)
  viewed_state.mark_reviewed(file, diff_hash_for(file))

  -- Micro-reward animation
  if config.get().pr_view.micro_rewards then
    local header_lnum = nil
    for _, lnum in ipairs(state.file_header_lnums) do
      if state.line_map[lnum] and state.line_map[lnum].file == file then
        header_lnum = lnum
        break
      end
    end
    if header_lnum then
      local n = ensure_ns()
      vim.api.nvim_buf_set_extmark(state.buf, n, header_lnum - 1, 0, {
        virt_text     = { { "  ● reviewed ✦", "DiagnosticSignOk" } },
        virt_text_pos = "eol",
      })
    end
    vim.defer_fn(function() M.refresh() end, 350)
  else
    M.refresh()
  end

  if config.get().pr_view.auto_advance_on_viewed then
    local vst = viewed_state.load()
    for _, lnum in ipairs(state.file_header_lnums) do
      local hm = state.line_map[lnum]
      if hm and hm.file and get_entry_mood(vst[hm.file]) ~= "reviewed"
          and not viewed_state.is_snoozed(hm.file) then
        vim.api.nvim_win_set_cursor(0, { lnum, 0 })
        return
      end
    end
    ui.notify("all files reviewed ✦", vim.log.levels.INFO)
  end
end

-- Backwards-compat name used in batch_mark_directory
local mark_viewed_at_cursor = mark_reviewed_at_cursor

local function mark_unviewed_at_cursor()
  local meta, lnum = meta_at_cursor()
  if not meta or not meta.file then return end
  queue_cursor_restore(meta, lnum, 0)
  viewed_state.mark_unviewed(meta.file)
  M.refresh()
end

local function snooze_file_at_cursor()
  local meta, lnum = meta_at_cursor()
  if not meta or not meta.file then
    ui.notify("not on a file line", vim.log.levels.WARN)
    return
  end

  local file = meta.file
  queue_cursor_restore(meta, lnum, 0)
  if viewed_state.is_snoozed(file) then
    viewed_state.unsnooze(file)
    ui.notify("un-snoozed " .. file, vim.log.levels.INFO)
  else
    viewed_state.snooze(file)

    -- Brief animation
    if config.get().pr_view.micro_rewards then
      local n = ensure_ns()
      local header_lnum = nil
      for _, lnum in ipairs(state.file_header_lnums) do
        if state.line_map[lnum] and state.line_map[lnum].file == file then
          header_lnum = lnum
          break
        end
      end
      if header_lnum then
        vim.api.nvim_buf_set_extmark(state.buf, n, header_lnum - 1, 0, {
          virt_text     = { { "  ⏸ snoozed", "LocoMoodSnoozed" } },
          virt_text_pos = "eol",
        })
      end
      vim.defer_fn(function() M.refresh() end, 350)
    else
      M.refresh()
    end
    ui.notify("snoozed " .. file .. " — skipped in rhythm", vim.log.levels.INFO)
  end
end

local function jump_next_unreviewed()
  local vst = viewed_state.load()
  for _, lnum in ipairs(state.file_header_lnums) do
    local hm = state.line_map[lnum]
    if hm and hm.file then
      local mood = get_entry_mood(vst[hm.file])
      if mood ~= "reviewed" and not viewed_state.is_snoozed(hm.file) then
        local win = get_win()
        if win then vim.api.nvim_win_set_cursor(win, { lnum, 0 }) end
        return
      end
    end
  end
  ui.notify("no unreviewed files remaining", vim.log.levels.INFO)
end

-- ── Comment actions ───────────────────────────────────────────────────────────

local function add_comment_at_cursor()
  local meta, lnum = meta_at_cursor()
  if not meta or not meta.file then
    ui.notify("place cursor on a diff line to comment", vim.log.levels.WARN)
    return
  end

  local line, line_ref
  if meta.type == "remove" and meta.old_line then
    line = meta.old_line; line_ref = "old"
  elseif (meta.type == "add" or meta.type == "context") and meta.new_line then
    line = meta.new_line; line_ref = "new"
  else
    ui.notify("place cursor on an added, context, or removed line to comment", vim.log.levels.WARN)
    return
  end

  local win = get_win()
  if win then
    local cur = vim.api.nvim_win_get_cursor(win)
    queue_cursor_restore(meta, lnum or cur[1], cur[2] or 0)
  end
  require("locoreview.commands").add_at(meta.file, line, nil, line_ref)
end

local function add_quick_comment_at_cursor()
  local meta, lnum = meta_at_cursor()
  if not meta or not meta.file then
    ui.notify("place cursor on a diff line to comment", vim.log.levels.WARN)
    return
  end

  local line, line_ref
  if meta.type == "remove" and meta.old_line then
    line = meta.old_line; line_ref = "old"
  elseif (meta.type == "add" or meta.type == "context") and meta.new_line then
    line = meta.new_line; line_ref = "new"
  else
    ui.notify("place cursor on an added, context, or removed line to comment", vim.log.levels.WARN)
    return
  end

  local win = get_win()
  if win then
    local cur = vim.api.nvim_win_get_cursor(win)
    queue_cursor_restore(meta, lnum or cur[1], cur[2] or 0)
  end

  vim.ui.input({ prompt = "Quick note: " }, function(text)
    if not text or text:match("^%s*$") then return end

    local items = load_review_items()
    local next_items, new_item = store.insert(items, {
      file             = meta.file,
      line             = line,
      line_ref         = line_ref,
      severity         = "low",
      status           = "open",
      issue            = text,
      requested_change = "",
    })

    if not next_items then
      ui.notify("failed to add comment", vim.log.levels.ERROR)
      return
    end

    local path = fs.review_file_path()
    if not path then ui.notify("unable to find review file", vim.log.levels.ERROR); return end

    local ok, save_err = store.save(path, next_items)
    if not ok then
      ui.notify(save_err or "failed to save review file", vim.log.levels.ERROR)
      return
    end
    M.refresh()
    ui.notify("added note " .. new_item.id, vim.log.levels.INFO)
  end)
end

local STATUS_TRANSITION_ORDER = { "fixed", "blocked", "wontfix", "open" }

local function next_status_for(current_status)
  local types_mod = require("locoreview.types")
  local transitions = types_mod.VALID_TRANSITIONS[current_status] or {}
  for _, status in ipairs(STATUS_TRANSITION_ORDER) do
    if transitions[status] then return status end
  end
  return nil
end

local function show_comment_popup()
  local meta = meta_at_cursor()
  if not meta or not meta.file then
    ui.notify("no comment here", vim.log.levels.WARN)
    return
  end

  local review_items = load_review_items()
  local comment_map  = build_comment_map(review_items)
  local fc           = comment_map[meta.file]
  local items        = nil

  if fc then
    if meta.type == "remove" and meta.old_line then
      items = fc.old and fc.old[meta.old_line]
    elseif meta.new_line then
      items = fc.new and fc.new[meta.new_line]
    end
  end

  if not items or #items == 0 then
    ui.notify("no comment here", vim.log.levels.WARN)
    return
  end

  local item = items[1]

  local lines = {
    "ID: " .. item.id,
    "Status: " .. item.status,
    "Severity: " .. item.severity,
    "",
    "Issue:",
  }
  for line in (item.issue .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  if item.requested_change and item.requested_change ~= "" then
    table.insert(lines, "")
    table.insert(lines, "Requested change:")
    for line in (item.requested_change .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, line)
    end
  end
  table.insert(lines, "")
  table.insert(lines, "[e] edit  [s] status  [d] delete  [q] close")

  local width = 0
  for _, line in ipairs(lines) do width = math.max(width, #line) end
  width = math.min(width + 4, vim.o.columns - 4)

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(float_buf, "buftype",  "nofile")
  vim.api.nvim_buf_set_option(float_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(float_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(float_buf, "modifiable", false)

  local float_win = vim.api.nvim_open_win(float_buf, true, {
    relative = "cursor",
    row = 1, col = 0,
    width  = width,
    height = #lines,
    style  = "minimal",
    border = "rounded",
  })

  local fk = { noremap = true, silent = true, buffer = float_buf }

  local function close_float()
    if vim.api.nvim_win_is_valid(float_win) then
      vim.api.nvim_win_close(float_win, true)
    end
  end

  vim.keymap.set("n", "e", function()
    local path = fs.review_file_path()
    if not path then
      ui.notify("unable to find review file", vim.log.levels.ERROR)
      return
    end
    close_float()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.fn.search("^## " .. item.id)
  end, fk)

  vim.keymap.set("n", "s", function()
    local next_status = next_status_for(item.status)
    if not next_status then
      ui.notify("no valid transition from " .. item.status, vim.log.levels.WARN)
      return
    end

    local updated, transition_err = require("locoreview.store").transition(review_items, item.id, next_status)
    if not updated then
      ui.notify(transition_err or "failed to update note status", vim.log.levels.ERROR)
      return
    end

    local path = fs.review_file_path()
    if not path then
      ui.notify("unable to find review file", vim.log.levels.ERROR)
      return
    end

    local ok, save_err = require("locoreview.store").save(path, updated)
    if not ok then
      ui.notify(save_err or "failed to save review file", vim.log.levels.ERROR)
      return
    end

    close_float()
    M.refresh()
  end, fk)

  vim.keymap.set("n", "d", function()
    vim.ui.select({ "Delete", "Cancel" }, { prompt = "Delete this note?" }, function(choice)
      if choice ~= "Delete" then return end

      local updated, delete_err = require("locoreview.store").delete(review_items, item.id)
      if not updated then
        ui.notify(delete_err or "failed to delete note", vim.log.levels.ERROR)
        return
      end

      local path = fs.review_file_path()
      if not path then
        ui.notify("unable to find review file", vim.log.levels.ERROR)
        return
      end

      local ok, save_err = require("locoreview.store").save(path, updated)
      if not ok then
        ui.notify(save_err or "failed to save review file", vim.log.levels.ERROR)
        return
      end

      close_float()
      M.refresh()
    end)
  end, fk)

  vim.keymap.set("n", "q",    close_float, fk)
  vim.keymap.set("n", "<Esc>", close_float, fk)

  local autocmd_id = vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = state.buf,
    callback = function()
      if vim.api.nvim_win_is_valid(float_win) then
        close_float()
        vim.api.nvim_del_autocmd(autocmd_id)
      end
    end,
  })
end

-- ── Batch directory mark ──────────────────────────────────────────────────────

local function batch_mark_directory()
  local meta, lnum = meta_at_cursor()
  if not meta or not meta.file then
    ui.notify("cursor not on a diff line", vim.log.levels.WARN)
    return
  end

  local dir = vim.fn.fnamemodify(meta.file, ":h")
  if dir == "." then dir = "" end

  local files_in_dir = {}
  for _, fd in ipairs(state.file_diffs) do
    local matches = (dir == "") and not string.find(fd.file, "/")
                    or vim.startswith(fd.file, dir .. "/")
    if matches then table.insert(files_in_dir, fd) end
  end

  if #files_in_dir == 0 then
    ui.notify("no files found in directory", vim.log.levels.WARN)
    return
  end

  vim.ui.select({ "Yes", "No" }, {
    prompt = "Mark " .. #files_in_dir .. " files in "
             .. (dir ~= "" and dir or "/") .. "/ as reviewed?",
  }, function(choice)
    if choice == "Yes" then
      queue_cursor_restore(meta, lnum, 0)
      for _, fd in ipairs(files_in_dir) do
        viewed_state.mark_reviewed(fd.file, fd.diff_hash)
      end
      M.refresh()
      ui.notify("marked " .. #files_in_dir .. " files reviewed", vim.log.levels.INFO)
    end
  end)
end

-- ── Timer ─────────────────────────────────────────────────────────────────────

local function start_or_manage_timer()
  if state.timer ~= nil then
    vim.ui.select({ "Cancel timer", "Keep going" }, { prompt = "Timer is running" },
      function(choice)
        if choice == "Cancel timer" then
          state.timer:stop(); state.timer:close()
          state.timer = nil; state.timer_end = nil
          M.refresh()
        end
      end)
  else
    vim.ui.input({ prompt = "Minutes: " }, function(input)
      if not input or input:match("^%s*$") then return end
      local minutes = tonumber(input)
      if not minutes or minutes <= 0 then
        ui.notify("please enter a positive number", vim.log.levels.WARN)
        return
      end
      state.timer_end = os.time() + (minutes * 60)
      state.timer = vim.loop.new_timer()
      state.timer:start(0, 1000, vim.schedule_wrap(function() M.refresh() end))
      M.refresh()
      ui.notify("timer started: " .. minutes .. " minutes", vim.log.levels.INFO)
    end)
  end
end

-- ── File / hunk actions ───────────────────────────────────────────────────────

local function file_path_at_cursor()
  local meta = meta_at_cursor()
  if not meta or not meta.file then
    ui.notify("cursor is not on a file line", vim.log.levels.WARN)
    return nil
  end
  return meta.file
end

local function absolute_path_for(file)
  local root = git.repo_root()
  if not root or root == "" then return nil end
  return root .. "/" .. file
end

local function repo_root_or_notify()
  local root = git.repo_root()
  if not root or root == "" then
    ui.notify("could not determine repository root", vim.log.levels.ERROR)
    return nil
  end
  return root
end

local function open_source_at_cursor()
  local meta = meta_at_cursor()
  if not meta or not meta.file then
    ui.notify("cursor is not on a file line", vim.log.levels.WARN)
    return
  end
  local line = meta.new_line or meta.old_line or 1
  local root = repo_root_or_notify()
  if not root then return end
  pcall(vim.cmd, "tabprevious")
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. meta.file))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end

local function open_in_split_at_cursor()
  local meta = meta_at_cursor()
  if not meta or not meta.file then
    ui.notify("cursor is not on a file line", vim.log.levels.WARN)
    return
  end
  local line = meta.new_line or meta.old_line or 1
  local root = repo_root_or_notify()
  if not root then return end
  pcall(vim.cmd, "tabprevious")
  vim.cmd("vsplit " .. vim.fn.fnameescape(root .. "/" .. meta.file))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end

local function refresh_after_worktree_change()
  M.refresh()
end

local function delete_file_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end
  local path = absolute_path_for(file)
  if not path then ui.notify("could not determine repository root", vim.log.levels.ERROR); return end

  local rc = vim.fn.delete(path)
  if rc ~= 0 then ui.notify("failed to delete " .. file, vim.log.levels.ERROR); return end
  refresh_after_worktree_change()
  ui.notify("deleted " .. file, vim.log.levels.INFO)
end

local function rename_file_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end
  local old_path = absolute_path_for(file)
  if not old_path then ui.notify("could not determine repository root", vim.log.levels.ERROR); return end
  local root = repo_root_or_notify()
  if not root then return end

  vim.ui.input({ prompt = "Rename file to: ", default = file }, function(input)
    if not input then return end
    local target = (input:gsub("^%s+", ""):gsub("%s+$", ""))
    if target == "" or target == file then return end
    if target:sub(1, 1) == "/" then
      if vim.startswith(target, root .. "/") then
        target = target:sub(#root + 2)
      else
        ui.notify("path must be inside repository", vim.log.levels.ERROR)
        return
      end
    end
    local new_path = absolute_path_for(target)
    if not new_path then ui.notify("could not determine repository root", vim.log.levels.ERROR); return end
    local dir = vim.fn.fnamemodify(new_path, ":h")
    if dir and dir ~= "" then vim.fn.mkdir(dir, "p") end
    if vim.fn.rename(old_path, new_path) ~= 0 then
      ui.notify("failed to rename " .. file, vim.log.levels.ERROR)
      return
    end
    refresh_after_worktree_change()
    ui.notify("renamed " .. file .. " → " .. target, vim.log.levels.INFO)
  end)
end

local function copy_file_path_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end
  local copied = false
  for _, reg in ipairs({ "+", "*" }) do
    local ok = pcall(vim.fn.setreg, reg, file)
    copied = copied or ok
  end
  if not copied then pcall(vim.fn.setreg, '"', file) end
  ui.notify("copied: " .. file, vim.log.levels.INFO)
end

local function view_file_diff_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end

  local cmd = { "git", "diff", "--unified=3" }
  if state.base_ref then
    table.insert(cmd, state.base_ref .. "...HEAD")
  else
    table.insert(cmd, "HEAD")
  end
  table.insert(cmd, "--")
  table.insert(cmd, file)

  local lines, err = run_system_list(cmd)
  if not lines then ui.notify("git diff failed: " .. (err or ""), vim.log.levels.ERROR); return end
  if #lines == 0 then ui.notify("no diff for " .. file, vim.log.levels.INFO); return end

  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_option(buf, "buftype",  "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "swapfile",  false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "diff")
  pcall(vim.api.nvim_buf_set_name, buf, "locoreview://file-diff/" .. file)
end

local function add_to_gitignore_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end
  local root = repo_root_or_notify()
  if not root then return end
  local f = io.open(root .. "/.gitignore", "a")
  if not f then ui.notify("failed to open .gitignore", vim.log.levels.ERROR); return end
  f:write(file .. "\n")
  f:close()
  ui.notify("added " .. file .. " to .gitignore", vim.log.levels.INFO)
end

local function remove_from_tracking_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end
  local root = repo_root_or_notify()
  if not root then return end
  vim.fn.system({ "git", "-C", root, "rm", "--cached", "--", file })
  if vim.v.shell_error ~= 0 then ui.notify("git rm --cached failed", vim.log.levels.ERROR); return end
  refresh_after_worktree_change()
  ui.notify("removed " .. file .. " from tracking", vim.log.levels.INFO)
end

local function reset_file_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end
  local root = repo_root_or_notify()
  if not root then return end
  vim.fn.system({ "git", "-C", root, "checkout", "--", file })
  if vim.v.shell_error ~= 0 then ui.notify("git checkout -- failed", vim.log.levels.ERROR); return end
  refresh_after_worktree_change()
  ui.notify("reverted " .. file, vim.log.levels.INFO)
end

local function reset_hunk_at_cursor()
  local meta = meta_at_cursor()
  if not meta or not meta.hunk_idx or not meta.file_idx then
    ui.notify("cursor is not on a hunk line", vim.log.levels.WARN)
    return
  end
  local fd   = state.file_diffs[meta.file_idx]
  local hunk = fd and fd.hunks[meta.hunk_idx]
  if not hunk then return end

  local patch_lines = { "--- a/" .. fd.old_file, "+++ b/" .. fd.file, hunk.header }
  for _, dl in ipairs(hunk.lines) do table.insert(patch_lines, dl.text) end
  local patch_text = table.concat(patch_lines, "\n") .. "\n"

  local tmpfile = vim.fn.tempname()
  local f = io.open(tmpfile, "w")
  if not f then ui.notify("failed to create temp file", vim.log.levels.ERROR); return end
  f:write(patch_text); f:close()

  local root = repo_root_or_notify()
  if not root then
    vim.fn.delete(tmpfile)
    return
  end
  vim.fn.system({ "git", "-C", root, "apply", "--reverse", tmpfile })
  vim.fn.delete(tmpfile)
  if vim.v.shell_error ~= 0 then ui.notify("revert hunk failed", vim.log.levels.ERROR); return end

  refresh_after_worktree_change()
  ui.notify("reverted hunk in " .. fd.file, vim.log.levels.INFO)
end

local function stage_file_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end
  local root = repo_root_or_notify()
  if not root then return end
  vim.fn.system({ "git", "-C", root, "add", "--", file })
  if vim.v.shell_error ~= 0 then ui.notify("git add failed", vim.log.levels.ERROR); return end
  refresh_after_worktree_change()
  ui.notify("staged " .. file, vim.log.levels.INFO)
end

local function stage_hunk_at_cursor()
  local meta = meta_at_cursor()
  if not meta or not meta.hunk_idx or not meta.file_idx then
    ui.notify("cursor is not on a hunk line", vim.log.levels.WARN)
    return
  end
  local fd   = state.file_diffs[meta.file_idx]
  local hunk = fd and fd.hunks[meta.hunk_idx]
  if not hunk then return end

  local patch_lines = { "--- a/" .. fd.old_file, "+++ b/" .. fd.file, hunk.header }
  for _, dl in ipairs(hunk.lines) do table.insert(patch_lines, dl.text) end
  local patch_text = table.concat(patch_lines, "\n") .. "\n"

  local tmpfile = vim.fn.tempname()
  local f = io.open(tmpfile, "w")
  if not f then ui.notify("failed to create temp file", vim.log.levels.ERROR); return end
  f:write(patch_text); f:close()

  local root = repo_root_or_notify()
  if not root then
    vim.fn.delete(tmpfile)
    return
  end
  vim.fn.system({ "git", "-C", root, "apply", "--cached", tmpfile })
  vim.fn.delete(tmpfile)
  if vim.v.shell_error ~= 0 then ui.notify("git apply --cached failed", vim.log.levels.ERROR); return end

  refresh_after_worktree_change()
  ui.notify("staged hunk in " .. fd.file, vim.log.levels.INFO)
end

local function open_related_test_file()
  local file = file_path_at_cursor()
  if not file then return end
  local root = repo_root_or_notify()
  if not root then return end
  local base = vim.fn.fnamemodify(file, ":t:r")
  local ext  = vim.fn.fnamemodify(file, ":e")
  local dir  = vim.fn.fnamemodify(file, ":h")

  local candidates = {
    dir .. "/" .. base .. "_test." .. ext,
    dir .. "/" .. base .. ".test." .. ext,
    dir .. "/" .. base .. "_spec." .. ext,
    dir .. "/" .. base .. ".spec." .. ext,
    "spec/" .. base .. "_spec." .. ext,
    "test/" .. base .. "_test." .. ext,
    "tests/" .. base .. "_test." .. ext,
    "__tests__/" .. base .. ".test." .. ext,
  }

  for _, candidate in ipairs(candidates) do
    if vim.fn.filereadable(root .. "/" .. candidate) == 1 then
      pcall(vim.cmd, "tabprevious")
      vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. candidate))
      return
    end
  end
  ui.notify("no related test file found for " .. file, vim.log.levels.WARN)
end

local function open_file_actions_menu()
  local meta = meta_at_cursor()
  if not meta or not meta.file then return end

  -- Two-layer action system: primary flow actions, then maintenance
  local actions = {
    -- Review flow
    { label = "Mark reviewed",                       run = mark_reviewed_at_cursor },
    { label = "Snooze / un-snooze file",             run = snooze_file_at_cursor },
    { label = "Jump to next unreviewed",             run = jump_next_unreviewed },
    { label = "Stage file  (git add)",               run = stage_file_at_cursor },
    { label = "Open in editor",                      run = open_source_at_cursor },
    { label = "Open in split",                       run = open_in_split_at_cursor },
    { label = "Copy file path",                      run = copy_file_path_at_cursor },
    { label = "Open related test file",              run = open_related_test_file },
    { label = "View file diff (new tab)",            run = view_file_diff_at_cursor },
    { label = "── maintenance ──────────────────",   run = nil },
    { label = "Rename file",                         run = rename_file_at_cursor },
    { label = "Revert file  (git checkout --)",      run = reset_file_at_cursor },
    { label = "Add to .gitignore",                   run = add_to_gitignore_at_cursor },
    { label = "Remove from tracking  (git rm)",      run = remove_from_tracking_at_cursor },
    { label = "Delete file",                         run = delete_file_at_cursor },
  }

  if meta.hunk_idx then
    table.insert(actions, 5,
      { label = "Stage hunk  (git apply --cached)",  run = stage_hunk_at_cursor })
    table.insert(actions, 6,
      { label = "Revert hunk  (git apply --reverse)", run = reset_hunk_at_cursor })
  end

  vim.ui.select(actions, {
    prompt      = "Actions: " .. meta.file,
    format_item = function(item) return item.label end,
  }, function(choice)
    if choice and choice.run then choice.run() end
  end)
end

local function remove_resolved_comments()
  local path = fs.review_file_path()
  if not path then ui.notify("unable to resolve review file path", vim.log.levels.ERROR); return end

  local items, err = store.load(path)
  if not items then ui.notify(err or "unable to load review notes", vim.log.levels.ERROR); return end

  local next_items, removed = store.delete_by_statuses(items, { "fixed", "wontfix" })
  if removed == 0 then ui.notify("no resolved notes to remove", vim.log.levels.INFO); return end

  local ok, save_err = store.save(path, next_items)
  if not ok then ui.notify(save_err or "failed to save review file", vim.log.levels.ERROR); return end

  M.refresh()
  ui.notify("removed " .. removed .. " resolved notes", vim.log.levels.INFO)
end

-- ── Keymaps ───────────────────────────────────────────────────────────────────

local function attach_keymaps(buf)
  local opts = { noremap = true, silent = true, buffer = buf }
  local function bmap(lhs, fn) vim.keymap.set("n", lhs, fn, opts) end

  bmap("v",           mark_reviewed_at_cursor)
  bmap("V",           mark_unviewed_at_cursor)
  bmap("s",           snooze_file_at_cursor)
  bmap("<leader>v",   batch_mark_directory)
  bmap("<leader>T",   start_or_manage_timer)
  bmap("<leader>F",   cycle_rhythm)
  bmap("<CR>", function()
    local _, lnum = meta_at_cursor()
    toggle_fold_at(lnum)
  end)
  bmap("]f",  function() navigate_files(1)  end)
  bmap("[f",  function() navigate_files(-1) end)
  bmap("<leader>f", open_file_picker)
  bmap("]c",  function() navigate_hunks(1)  end)
  bmap("[c",  function() navigate_hunks(-1) end)
  bmap("zC",  function()
    local lnum = hunk_header_lnum_at_cursor()
    if lnum then collapse_hunk_context(lnum) end
  end)
  bmap("zO",  function()
    local lnum = hunk_header_lnum_at_cursor()
    if lnum then expand_hunk_context(lnum) end
  end)
  bmap("zCA", function()
    local cl = vim.api.nvim_win_get_cursor(0)[1]
    local fi = state.line_map[cl] and state.line_map[cl].file_idx
    if fi then
      for _, hl in ipairs(state.hunk_header_lnums) do
        if state.line_map[hl] and state.line_map[hl].file_idx == fi then
          collapse_hunk_context(hl)
        end
      end
    end
  end)
  bmap("zOA", function()
    local cl = vim.api.nvim_win_get_cursor(0)[1]
    local fi = state.line_map[cl] and state.line_map[cl].file_idx
    if fi then
      for _, hl in ipairs(state.hunk_header_lnums) do
        if state.line_map[hl] and state.line_map[hl].file_idx == fi then
          expand_hunk_context(hl)
        end
      end
    end
  end)
  bmap("c",          add_comment_at_cursor)
  bmap("C",          add_quick_comment_at_cursor)
  bmap("K",          show_comment_popup)
  bmap("d",          open_file_actions_menu)
  bmap("<leader>a",  open_file_actions_menu)
  bmap("<leader>R",  remove_resolved_comments)
  bmap("go",         open_source_at_cursor)
  bmap("R",          function() M.refresh() end)
  bmap("q",          function() M.close()   end)
  bmap("?",          function() M.show_help() end)
end

-- ── Core render / open logic ──────────────────────────────────────────────────

local function render_empty_view(desc)
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end

  state.file_diffs        = {}
  state.line_map          = {}
  state.fold_ranges       = {}
  state.file_header_lnums = {}
  state.hunk_header_lnums = {}
  state.saved_cursor      = nil
  state.saved_anchor      = nil
  state.pending_cursor    = nil
  state.pending_anchor    = nil
  state.active_file       = nil
  state.active_hunk_lnum  = nil
  state.hunk_ctx_marks    = {}

  local buf = state.buf

  local namespaces = {
    ns,
    state.hunk_ctx_ns,
    state.heat_ns,
    state.hunk_spot_ns,
    state.dim_ns,
    state.tint_ns,
  }
  for _, n in ipairs(namespaces) do
    if n then
      vim.api.nvim_buf_clear_namespace(buf, n, 0, -1)
    end
  end

  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  no " .. desc })
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  local win = get_win()
  if win then
    vim.api.nvim_win_call(win, function()
      vim.cmd("setlocal foldmethod=manual")
      vim.cmd("setlocal foldlevel=99")
      vim.cmd("normal! zE")
    end)
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  end

  update_sticky_header()
  update_hint_bar(nil)
end

local function do_render(file_diffs, review_items, vst)
  -- Clear previous hunk context
  if state.hunk_ctx_ns then
    vim.api.nvim_buf_clear_namespace(state.buf, state.hunk_ctx_ns, 0, -1)
  end
  state.hunk_ctx_marks = {}

  local comment_map = build_comment_map(review_items)
  local lm, fr, fhl, hhl = render(file_diffs, review_items, vst)
  state.line_map          = lm
  state.fold_ranges       = fr
  state.file_header_lnums = fhl
  state.hunk_header_lnums = hhl

  apply_highlights(lm)
  apply_comment_badges(lm, comment_map)
  apply_heat_map(comment_map)
  apply_rhythm_dims()
  update_sticky_header()

  -- Re-apply active-file tint and hunk spotlight after render
  if state.active_file then
    apply_active_file_tint(state.active_file)
  end
  if state.active_hunk_lnum then
    -- Re-find hunk header lnum by scanning for same file/hunk indices
    -- (lnums shift after re-render, so we look up by file+hunk)
    local target_file = state.line_map[state.active_hunk_lnum] and
                        state.line_map[state.active_hunk_lnum].file
    local target_hunk = state.line_map[state.active_hunk_lnum] and
                        state.line_map[state.active_hunk_lnum].hunk_idx
    if target_file and target_hunk then
      for _, hl in ipairs(state.hunk_header_lnums) do
        local hm = state.line_map[hl]
        if hm and hm.file == target_file and hm.hunk_idx == target_hunk then
          state.active_hunk_lnum = hl
          apply_hunk_spotlight(hl)
          break
        end
      end
    end
  end
end

local function sort_file_diffs(file_diffs, vst)
  local indexed = {}
  for i, fd in ipairs(file_diffs) do indexed[i] = { fd, i } end

  table.sort(indexed, function(a, b)
    local va = get_entry_mood(vst[a[1].file]) == "reviewed"
    local vb = get_entry_mood(vst[b[1].file]) == "reviewed"
    if va ~= vb then return va end   -- reviewed files first (true < false)
    return a[2] < b[2]
  end)

  local sorted = {}
  for _, pair in ipairs(indexed) do table.insert(sorted, pair[1]) end
  return sorted
end

local function do_open_or_refresh(base_ref)
  setup_hl()
  state.base_ref = base_ref

  local file_diffs, err = git_diff.parse(base_ref)
  if not file_diffs then
    ui.notify("ReviewPR: " .. (err or "git diff failed"), vim.log.levels.ERROR)
    return
  end
  local desc = base_ref and ("relative to " .. base_ref) or "uncommitted changes"
  if #file_diffs == 0 then
    render_empty_view(desc)
    ui.notify("no " .. desc, vim.log.levels.INFO)
    return
  end

  local review_items = load_review_items()
  local vst          = viewed_state.sync(file_diffs)
  file_diffs         = sort_file_diffs(file_diffs, vst)
  state.file_diffs   = file_diffs

  local is_new_buf = not state.buf or not vim.api.nvim_buf_is_valid(state.buf)
  if is_new_buf then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, "buftype",   "nofile")
    vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(buf, "swapfile",  false)
    pcall(vim.api.nvim_buf_set_name, buf, "locoreview://pr-review")
    state.buf          = buf
    state.session_start = os.time()

    vim.api.nvim_create_autocmd("BufDelete", {
      buffer = state.buf,
      once   = true,
      callback = function()
        if state.timer then state.timer:stop(); state.timer:close(); state.timer = nil end
        if state._ip_timer then state._ip_timer:stop(); state._ip_timer:close(); state._ip_timer = nil end
        if state.sticky_autocmd then vim.api.nvim_del_autocmd(state.sticky_autocmd) end
        if state.hint_autocmd   then vim.api.nvim_del_autocmd(state.hint_autocmd)   end
        if state.sticky_win and vim.api.nvim_win_is_valid(state.sticky_win) then
          vim.api.nvim_win_close(state.sticky_win, true)
        end
        if state.hint_win and vim.api.nvim_win_is_valid(state.hint_win) then
          vim.api.nvim_win_close(state.hint_win, true)
        end
        state.buf = nil; state.tabpage = nil
        state.line_map = {}; state.fold_ranges = {}
        state.file_header_lnums = {}; state.hunk_header_lnums = {}
        state.saved_cursor = nil; state.saved_anchor = nil
        state.pending_cursor = nil; state.pending_anchor = nil
        state.timer_end = nil
        state.sticky_win = nil; state.sticky_buf = nil; state.sticky_autocmd = nil
        state.hint_win = nil; state.hint_buf = nil; state.hint_autocmd = nil
      end,
    })
  end

  if not is_new_buf then
    local win = get_win()
    if state.pending_anchor then
      state.saved_anchor = state.pending_anchor
    elseif win then
      state.saved_anchor = capture_cursor_anchor_from_win(win)
    elseif state.pending_cursor and state.pending_cursor[1] then
      state.saved_anchor = {
        lnum = state.pending_cursor[1],
        col  = state.pending_cursor[2] or 0,
      }
    else
      state.saved_anchor = nil
    end
    if state.saved_anchor and state.saved_anchor.lnum then
      state.saved_cursor = { state.saved_anchor.lnum, state.saved_anchor.col or 0 }
    else
      state.saved_cursor = nil
    end
    state.pending_anchor = nil
    state.pending_cursor = nil
  end

  do_render(file_diffs, review_items, vst)

  if not is_alive() then
    vim.cmd("tabnew")
    state.tabpage = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_win_set_buf(0, state.buf)
    if is_new_buf then attach_keymaps(state.buf) end
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_option(win, "number",         false)
    vim.api.nvim_win_set_option(win, "relativenumber", false)
    vim.api.nvim_win_set_option(win, "signcolumn",     "no")
    vim.api.nvim_win_set_option(win, "wrap",           false)
  else
    vim.api.nvim_set_current_tabpage(state.tabpage)
  end

  local win = get_win()
  if win then
    setup_folds(win, state.fold_ranges)
    create_sticky_header(win)
    update_sticky_header()
    create_hint_bar(win)

    if not is_new_buf then
      local target = resolve_anchor_to_cursor(state.saved_anchor) or state.saved_cursor
      if target then
        local clamped = clamp_cursor_target(target)
        if clamped then pcall(vim.api.nvim_win_set_cursor, win, clamped) end
      end
    end

    -- CursorMoved autocmd: hunk spotlight, hint bar, in_progress tracking
    if is_new_buf and not state.hint_autocmd then
      state.hint_autocmd = vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = state.buf,
        callback = function()
          local lnum = vim.api.nvim_win_get_cursor(0)[1]
          local meta = state.line_map[lnum]
          local new_file = meta and meta.file

          -- Hunk spotlight (only update when hunk changes)
          local new_hunk_lnum = hunk_header_lnum_at_lnum(lnum)
          if new_hunk_lnum ~= state.active_hunk_lnum then
            state.active_hunk_lnum = new_hunk_lnum
            vim.schedule(function()
              if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
                apply_hunk_spotlight(state.active_hunk_lnum)
              end
            end)
          end

          -- Active file tint (only update when file changes)
          if new_file ~= state.active_file then
            state.active_file = new_file
            vim.schedule(function()
              if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
                apply_active_file_tint(state.active_file)
              end
            end)

            -- Mark in_progress (debounced)
            if new_file then
              if state._ip_timer then
                state._ip_timer:stop(); state._ip_timer:close(); state._ip_timer = nil
              end
              state._ip_timer = vim.loop.new_timer()
              state._ip_timer:start(600, 0, vim.schedule_wrap(function()
                viewed_state.mark_in_progress(new_file)
                state._ip_timer = nil
              end))
            end
          end

          -- Hint bar
          vim.schedule(function()
            update_hint_bar(meta)
          end)
        end,
      })
    end
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.open(base_ref)
  if base_ref ~= nil then
    do_open_or_refresh(base_ref)
    return
  end

  local cfg      = config.get()
  local auto_base = git.base_branch(cfg)

  local choices = {
    { label = "Uncommitted changes  (git diff HEAD)",   ref = false },
    { label = "vs " .. auto_base .. "  [PR-style]",     ref = auto_base },
    { label = "Custom ref…",                             ref = "custom" },
  }

  vim.ui.select(choices, {
    prompt      = "ReviewPR: diff against",
    format_item = function(c) return c.label end,
  }, function(choice)
    if not choice then return end
    if choice.ref == "custom" then
      ui.prompt_git_ref(auto_base, function(ref)
        if ref then
          do_open_or_refresh(ref ~= "" and ref or nil)
        end
      end)
    else
      do_open_or_refresh(choice.ref ~= false and choice.ref or nil)
    end
  end)
end

function M.refresh()
  do_open_or_refresh(state.base_ref)
  if is_alive() then
    ui.notify("refreshed", vim.log.levels.INFO)
  end
end

function M.close()
  if state.timer then
    state.timer:stop(); state.timer:close()
    state.timer = nil; state.timer_end = nil
  end
  if state._ip_timer then
    state._ip_timer:stop(); state._ip_timer:close(); state._ip_timer = nil
  end
  if state.sticky_autocmd then
    vim.api.nvim_del_autocmd(state.sticky_autocmd); state.sticky_autocmd = nil
  end
  if state.hint_autocmd then
    vim.api.nvim_del_autocmd(state.hint_autocmd); state.hint_autocmd = nil
  end
  if state.sticky_win and vim.api.nvim_win_is_valid(state.sticky_win) then
    vim.api.nvim_win_close(state.sticky_win, true); state.sticky_win = nil
  end
  if state.hint_win and vim.api.nvim_win_is_valid(state.hint_win) then
    vim.api.nvim_win_close(state.hint_win, true); state.hint_win = nil
  end
  state.sticky_buf = nil; state.hint_buf = nil

  -- Restore UI chrome if rhythm mode had hidden it
  if state.saved_ui.laststatus  ~= nil then vim.o.laststatus  = state.saved_ui.laststatus  end
  if state.saved_ui.showtabline ~= nil then vim.o.showtabline = state.saved_ui.showtabline end
  state.rhythm_mode  = "overview"
  state.rhythm_queue = {}
  state.saved_ui     = {}
  clear_rhythm_advance_map(state.buf)

  if state.hunk_ctx_ns and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_clear_namespace, state.buf, state.hunk_ctx_ns, 0, -1)
  end
  state.hunk_ctx_marks = {}

  if is_alive() then
    pcall(function()
      vim.api.nvim_set_current_tabpage(state.tabpage)
      vim.cmd("tabclose")
    end)
  end
  state.tabpage           = nil
  state.buf               = nil
  state.line_map          = {}
  state.fold_ranges       = {}
  state.file_header_lnums = {}
  state.hunk_header_lnums = {}
  state.active_file       = nil
  state.active_hunk_lnum  = nil
end

function M.show_help()
  local advance_lhs = rhythm_advance_lhs()
  local lines = {
    "locoreview PR view",
    "  v / V         mark file reviewed / un-reviewed",
    "  s             snooze file (skip in rhythm; toggle to un-snooze)",
    "  <leader>v     mark all files in directory as reviewed",
    "  <CR>          toggle file fold",
    "  ]f / [f       next / previous file",
    "  ]c / [c       next / previous hunk",
    "  c             add review comment at cursor line",
    "  C             quick note (one prompt, low severity)",
    "  K             show full comment popup",
    "  d / <leader>a actions menu (review + maintenance)",
    "  <leader>R     remove resolved notes (fixed + wontfix)",
    "  go            open source file at cursor",
    "  <leader>T     start / cancel timed review session",
    "  <leader>F     cycle rhythm mode  (overview → focus → sweep)",
    string.format("  %s       advance to next file  (focus / sweep modes)", advance_lhs),
    "  zC / zO       collapse / expand hunk context",
    "  zCA / zOA     collapse / expand all hunks in file",
    "  <leader>f     jump-to-file picker",
    "  R             refresh",
    "  q             close",
    "  ?             this help",
    "",
    "Rhythm modes:",
    "  overview  — all files visible, no dimming",
    string.format("  focus     — one file at a time; others dimmed; %s advances", advance_lhs),
    string.format("  sweep     — reviewed files dimmed; %s cycles pending files", advance_lhs),
    "",
    "File moods:",
    "  ○ untouched   ◑ in progress   ● reviewed",
    "  ⏸ snoozed     ⊗ blocked        ⚠ risky   ⌁ generated",
  }
  ui.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

function M.is_open()
  return is_alive()
end

return M
