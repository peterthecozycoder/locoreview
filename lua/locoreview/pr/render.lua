-- pr/render.lua
-- Buffer content generation for the PR view.
--
-- The public entry point is M.render(file_diffs, review_items, vst, buf) which
-- fills `buf` with lines and returns the ancillary structures that the rest of
-- the PR view uses to apply highlights and handle keymaps:
--
--   line_map          table<lnum, meta>  – per-line metadata
--   fold_ranges       []FoldRange        – ranges to fold after render
--   file_header_lnums []number           – lnums of file-header lines
--   hunk_header_lnums []number           – lnums of hunk-header lines
--
-- Everything in this module is a pure data transformation.  It touches the vim
-- buffer only via nvim_buf_set_lines.

local M = {}

local config       = require("locoreview.config")
local viewed_state = require("locoreview.viewed_state")
local state_mod    = require("locoreview.pr.state")
local state        = state_mod.state

-- ── Mood tables ───────────────────────────────────────────────────────────────

M.MOOD_DOT = {
  untouched   = "○",
  in_progress = "◑",
  reviewed    = "●",
  snoozed     = "⏸",
  blocked     = "⊗",
  generated   = "⌁",
  risky       = "⚠",
}

M.MOOD_HL = {
  untouched   = "LocoMoodUntouched",
  in_progress = "LocoMoodInProgress",
  reviewed    = "LocoMoodReviewed",
  snoozed     = "LocoMoodSnoozed",
  blocked     = "LocoMoodBlocked",
  generated   = "LocoMoodGenerated",
  risky       = "LocoMoodRisky",
}

-- ── Comment helpers ───────────────────────────────────────────────────────────

function M.build_comment_map(items)
  local map = {}
  for _, item in ipairs(items or {}) do
    map[item.file] = map[item.file] or { new = {}, old = {} }
    local bucket = (item.line_ref == "old") and map[item.file].old or map[item.file].new
    bucket[item.line] = bucket[item.line] or {}
    table.insert(bucket[item.line], item)
  end
  return map
end

function M.comment_count_for(file, comment_map)
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

-- ── Mood helpers ──────────────────────────────────────────────────────────────

local function get_entry_mood(entry)
  if not entry then return "untouched" end
  return entry.mood or (entry.viewed and "reviewed" or "untouched")
end

-- Expose for use by other pr/ modules.
M.get_entry_mood = get_entry_mood

-- Effective mood: session > generated > computed (blocked/risky) > persisted
function M.get_file_effective_mood(file, vst, comment_map, fd)
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
        and M.comment_count_for(file, comment_map) == 0 then
      return "risky"
    end
  end

  return mood
end

-- ── Header rendering ──────────────────────────────────────────────────────────

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
  if progress_pct >= 95  then return "quiet pass" end
  if progress_pct >= 84  then return "tying loose ends" end
  if progress_pct >= 72  then return "lamplight review" end
  if progress_pct >= 60  then return "checking the edges" end
  if progress_pct >= 48  then return "following the thread" end
  if progress_pct >= 34  then return "deep in the diff" end
  if progress_pct >= 20  then return "steady pace" end
  if progress_pct >= 10  then return "mapping the terrain" end
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
  local total    = #HEADER_PHASES
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

local function current_branch_name()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--abbrev-ref", "HEAD" })
  if vim.v.shell_error == 0 and out and out[1] and out[1] ~= "" then
    return out[1]
  end
  return state.base_ref or "HEAD"
end

local function build_header_model(file_diffs, review_items, file_moods)
  local reviewed_count, snoozed_count = 0, 0
  for _, fd in ipairs(file_diffs) do
    if file_moods[fd.file] == "reviewed" then reviewed_count = reviewed_count + 1 end
    if viewed_state.is_snoozed(fd.file)  then snoozed_count  = snoozed_count  + 1 end
  end

  local total   = #file_diffs
  local pct     = total > 0 and math.floor(reviewed_count / total * 100) or 0
  local bar_len = 22
  local filled  = total > 0 and math.floor(reviewed_count / total * bar_len) or 0
  local progress_bar = "[" .. string.rep("=", filled) .. string.rep("-", bar_len - filled) .. "]"

  local mood    = select_header_mood(pct)
  local mascot  = select_header_mascot(pct, mood)
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
  if timer_text then table.insert(mood_parts, timer_text) end

  local branch = current_branch_name()
  local target = state.base_ref or "working tree"

  return {
    mascot        = mascot,
    title_line    = string.format("PR Review  %s -> %s", branch, target),
    mood_line     = table.concat(mood_parts, "  ·  "),
    progress_bar  = progress_bar,
    progress_line = string.format(
      "progress %s  %d%%  (%d/%d reviewed)", progress_bar, pct, reviewed_count, total),
    checklist_line = "phases  " .. render_phase_checklist(pct),
    quiet_line    = "quiet  " .. select_quiet_phrase(reviewed_count, total),
  }
end

-- ── Display utilities ─────────────────────────────────────────────────────────

local function display_width(text)
  if vim.fn and type(vim.fn.strdisplaywidth) == "function" then
    local ok, width = pcall(vim.fn.strdisplaywidth, text)
    if ok and type(width) == "number" then return width end
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
      type        = content_types[i],
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

local function make_section_header(label, count)
  return string.format("  %s (%d)", label, count)
end

-- File header text + position metadata for inline highlights.
-- Returns: text, meta_positions
local function make_file_header(fd, mood)
  local dot  = M.MOOD_DOT[mood] or "○"
  local dir  = vim.fn.fnamemodify(fd.file, ":h")
  local name = vim.fn.fnamemodify(fd.file, ":t")

  local path_display, dir_byte_len
  if dir == "." then
    path_display = name
    dir_byte_len = 0
  else
    path_display = dir .. "/" .. name
    dir_byte_len = #dir + 1
  end

  local status = fd.status or "modified"

  local text = "  " .. dot .. "  " .. path_display .. "   " .. status

  local path_col   = 7
  local name_col   = path_col + dir_byte_len
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

-- ── Sort ──────────────────────────────────────────────────────────────────────

function M.sort_file_diffs(file_diffs, vst)
  local indexed = {}
  for i, fd in ipairs(file_diffs) do indexed[i] = { fd, i } end

  table.sort(indexed, function(a, b)
    local va = get_entry_mood(vst[a[1].file]) == "reviewed"
    local vb = get_entry_mood(vst[b[1].file]) == "reviewed"
    if va ~= vb then return va end
    return a[2] < b[2]
  end)

  local sorted = {}
  for _, pair in ipairs(indexed) do table.insert(sorted, pair[1]) end
  return sorted
end

-- ── Main render ───────────────────────────────────────────────────────────────

local SEP = "  " .. string.rep(".", 24)

-- Fill `buf` with the full PR diff document.
-- Returns: line_map, fold_ranges, file_header_lnums, hunk_header_lnums
function M.render(file_diffs, review_items, vst, buf)
  local lines             = {}
  local line_map          = {}
  local fold_ranges       = {}
  local file_header_lnums = {}
  local hunk_header_lnums = {}

  local comment_map = M.build_comment_map(review_items)

  -- Pre-compute effective mood for every file
  local file_moods = {}
  for _, fd in ipairs(file_diffs) do
    file_moods[fd.file] = M.get_file_effective_mood(fd.file, vst, comment_map, fd)
  end

  local header_model = build_header_model(file_diffs, review_items, file_moods)
  local header_lines, header_meta = render_header_block(header_model)
  for i, line in ipairs(header_lines) do
    table.insert(lines, line)
    line_map[#lines] = header_meta[i]
  end
  table.insert(lines, ""); line_map[#lines] = { type = "gap" }
  table.insert(lines, ""); line_map[#lines] = { type = "gap" }

  -- Split into reviewed vs to-review
  local first_unreviewed_idx = nil
  for fi, fd in ipairs(file_diffs) do
    if file_moods[fd.file] ~= "reviewed" then
      first_unreviewed_idx = fi
      break
    end
  end
  local reviewed_count = first_unreviewed_idx and (first_unreviewed_idx - 1) or #file_diffs

  -- Append one file section (hunks + separator) to the accumulated lines.
  local function append_file_section(fi, fd, is_reviewed)
    local mood      = file_moods[fd.file]
    local text, hdr_pos = make_file_header(fd, mood)
    table.insert(lines, text)
    local header_lnum = #lines
    line_map[header_lnum] = vim.tbl_extend("force", hdr_pos, {
      file      = fd.file,
      type      = "file_header",
      file_idx  = fi,
      mood      = mood,
      is_viewed = is_reviewed,
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

    table.insert(lines, "")
    line_map[#lines] = { type = "gap" }
  end

  -- ── REVIEWED section ────────────────────────────────────────────────────────
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

  -- ── TO REVIEW section ───────────────────────────────────────────────────────
  if first_unreviewed_idx then
    local unreviewed_count = #file_diffs - first_unreviewed_idx + 1
    table.insert(lines, make_section_header("to review", unreviewed_count))
    line_map[#lines] = { type = "section_header", section = "unviewed" }

    for fi, fd in ipairs(file_diffs) do
      if fi < first_unreviewed_idx then goto continue end
      append_file_section(fi, fd, false)
      ::continue::
    end

    -- "Done for now" banner
    local all_handled = true
    for _, fd in ipairs(file_diffs) do
      local m = file_moods[fd.file]
      if m ~= "reviewed" and m ~= "snoozed" and m ~= "generated" then
        all_handled = false; break
      end
    end
    if all_handled and #file_diffs > 0 then
      local snoozed_n = 0
      for _, fd in ipairs(file_diffs) do
        if viewed_state.is_snoozed(fd.file) then snoozed_n = snoozed_n + 1 end
      end
      local done_text = "  ✦  all caught up — " .. reviewed_count .. " reviewed"
      if snoozed_n > 0 then done_text = done_text .. ", " .. snoozed_n .. " snoozed" end
      table.insert(lines, ""); line_map[#lines] = { type = "gap" }
      table.insert(lines, done_text); line_map[#lines] = { type = "done_summary" }
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  return line_map, fold_ranges, file_header_lnums, hunk_header_lnums
end

return M
