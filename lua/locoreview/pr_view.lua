-- pr_view.lua
-- GitHub-style single-scroll PR diff view.
--
-- Architecture:
--   One scratch buffer holds all diffs as a continuous document.
--   Each file section is wrapped in a manual fold (separator → last diff line).
--   The file header line sits ABOVE the fold so it is always visible.
--   Viewed files start with their fold collapsed.
--   Comment badges from review.md are overlaid as virtual text.
--   All actions (view, comment, open source) are buffer-local keymaps.

local M = {}

local config       = require("locoreview.config")
local fs           = require("locoreview.fs")
local git          = require("locoreview.git")
local git_diff     = require("locoreview.git_diff")
local store        = require("locoreview.store")
local ui           = require("locoreview.ui")
local viewed_state = require("locoreview.viewed_state")

-- ── Module state ────────────────────────────────────────────────────────────

local state = {
  buf              = nil,
  tabpage          = nil,
  line_map         = {},   -- 1-indexed lnum → metadata table
  fold_ranges      = {},   -- [{start, stop, file, is_viewed}]
  file_header_lnums = {},  -- 1-indexed lnums of file-header lines (sorted)
  hunk_header_lnums = {},  -- 1-indexed lnums of hunk-header lines (sorted)
  file_diffs       = {},
  base_ref         = nil,
  timer            = nil,   -- vim.loop timer handle, or nil
  timer_end        = nil,   -- os.time() when timer expires, or nil
  sticky_win       = nil,   -- window handle for the sticky header float
  sticky_buf       = nil,   -- buffer for the sticky header float
  sticky_autocmd   = nil,   -- autocmd id for WinScrolled
  focus_level      = 0,    -- 0 = off, 1 = file, 2 = hunk
  dim_ns           = nil,  -- namespace for file-level dimming
  hunk_dim_ns      = nil,  -- namespace for hunk-level dimming
  focus_queue      = {},   -- ordered list of file paths (priority queue)
  focus_file_idx   = 1,    -- current position in focus_queue
  focus_hunk_idx   = 1,    -- current hunk index within focus_queue[focus_file_idx]
  saved_ui         = {},   -- saved vim options: { laststatus, showtabline }
  hunk_ctx_ns      = nil,  -- namespace for context-collapse extmarks
  hunk_ctx_marks   = {},   -- { hunk_header_lnum → { extmark_ids... } }
  heat_ns          = nil,  -- namespace for heat map sign extmarks
}

local NS_NAME = "locoreview_pr"
local ns      = nil

local function ensure_ns()
  if not ns then
    ns = vim.api.nvim_create_namespace(NS_NAME)
  end
  return ns
end

-- ── Highlight groups ────────────────────────────────────────────────────────

local function setup_hl()
  local defs = {
    LocoFileHeader     = { link = "Title" },
    LocoFileViewed     = { link = "Comment" },
    LocoHunkHeader     = { link = "Special" },
    LocoViewed         = { link = "DiagnosticSignOk" },
    LocoUnviewed       = { link = "DiagnosticSignWarn" },
    LocoComment        = { link = "DiagnosticVirtualTextInfo" },
    LocoCommentOld     = { link = "DiagnosticVirtualTextWarn" },
    LocoDiffSep        = { link = "LineNr" },
    LocoBinaryNote     = { link = "Comment" },
    LocoSectionHeader  = { link = "Type" },
    LocoSectionDivider = { link = "VertSplit" },
    LocoProgressBar    = { link = "Statement" },
    LocoTimerWarn      = { link = "DiagnosticSignError" },
    LocoHeatLow        = { link = "DiagnosticSignWarn" },
    LocoHeatHigh       = { link = "DiagnosticSignError" },
  }
  for name, attrs in pairs(defs) do
    vim.api.nvim_set_hl(0, name, attrs)
  end
end

-- ── Fold text ───────────────────────────────────────────────────────────────

-- Global so vimscript's v:lua can reach it.
_G._locoreview_pr_foldtext = function()
  local n = vim.v.foldend - vim.v.foldstart + 1
  return "  " .. string.rep("─", 4) .. string.format(" %d lines ", n) .. string.rep("─", 50)
end

-- ── Utility functions ───────────────────────────────────────────────────────

local function load_review_items()
  local path = fs.review_file_path()
  if not path then return {} end
  local items, _ = store.load(path)
  return items or {}
end

-- ── Rendering ───────────────────────────────────────────────────────────────

local SEP = string.rep("─", 64)

-- Render the progress line showing review progress and optionally a timer.
local function render_progress_line(file_diffs, review_items, vst)
  local viewed_count = 0
  for _, fd in ipairs(file_diffs) do
    if vst[fd.file] and vst[fd.file].viewed == true then
      viewed_count = viewed_count + 1
    end
  end
  local total_count = #file_diffs
  local pct = (total_count > 0) and math.floor((viewed_count / total_count) * 100) or 0

  -- Progress bar: 12 chars, filled with ▓
  local bar_len = 12
  local filled = math.floor((viewed_count / total_count) * bar_len)
  local bar = string.rep("▓", filled) .. string.rep("░", bar_len - filled)

  -- Branch name
  local branch = state.base_ref or "HEAD"

  -- Comment count
  local comment_count = #(review_items or {})

  -- Timer info if active
  local timer_str = ""
  if state.timer_end ~= nil then
    local remaining = state.timer_end - os.time()
    if remaining > 0 then
      local mins = math.floor(remaining / 60)
      local secs = remaining % 60
      timer_str = string.format("  │  ⏱ %02d:%02d", mins, secs)
    else
      timer_str = "  │  ✦ Time's up"
    end
  end

  return string.format("  %s  │  %d/%d reviewed  %s  %d%%  │  %d comments%s",
    branch, viewed_count, total_count, bar, pct, comment_count, timer_str)
end

-- Build {file → {new = {new_line → [items]}, old = {old_line → [items]}}} for fast lookup during decoration.
local function build_comment_map(items)
  local map = {}
  for _, item in ipairs(items or {}) do
    map[item.file] = map[item.file] or { new = {}, old = {} }
    local line_ref = item.line_ref or "new"
    local bucket = (line_ref == "old") and map[item.file].old or map[item.file].new
    bucket[item.line] = bucket[item.line] or {}
    table.insert(bucket[item.line], item)
  end
  return map
end

-- Fill state.buf with all diff content and return ancillary structures.
local function render(file_diffs, review_items, vst)
  local buf = state.buf

  local lines            = {}
  local line_map         = {}
  local fold_ranges      = {}
  local file_header_lnums = {}
  local hunk_header_lnums = {}

  -- Add progress line as the first line
  local progress_line = render_progress_line(file_diffs, review_items, vst)
  table.insert(lines, progress_line)
  line_map[#lines] = { type = "progress" }

  -- Find the boundary between viewed and unviewed files
  local first_unviewed_idx = nil
  for fi, fd in ipairs(file_diffs) do
    local is_viewed = vst[fd.file] and vst[fd.file].viewed == true
    if not is_viewed then
      first_unviewed_idx = fi
      break
    end
  end

  -- Add VIEWED section header if there are viewed files
  if first_unviewed_idx and first_unviewed_idx > 1 then
    table.insert(lines, "VIEWED (" .. (first_unviewed_idx - 1) .. ")")
    line_map[#lines] = { type = "section_header" }
  end

  for fi, fd in ipairs(file_diffs) do
    local is_viewed = vst[fd.file] and vst[fd.file].viewed == true

    -- Add UNVIEWED section header at the boundary
    if first_unviewed_idx and fi == first_unviewed_idx then
      table.insert(lines, SEP)
      line_map[#lines] = { type = "section_divider" }
      table.insert(lines, "UNVIEWED (" .. (#file_diffs - first_unviewed_idx + 1) .. ")")
      line_map[#lines] = { type = "section_header" }
    end

    -- ── File header (always visible – NOT inside the fold) ─────────────────
    local badge   = is_viewed and "  ✓ viewed" or "  ● unviewed"
    local stats   = string.format("  +%d -%d", fd.stats.added, fd.stats.removed)
    local header  = string.format(" %s%s  [%s]%s", fd.file, stats, fd.status, badge)
    table.insert(lines, header)
    local header_lnum = #lines
    line_map[header_lnum] = { file = fd.file, type = "file_header",
                               file_idx = fi, is_viewed = is_viewed }
    table.insert(file_header_lnums, header_lnum)

    local fold_start = #lines + 1   -- fold begins on the separator line

    -- ── Separator ──────────────────────────────────────────────────────────
    table.insert(lines, SEP)
    line_map[#lines] = { file = fd.file, type = "separator", file_idx = fi }

    -- ── Binary placeholder ─────────────────────────────────────────────────
    if fd.status == "binary" then
      table.insert(lines, " (binary file – diff not available)")
      line_map[#lines] = { file = fd.file, type = "binary_note", file_idx = fi }

    -- ── Hunks ──────────────────────────────────────────────────────────────
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

        -- blank between hunks (not after the last one)
        if hi < #fd.hunks then
          table.insert(lines, "")
          line_map[#lines] = { file = fd.file, type = "blank", file_idx = fi }
        end
      end
    end

    -- ── Register fold range ────────────────────────────────────────────────
    local fold_stop = #lines
    if fold_start <= fold_stop then
      table.insert(fold_ranges, {
        start     = fold_start,
        stop      = fold_stop,
        file      = fd.file,
        file_idx  = fi,
        is_viewed = is_viewed,
      })
    end

    -- ── Gap between files ──────────────────────────────────────────────────
    table.insert(lines, "")
    line_map[#lines] = { type = "gap" }
  end

  -- Write buffer
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  return line_map, fold_ranges, file_header_lnums, hunk_header_lnums
end

-- Apply line-level highlight groups.
local function apply_highlights(line_map)
  local buf = state.buf
  local n   = ensure_ns()
  vim.api.nvim_buf_clear_namespace(buf, n, 0, -1)

  for lnum, meta in pairs(line_map) do
    local l0 = lnum - 1   -- 0-indexed for API calls
    if meta.type == "progress" then
      local hl = "LocoProgressBar"
      if state.timer_end and (state.timer_end - os.time()) > 0 and (state.timer_end - os.time()) <= 120 then
        hl = "LocoTimerWarn"
      end
      vim.api.nvim_buf_add_highlight(buf, n, hl, l0, 0, -1)
    elseif meta.type == "section_header" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoSectionHeader", l0, 0, -1)
    elseif meta.type == "section_divider" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoSectionDivider", l0, 0, -1)
    elseif meta.type == "file_header" then
      local hl = meta.is_viewed and "LocoFileViewed" or "LocoFileHeader"
      vim.api.nvim_buf_add_highlight(buf, n, hl, l0, 0, -1)
    elseif meta.type == "separator" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoDiffSep", l0, 0, -1)
    elseif meta.type == "hunk_header" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoHunkHeader", l0, 0, -1)
    elseif meta.type == "add" then
      vim.api.nvim_buf_add_highlight(buf, n, "DiffAdd", l0, 0, -1)
    elseif meta.type == "remove" then
      vim.api.nvim_buf_add_highlight(buf, n, "DiffDelete", l0, 0, -1)
    elseif meta.type == "binary_note" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoBinaryNote", l0, 0, -1)
    end
  end
end

-- Overlay comment badges as virtual text on relevant diff lines.
local function apply_comment_badges(line_map, comment_map)
  local buf = state.buf
  local n   = ensure_ns()

  for lnum, meta in pairs(line_map) do
    if meta.file and (meta.type == "add" or meta.type == "context") then
      if meta.new_line then
        local file_comments = comment_map[meta.file]
        local items = file_comments and file_comments.new and file_comments.new[meta.new_line]
        if items and #items > 0 then
          local badges = {}
          for _, item in ipairs(items) do
            local preview = item.issue:sub(1, 45)
            if #item.issue > 45 then preview = preview .. "…" end
            table.insert(badges, item.id .. ": " .. preview)
          end
          vim.api.nvim_buf_set_extmark(buf, n, lnum - 1, 0, {
            virt_text     = { { "  💬 " .. table.concat(badges, " | "), "LocoComment" } },
            virt_text_pos = "eol",
          })
        end
      end
    elseif meta.file and meta.type == "remove" then
      if meta.old_line then
        local file_comments = comment_map[meta.file]
        local items = file_comments and file_comments.old and file_comments.old[meta.old_line]
        if items and #items > 0 then
          local badges = {}
          for _, item in ipairs(items) do
            local preview = item.issue:sub(1, 45)
            if #item.issue > 45 then preview = preview .. "…" end
            table.insert(badges, item.id .. ": " .. preview)
          end
          vim.api.nvim_buf_set_extmark(buf, n, lnum - 1, 0, {
            virt_text     = { { "  💬 " .. table.concat(badges, " | "), "LocoCommentOld" } },
            virt_text_pos = "eol",
          })
        end
      end
    end
  end
end

-- Create manual folds in the given window and collapse viewed-file sections.
local function setup_folds(win, fold_ranges)
  vim.api.nvim_win_call(win, function()
    vim.cmd("setlocal foldmethod=manual")
    vim.cmd("setlocal foldtext=v:lua._locoreview_pr_foldtext()")
    vim.cmd("setlocal foldlevel=99")
    vim.cmd("normal! zE")   -- delete all existing folds
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

-- ── Window helpers ──────────────────────────────────────────────────────────

local function is_alive()
  return state.tabpage ~= nil
    and vim.api.nvim_tabpage_is_valid(state.tabpage)
end

local function get_win()
  if not is_alive() then return nil end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
    if vim.api.nvim_win_get_buf(win) == state.buf then
      return win
    end
  end
  return nil
end

-- ── Keymaps ─────────────────────────────────────────────────────────────────

local function meta_at_cursor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return state.line_map[lnum], lnum
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

local function navigate_files(direction)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
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
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
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

local function update_sticky_header()
  if not state.sticky_win or not vim.api.nvim_win_is_valid(state.sticky_win) then
    return
  end

  local win = get_win()
  if not win then
    return
  end

  -- Get the top visible line
  local top_visible_line = vim.api.nvim_win_call(win, function()
    return vim.fn.line("w0")
  end)

  -- Find the enclosing file header by walking file_header_lnums backwards
  local header_lnum = nil
  for i = #state.file_header_lnums, 1, -1 do
    if state.file_header_lnums[i] <= top_visible_line then
      header_lnum = state.file_header_lnums[i]
      break
    end
  end

  -- Make sticky buffer modifiable to write to it
  vim.api.nvim_buf_set_option(state.sticky_buf, "modifiable", true)

  if not header_lnum or header_lnum == top_visible_line then
    -- Hide the sticky header if no enclosing header or real header is visible
    vim.api.nvim_buf_set_lines(state.sticky_buf, 0, -1, false, {""})
  else
    -- Read the actual header text from the buffer
    local header_text = vim.api.nvim_buf_get_lines(state.buf, header_lnum - 1, header_lnum, false)[1]
    vim.api.nvim_buf_set_lines(state.sticky_buf, 0, -1, false, {header_text or ""})

    -- Apply the same highlight as the real header
    local header_meta = state.line_map[header_lnum]
    local hl = (header_meta and header_meta.is_viewed) and "LocoFileViewed" or "LocoFileHeader"
    vim.api.nvim_buf_add_highlight(state.sticky_buf, ensure_ns(), hl, 0, 0, -1)
  end

  vim.api.nvim_buf_set_option(state.sticky_buf, "modifiable", false)
end

local function create_sticky_header(win)
  if state.sticky_win and vim.api.nvim_win_is_valid(state.sticky_win) then
    return  -- Already exists
  end

  -- Create scratch buffer for the sticky header
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

  -- Get window width
  local win_width = vim.api.nvim_win_get_width(win)

  -- Open float window at top of PR view window
  local float_win = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = win,
    row = 0,
    col = 0,
    width = win_width,
    height = 1,
    focusable = false,
    style = "minimal",
    zindex = 50,
  })

  state.sticky_win = float_win
  state.sticky_buf = buf

  -- Register WinScrolled autocmd
  state.sticky_autocmd = vim.api.nvim_create_autocmd("WinScrolled", {
    callback = function()
      update_sticky_header()
    end,
  })
end

local function get_context_lnums_for_hunk(hunk_header_lnum)
  local meta = state.line_map[hunk_header_lnum]
  if not meta then return {} end
  local target_hunk_idx = meta.hunk_idx
  local target_file_idx = meta.file_idx

  local context_lnums = {}
  for lnum, line_meta in pairs(state.line_map) do
    if line_meta.hunk_idx == target_hunk_idx
        and line_meta.file_idx == target_file_idx
        and line_meta.type == "context" then
      table.insert(context_lnums, lnum)
    end
  end
  table.sort(context_lnums)
  return context_lnums
end

local function collapse_hunk_context(hunk_header_lnum)
  if state.hunk_ctx_marks[hunk_header_lnum] then
    return  -- Already collapsed
  end

  local context_lnums = get_context_lnums_for_hunk(hunk_header_lnum)
  if #context_lnums == 0 then
    return
  end

  local hunk_ctx_ns = state.hunk_ctx_ns or vim.api.nvim_create_namespace("locoreview_pr_ctx")
  state.hunk_ctx_ns = hunk_ctx_ns

  local mark_ids = {}

  -- Hide all context lines with conceal
  for _, lnum in ipairs(context_lnums) do
    local id = vim.api.nvim_buf_set_extmark(state.buf, hunk_ctx_ns, lnum - 1, 0, {
      conceal = " ",
    })
    table.insert(mark_ids, id)
  end

  -- Show virtual line after the last context line with a count
  local last_context_lnum = context_lnums[#context_lnums]
  local virtual_text = "  [· " .. #context_lnums .. " context lines ·]"
  local id = vim.api.nvim_buf_set_extmark(state.buf, hunk_ctx_ns, last_context_lnum - 1, 0, {
    virt_lines = { { virtual_text, "Comment" } },
  })
  table.insert(mark_ids, id)

  state.hunk_ctx_marks[hunk_header_lnum] = mark_ids

  -- Set conceallevel if this is the first collapse
  if not state.buf then return end
  local win = get_win()
  if win then
    vim.api.nvim_win_set_option(win, "conceallevel", 2)
  end
end

local function expand_hunk_context(hunk_header_lnum)
  local ids = state.hunk_ctx_marks[hunk_header_lnum]
  if not ids then
    return
  end

  for _, id in ipairs(ids) do
    if state.hunk_ctx_ns then
      pcall(vim.api.nvim_buf_del_extmark, state.buf, state.hunk_ctx_ns, id)
    end
  end

  state.hunk_ctx_marks[hunk_header_lnum] = nil

  -- Reset conceallevel if no more collapses
  if not next(state.hunk_ctx_marks) then
    local win = get_win()
    if win then
      vim.api.nvim_win_set_option(win, "conceallevel", 0)
    end
  end
end

local function hunk_header_lnum_at_cursor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local meta = state.line_map[lnum]
  if not meta then return nil end

  local target_hunk_idx = meta.hunk_idx
  local target_file_idx = meta.file_idx
  if not target_hunk_idx or not target_file_idx then return nil end

  -- Walk backwards to find the hunk header
  for i = #state.hunk_header_lnums, 1, -1 do
    local header_lnum = state.hunk_header_lnums[i]
    local header_meta = state.line_map[header_lnum]
    if header_meta and header_meta.hunk_idx == target_hunk_idx and header_meta.file_idx == target_file_idx then
      return header_lnum
    end
  end

  return nil
end

local function build_focus_queue()
  local queue = {}
  local vst = viewed_state.load()
  local review_items = load_review_items()
  local comment_map = build_comment_map(review_items)

  -- Separate unviewed and viewed
  local unviewed = {}
  local viewed = {}

  for _, fd in ipairs(state.file_diffs) do
    local is_viewed = vst[fd.file] and vst[fd.file].viewed == true
    local item = { file = fd.file, fd = fd, is_viewed = is_viewed }

    -- Count comments
    local comment_count = 0
    if comment_map[fd.file] then
      for _, bucket in pairs(comment_map[fd.file]) do
        for _, items in pairs(bucket) do
          comment_count = comment_count + #items
        end
      end
    end
    item.comment_count = comment_count

    if is_viewed then
      table.insert(viewed, item)
    else
      table.insert(unviewed, item)
    end
  end

  -- Sort unviewed by size (descending) then by comment count
  table.sort(unviewed, function(a, b)
    local size_a = a.fd.stats.added + a.fd.stats.removed
    local size_b = b.fd.stats.added + b.fd.stats.removed
    if size_a ~= size_b then
      return size_a > size_b
    end
    return a.comment_count > b.comment_count
  end)

  -- Sort viewed alphabetically
  table.sort(viewed, function(a, b)
    return a.file < b.file
  end)

  -- Combine: unviewed first, then viewed
  for _, item in ipairs(unviewed) do
    table.insert(queue, item.file)
  end
  for _, item in ipairs(viewed) do
    table.insert(queue, item.file)
  end

  return queue
end

local function apply_dim_layer(except_file)
  local dim_ns = state.dim_ns or vim.api.nvim_create_namespace("locoreview_pr_dim")
  state.dim_ns = dim_ns

  -- Clear namespace
  vim.api.nvim_buf_clear_namespace(state.buf, dim_ns, 0, -1)

  -- Dim all lines not in except_file
  for lnum, meta in pairs(state.line_map) do
    if meta.file and meta.file ~= except_file and meta.type ~= "section_header" and meta.type ~= "progress" then
      vim.api.nvim_buf_set_extmark(state.buf, dim_ns, lnum - 1, 0, {
        hl_group = "Comment",
        priority = 200,
      })
    end
  end
end

local function apply_hunk_dim_layer(active_hunk_lnum)
  local hunk_dim_ns = state.hunk_dim_ns or vim.api.nvim_create_namespace("locoreview_pr_hdim")
  state.hunk_dim_ns = hunk_dim_ns

  -- Clear namespace
  vim.api.nvim_buf_clear_namespace(state.buf, hunk_dim_ns, 0, -1)

  -- Get active hunk's indices
  local active_meta = state.line_map[active_hunk_lnum]
  if not active_meta then return end

  local active_hunk_idx = active_meta.hunk_idx
  local active_file_idx = active_meta.file_idx

  -- Dim all lines in same file but different hunk
  for lnum, meta in pairs(state.line_map) do
    if meta.file_idx == active_file_idx
        and meta.hunk_idx
        and meta.hunk_idx ~= active_hunk_idx
        and meta.type ~= "section_header"
        and meta.type ~= "progress" then
      vim.api.nvim_buf_set_extmark(state.buf, hunk_dim_ns, lnum - 1, 0, {
        hl_group = "Comment",
        priority = 200,
      })
    end
  end
end

local function update_focus_dim()
  if state.focus_level == 0 then return end

  local meta = meta_at_cursor()
  local current_file = meta and meta.file

  if current_file then
    apply_dim_layer(current_file)
    state.focus_file_idx = 1
    for i, f in ipairs(state.focus_queue) do
      if f == current_file then
        state.focus_file_idx = i
        break
      end
    end

    if state.focus_level == 2 then
      local hunk_lnum = hunk_header_lnum_at_cursor()
      if hunk_lnum then
        apply_hunk_dim_layer(hunk_lnum)
      end
    end
  end
end

local function cycle_focus()
  state.focus_level = (state.focus_level + 1) % 3

  if state.focus_level == 0 then
    -- Exit focus
    if state.dim_ns then
      vim.api.nvim_buf_clear_namespace(state.buf, state.dim_ns, 0, -1)
    end
    if state.hunk_dim_ns then
      vim.api.nvim_buf_clear_namespace(state.buf, state.hunk_dim_ns, 0, -1)
    end
    if state.saved_ui.laststatus then
      vim.o.laststatus = state.saved_ui.laststatus
    end
    if state.saved_ui.showtabline then
      vim.o.showtabline = state.saved_ui.showtabline
    end
    state.focus_queue = {}
    state.saved_ui = {}

    -- Remove <Space> keymap if in level 2
    local buf = state.buf
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.keymap.del, "n", "<Space>", { buffer = buf })
    end

    M.refresh()
    vim.api.nvim_echo({ { "-- Focus: Off --", "ModeMsg" } }, false, {})
  elseif state.focus_level == 1 then
    -- Enter file focus
    state.saved_ui.laststatus = vim.o.laststatus
    state.saved_ui.showtabline = vim.o.showtabline
    vim.o.laststatus = 0
    vim.o.showtabline = 0

    state.focus_queue = build_focus_queue()
    state.focus_file_idx = 1
    state.focus_hunk_idx = 1

    if #state.focus_queue > 0 then
      apply_dim_layer(state.focus_queue[1])
    end

    vim.api.nvim_echo({ { "-- Focus: File --", "ModeMsg" } }, false, {})
  elseif state.focus_level == 2 then
    -- Enter hunk focus (all of level 1, plus hunk dimming)
    apply_hunk_dim_layer(vim.api.nvim_win_get_cursor(0)[1])

    -- Add <Space> keymap for hunk advance
    local buf = state.buf
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.keymap.set("n", "<Space>", focus_advance_hunk, { noremap = true, silent = true, buffer = buf })
    end

    vim.api.nvim_echo({ { "-- Focus: Hunk --", "ModeMsg" } }, false, {})
  end
end

local function focus_advance_hunk()
  if state.focus_level ~= 2 then
    -- Not in focus mode; pass through <Space>
    vim.api.nvim_feedkeys(" ", "n", false)
    return
  end

  local current_lnum = vim.api.nvim_win_get_cursor(0)[1]

  -- Find next hunk header after current position
  local next_hunk_lnum = nil
  for _, hunk_lnum in ipairs(state.hunk_header_lnums) do
    if hunk_lnum > current_lnum then
      next_hunk_lnum = hunk_lnum
      break
    end
  end

  if not next_hunk_lnum then
    return  -- No next hunk
  end

  -- Check if next hunk is in a different file
  local next_meta = state.line_map[next_hunk_lnum]
  local current_meta = state.line_map[current_lnum]
  if next_meta and current_meta and next_meta.file_idx ~= current_meta.file_idx then
    -- Find the new file in queue
    for i, f in ipairs(state.focus_queue) do
      if state.line_map[next_hunk_lnum].file == f then
        state.focus_file_idx = i
        break
      end
    end
    apply_dim_layer(next_meta.file)
  end

  -- Move cursor to next hunk
  vim.api.nvim_win_set_cursor(0, { next_hunk_lnum, 0 })
  vim.cmd("normal! zz")

  -- Apply hunk dim
  apply_hunk_dim_layer(next_hunk_lnum)

  -- Collapse all other hunks in the current file
  local file_idx = next_meta.file_idx
  for _, hunk_lnum in ipairs(state.hunk_header_lnums) do
    local hunk_meta = state.line_map[hunk_lnum]
    if hunk_meta and hunk_meta.file_idx == file_idx and hunk_lnum ~= next_hunk_lnum then
      collapse_hunk_context(hunk_lnum)
    end
  end
end

local function apply_heat_map(comment_map)
  local heat_ns = state.heat_ns or vim.api.nvim_create_namespace("locoreview_pr_heat")
  state.heat_ns = heat_ns

  -- Clear namespace first
  vim.api.nvim_buf_clear_namespace(state.buf, heat_ns, 0, -1)

  -- Apply signs to each file header
  for _, lnum in ipairs(state.file_header_lnums) do
    local file = state.line_map[lnum].file
    if file then
      -- Count total comments for this file
      local count = 0
      if comment_map[file] then
        for _, bucket in pairs(comment_map[file]) do
          for _, items in pairs(bucket) do
            count = count + #items
          end
        end
      end

      -- Place sign based on count
      if count > 0 then
        local hl = count >= 3 and "LocoHeatHigh" or "LocoHeatLow"
        vim.api.nvim_buf_set_extmark(state.buf, heat_ns, lnum - 1, 0, {
          sign_text = "▌",
          sign_hl_group = hl,
        })
      end
    end
  end
end

local function open_file_picker()
  -- Build entries
  local entries = {}
  local review_items = load_review_items()
  local comment_map = build_comment_map(review_items)

  for _, fd in ipairs(state.file_diffs) do
    local header_lnum = nil
    for _, lnum in ipairs(state.file_header_lnums) do
      if state.line_map[lnum].file == fd.file then
        header_lnum = lnum
        break
      end
    end

    -- Check if viewed
    local vst = viewed_state.load()
    local is_viewed = vst[fd.file] and vst[fd.file].viewed == true

    -- Count comments
    local comment_count = 0
    if comment_map[fd.file] then
      for _, bucket in pairs(comment_map[fd.file]) do
        for _, items in pairs(bucket) do
          comment_count = comment_count + #items
        end
      end
    end

    -- Build display string
    local status_icon = is_viewed and "✓" or "●"
    local changes = "+" .. fd.stats.added .. " -" .. fd.stats.removed
    local comment_str = comment_count > 0 and ("  " .. comment_count .. " comment(s)") or ""
    local display = status_icon .. " " .. fd.file .. "  " .. changes .. "  [" .. fd.status .. "]" .. comment_str

    table.insert(entries, {
      display = display,
      file = fd.file,
      is_viewed = is_viewed,
      header_lnum = header_lnum,
      ord = is_viewed and 1 or 0,  -- 0 for unviewed, 1 for viewed
      index = #entries,
    })
  end

  -- Sort: unviewed first, then viewed; within each group preserve order
  table.sort(entries, function(a, b)
    if a.ord ~= b.ord then
      return a.ord < b.ord
    end
    return a.index < b.index
  end)

  -- Show picker
  vim.ui.select(entries, {
    prompt = "Jump to file:",
    format_item = function(entry)
      return entry.display
    end,
  }, function(choice)
    if not choice or not choice.header_lnum then
      return
    end

    -- Jump to file
    local win = get_win()
    if not win then return end

    vim.api.nvim_win_set_cursor(win, { choice.header_lnum, 0 })

    -- Open fold if file is collapsed (viewed files start collapsed)
    if choice.is_viewed then
      toggle_fold_at(choice.header_lnum)
    end
  end)
end

local function toggle_fold_at(lnum)
  local meta = state.line_map[lnum]
  if meta and meta.type == "file_header" then
    -- Cursor is on the header (above the fold): move into the fold first
    local fr = fold_range_for(meta.file)
    if fr then
      vim.api.nvim_win_set_cursor(0, { fr.start, 0 })
      vim.cmd("normal! za")
      -- Restore cursor to the header line
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    end
  else
    vim.cmd("normal! za")
  end
end

local function mark_viewed_at_cursor()
  local meta = meta_at_cursor()
  if not meta or not meta.file then
    ui.notify("not on a diff line", vim.log.levels.WARN)
    return
  end

  local file = meta.file
  local diff_hash = diff_hash_for(file)

  viewed_state.mark_viewed(file, diff_hash)

  -- Micro-rewards: show animation if in focus mode
  if state.focus_level > 0 and config.get().pr_view.micro_rewards then
    -- Find the file's header lnum
    local header_lnum = nil
    for _, lnum in ipairs(state.file_header_lnums) do
      if state.line_map[lnum].file == file then
        header_lnum = lnum
        break
      end
    end

    if header_lnum then
      local n = ensure_ns()
      vim.api.nvim_buf_set_extmark(state.buf, n, header_lnum - 1, 0, {
        virt_text = { { " ✓ ✓ ✓ done ✓ ✓ ✓", "DiagnosticSignOk" } },
        virt_text_pos = "eol",
      })
    end

    -- Defer refresh so animation is visible
    vim.defer_fn(function()
      M.refresh()
    end, 300)
  else
    M.refresh()
  end

  -- Auto-advance to next unviewed file if enabled
  if config.get().pr_view.auto_advance_on_viewed then
    -- Find the first unviewed file in file_header_lnums
    for _, lnum in ipairs(state.file_header_lnums) do
      local header_meta = state.line_map[lnum]
      if header_meta and header_meta.is_viewed == false then
        -- Jump to this file's first hunk
        vim.api.nvim_win_set_cursor(0, { lnum, 0 })
        return
      end
    end
    -- All files reviewed
    ui.notify("All files reviewed!", vim.log.levels.INFO)
  end
end

local function mark_unviewed_at_cursor()
  local meta = meta_at_cursor()
  if not meta or not meta.file then return end
  viewed_state.mark_unviewed(meta.file)
  M.refresh()
end

local function add_comment_at_cursor()
  local meta = meta_at_cursor()
  if not meta or not meta.file then
    ui.notify("place cursor on a diff line to comment", vim.log.levels.WARN)
    return
  end

  local line, line_ref
  if meta.type == "remove" and meta.old_line then
    line = meta.old_line
    line_ref = "old"
  elseif (meta.type == "add" or meta.type == "context") and meta.new_line then
    line = meta.new_line
    line_ref = "new"
  else
    ui.notify("place cursor on an added, context, or removed line to comment", vim.log.levels.WARN)
    return
  end

  -- Delegate to the commands module so the full ReviewAdd flow runs.
  require("locoreview.commands").add_at(meta.file, line, nil, line_ref)
end

local function add_quick_comment_at_cursor()
  local meta = meta_at_cursor()
  if not meta or not meta.file then
    ui.notify("place cursor on a diff line to comment", vim.log.levels.WARN)
    return
  end

  local line, line_ref
  if meta.type == "remove" and meta.old_line then
    line = meta.old_line
    line_ref = "old"
  elseif (meta.type == "add" or meta.type == "context") and meta.new_line then
    line = meta.new_line
    line_ref = "new"
  else
    ui.notify("place cursor on an added, context, or removed line to comment", vim.log.levels.WARN)
    return
  end

  -- Prompt for issue text only
  vim.ui.input(
    { prompt = "Quick note: " },
    function(text)
      if not text or text:match("^%s*$") then
        return
      end

      local review_items = load_review_items()
      local next_items, new_item = store.insert(review_items, {
        file = meta.file,
        line = line,
        line_ref = line_ref,
        severity = "low",
        status = "open",
        issue = text,
        requested_change = "",
      })

      if not next_items then
        ui.notify("Failed to add comment", vim.log.levels.ERROR)
        return
      end

      local path = fs.review_file_path()
      if not path then
        ui.notify("Unable to find review file", vim.log.levels.ERROR)
        return
      end

      store.save(path, next_items)
      M.refresh()
      ui.notify("Added comment " .. new_item.id, vim.log.levels.INFO)
    end
  )
end

local function batch_mark_directory()
  local meta = meta_at_cursor()
  if not meta or not meta.file then
    ui.notify("cursor not on a diff line", vim.log.levels.WARN)
    return
  end

  -- Extract directory
  local dir = vim.fn.fnamemodify(meta.file, ":h")
  if dir == "." then
    -- Root-level file; match files with no '/' in path
    dir = ""
  end

  -- Collect files in this directory
  local files_in_dir = {}
  for _, fd in ipairs(state.file_diffs) do
    local matches = false
    if dir == "" then
      -- Root-level: match files with no '/'
      matches = not string.find(fd.file, "/")
    else
      -- Subdirectory: match files starting with "dir/"
      matches = vim.startswith(fd.file, dir .. "/")
    end

    if matches then
      table.insert(files_in_dir, fd)
    end
  end

  if #files_in_dir == 0 then
    ui.notify("no files found in directory", vim.log.levels.WARN)
    return
  end

  -- Confirm with user
  vim.ui.select(
    {"Yes", "No"},
    { prompt = "Mark " .. #files_in_dir .. " files in " .. (dir ~= "" and dir or "/") .. "/ as viewed?" },
    function(choice)
      if choice == "Yes" then
        -- Mark all files as viewed
        for _, fd in ipairs(files_in_dir) do
          viewed_state.mark_viewed(fd.file, fd.diff_hash)
        end
        -- Refresh and show notification
        M.refresh()
        ui.notify("Marked " .. #files_in_dir .. " files viewed", vim.log.levels.INFO)
      end
    end
  )
end

local function start_or_manage_timer()
  if state.timer ~= nil then
    -- Timer already running; offer to cancel or continue
    vim.ui.select(
      {"Cancel timer", "Keep going"},
      { prompt = "Timer is running" },
      function(choice)
        if choice == "Cancel timer" then
          state.timer:stop()
          state.timer:close()
          state.timer = nil
          state.timer_end = nil
          M.refresh()
        end
      end
    )
  else
    -- No timer running; prompt for duration
    vim.ui.input(
      { prompt = "Minutes: " },
      function(input)
        if not input or input:match("^%s*$") then
          return
        end
        local minutes = tonumber(input)
        if not minutes or minutes <= 0 then
          ui.notify("Invalid input: please enter a positive number", vim.log.levels.WARN)
          return
        end

        -- Set timer end time
        state.timer_end = os.time() + (minutes * 60)

        -- Create and start timer
        state.timer = vim.loop.new_timer()
        state.timer:start(0, 10000, vim.schedule_wrap(function()
          M.refresh()
        end))

        ui.notify("Timer started: " .. minutes .. " minutes", vim.log.levels.INFO)
      end
    )
  end
end

local function show_comment_popup()
  local meta = meta_at_cursor()
  if not meta or not meta.file then
    ui.notify("No comment here", vim.log.levels.WARN)
    return
  end

  local review_items = load_review_items()
  local comment_map = build_comment_map(review_items)

  -- Look up the comment
  local file_comments = comment_map[meta.file]
  local items = nil
  if file_comments then
    if meta.type == "remove" and meta.old_line then
      items = file_comments.old and file_comments.old[meta.old_line]
    elseif meta.new_line then
      items = file_comments.new and file_comments.new[meta.new_line]
    end
  end

  if not items or #items == 0 then
    ui.notify("No comment here", vim.log.levels.WARN)
    return
  end

  local item = items[1]  -- Show first item for now

  -- Build content for the float
  local lines = {
    "ID: " .. item.id,
    "Status: " .. item.status,
    "Severity: " .. item.severity,
    "",
  }

  -- Add issue (possibly multi-line)
  table.insert(lines, "Issue:")
  for line in (item.issue .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end

  -- Add requested_change if present
  if item.requested_change and item.requested_change ~= "" then
    table.insert(lines, "")
    table.insert(lines, "Requested change:")
    for line in (item.requested_change .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, line)
    end
  end

  table.insert(lines, "")
  table.insert(lines, "[e] edit  [s] status  [d] delete  [q] close")

  -- Calculate float dimensions
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, #line)
  end
  width = math.min(width + 4, vim.o.columns - 4)
  local height = #lines

  -- Create scratch buffer for float
  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(float_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(float_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(float_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(float_buf, "modifiable", false)

  -- Open float window
  local float_win = vim.api.nvim_open_win(float_buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
  })

  -- Set up keymaps on float buffer
  local float_opts = { noremap = true, silent = true, buffer = float_buf }

  -- Close the float and optionally refresh
  local function close_float()
    if vim.api.nvim_win_is_valid(float_win) then
      vim.api.nvim_win_close(float_win, true)
    end
  end

  -- e: Edit in review.md
  vim.keymap.set("n", "e", function()
    close_float()
    vim.cmd("edit " .. vim.fn.fnameescape(fs.review_file_path()))
    vim.fn.search("^## " .. item.id)
  end, float_opts)

  -- s: Cycle status
  vim.keymap.set("n", "s", function()
    local next_status = nil
    for status_name, _ in pairs(require("locoreview.types").VALID_TRANSITIONS[item.status] or {}) do
      next_status = status_name
      break
    end

    if next_status then
      local items_updated = require("locoreview.store").transition(review_items, item.id, next_status)
      if items_updated then
        require("locoreview.store").save(fs.review_file_path(), items_updated)
        close_float()
        M.refresh()
      end
    end
  end, float_opts)

  -- d: Delete
  vim.keymap.set("n", "d", function()
    vim.ui.select(
      {"Delete", "Cancel"},
      { prompt = "Delete this comment?" },
      function(choice)
        if choice == "Delete" then
          local items_updated = require("locoreview.store").delete(review_items, item.id)
          if items_updated then
            require("locoreview.store").save(fs.review_file_path(), items_updated)
            close_float()
            M.refresh()
          end
        end
      end
    )
  end, float_opts)

  -- q and <Esc>: Close
  local function close_handler()
    close_float()
  end
  vim.keymap.set("n", "q", close_handler, float_opts)
  vim.keymap.set("n", "<Esc>", close_handler, float_opts)

  -- Auto-close on cursor move
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

local function open_source_at_cursor()
  local meta = meta_at_cursor()
  if not meta or not meta.file then return end
  local line = meta.new_line or meta.old_line
  if not line then return end
  local root = git.repo_root()
  vim.cmd("tabprevious")
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. meta.file))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end

local function attach_keymaps(buf)
  local opts = { noremap = true, silent = true, buffer = buf }
  local function bmap(lhs, fn)
    vim.keymap.set("n", lhs, fn, opts)
  end

  bmap("v",        mark_viewed_at_cursor)
  bmap("V",        mark_unviewed_at_cursor)
  bmap("<leader>v", batch_mark_directory)
  bmap("<leader>T", start_or_manage_timer)
  bmap("<leader>F", cycle_focus)
  bmap("<CR>", function()
    local _, lnum = meta_at_cursor()
    toggle_fold_at(lnum)
  end)
  bmap("]f",   function() navigate_files(1)  end)
  bmap("[f",   function() navigate_files(-1) end)
  bmap("<leader>f", open_file_picker)
  bmap("]c",   function() navigate_hunks(1)  end)
  bmap("[c",   function() navigate_hunks(-1) end)
  bmap("zC",   function()
    local lnum = hunk_header_lnum_at_cursor()
    if lnum then collapse_hunk_context(lnum) end
  end)
  bmap("zO",   function()
    local lnum = hunk_header_lnum_at_cursor()
    if lnum then expand_hunk_context(lnum) end
  end)
  bmap("zCA",  function()
    local file_idx = state.line_map[vim.api.nvim_win_get_cursor(0)[1]].file_idx
    if file_idx then
      for _, hunk_lnum in ipairs(state.hunk_header_lnums) do
        if state.line_map[hunk_lnum].file_idx == file_idx then
          collapse_hunk_context(hunk_lnum)
        end
      end
    end
  end)
  bmap("zOA",  function()
    local file_idx = state.line_map[vim.api.nvim_win_get_cursor(0)[1]].file_idx
    if file_idx then
      for _, hunk_lnum in ipairs(state.hunk_header_lnums) do
        if state.line_map[hunk_lnum].file_idx == file_idx then
          expand_hunk_context(hunk_lnum)
        end
      end
    end
  end)
  bmap("c",    add_comment_at_cursor)
  bmap("C",    add_quick_comment_at_cursor)
  bmap("K",    show_comment_popup)
  bmap("go",   open_source_at_cursor)
  bmap("R",    function() M.refresh() end)
  bmap("q",    function() M.close()   end)
  bmap("?",    function() M.show_help() end)
end

-- ── Core open / refresh logic ────────────────────────────────────────────────

local function do_render(file_diffs, review_items, vst)
  -- Clear hunk context marks from previous render
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
  update_sticky_header()
end

-- Sort file_diffs: viewed first (stable sort), then unviewed.
local function sort_file_diffs(file_diffs, vst)
  local indexed = {}
  for i, fd in ipairs(file_diffs) do
    indexed[i] = { fd, i }  -- preserve original index for stable sort
  end

  table.sort(indexed, function(a, b)
    local fd_a, idx_a = a[1], a[2]
    local fd_b, idx_b = b[1], b[2]
    local is_viewed_a = vst[fd_a.file] and vst[fd_a.file].viewed == true
    local is_viewed_b = vst[fd_b.file] and vst[fd_b.file].viewed == true

    -- Viewed files first
    if is_viewed_a ~= is_viewed_b then
      return is_viewed_a  -- true comes before false
    end
    -- Within same group, preserve original order
    return idx_a < idx_b
  end)

  -- Extract sorted file_diffs
  local sorted = {}
  for _, pair in ipairs(indexed) do
    table.insert(sorted, pair[1])
  end
  return sorted
end

-- base_ref == nil   → diff working tree against HEAD (all uncommitted changes)
-- base_ref == string → diff <ref>...HEAD  (PR / branch-comparison style)
local function do_open_or_refresh(base_ref)
  setup_hl()
  state.base_ref = base_ref   -- nil is valid; persisted so refresh reuses it

  -- Parse diff
  local file_diffs, err = git_diff.parse(base_ref)
  if not file_diffs then
    ui.notify("ReviewPR: " .. (err or "git diff failed"), vim.log.levels.ERROR)
    return
  end
  local desc = base_ref and ("relative to " .. base_ref) or "uncommitted changes"
  if #file_diffs == 0 then
    ui.notify("no " .. desc, vim.log.levels.INFO)
    return
  end

  local review_items = load_review_items()

  -- Sync viewed state (auto-reset changed files)
  local vst = viewed_state.sync(file_diffs)

  -- Sort: viewed files first, then unviewed
  file_diffs = sort_file_diffs(file_diffs, vst)
  state.file_diffs = file_diffs

  -- Create buffer if needed
  local is_new_buf = not state.buf or not vim.api.nvim_buf_is_valid(state.buf)
  if is_new_buf then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, "buftype",  "nofile")
    vim.api.nvim_buf_set_option(buf, "bufhidden","wipe")
    vim.api.nvim_buf_set_option(buf, "swapfile", false)
    pcall(vim.api.nvim_buf_set_name, buf, "locoreview://pr-review")
    state.buf = buf

    vim.api.nvim_create_autocmd("BufDelete", {
      buffer = state.buf,
      once   = true,
      callback = function()
        -- Cleanup timer
        if state.timer ~= nil then
          state.timer:stop()
          state.timer:close()
          state.timer = nil
          state.timer_end = nil
        end

        -- Cleanup sticky header float
        if state.sticky_autocmd ~= nil then
          vim.api.nvim_del_autocmd(state.sticky_autocmd)
          state.sticky_autocmd = nil
        end
        if state.sticky_win and vim.api.nvim_win_is_valid(state.sticky_win) then
          vim.api.nvim_win_close(state.sticky_win, true)
          state.sticky_win = nil
        end
        state.sticky_buf = nil

        state.buf     = nil
        state.tabpage = nil
        state.line_map    = {}
        state.fold_ranges = {}
        state.file_header_lnums = {}
        state.hunk_header_lnums = {}
      end,
    })
  end

  -- Render content into buffer
  do_render(file_diffs, review_items, vst)

  -- Open / focus window
  if not is_alive() then
    vim.cmd("tabnew")
    state.tabpage = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_win_set_buf(0, state.buf)
    if is_new_buf then
      attach_keymaps(state.buf)
    end
    -- Window-local display options
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_option(win, "number",         false)
    vim.api.nvim_win_set_option(win, "relativenumber", false)
    vim.api.nvim_win_set_option(win, "signcolumn",     "no")
    vim.api.nvim_win_set_option(win, "wrap",           false)
  else
    vim.api.nvim_set_current_tabpage(state.tabpage)
  end

  -- Set up folds in the PR view window
  local win = get_win()
  if win then
    setup_folds(win, state.fold_ranges)
    create_sticky_header(win)
    update_sticky_header()
  end
end

-- ── Public API ───────────────────────────────────────────────────────────────

-- Open the PR diff view.
--   base_ref supplied  → use it directly (e.g. ":ReviewPR origin/main")
--   base_ref omitted   → show a quick picker so the user can choose what to
--                         diff against; defaults to "uncommitted changes"
function M.open(base_ref)
  if base_ref ~= nil then
    -- Explicit ref supplied: open immediately.
    do_open_or_refresh(base_ref)
    return
  end

  -- No explicit ref: offer a quick-pick.
  local cfg       = config.get()
  local auto_base = git.base_branch(cfg)

  local choices = {
    { label = "Uncommitted changes  (git diff HEAD)",        ref = false },
    { label = "vs " .. auto_base .. "  [PR-style]",         ref = auto_base },
    { label = "Custom ref…",                                 ref = "custom" },
  }

  vim.ui.select(choices, {
    prompt      = "ReviewPR: diff against",
    format_item = function(c) return c.label end,
  }, function(choice)
    if not choice then return end
    if choice.ref == "custom" then
      ui.prompt_git_ref(auto_base, function(ref)
        if ref then
          -- empty input → treat as uncommitted
          do_open_or_refresh(ref ~= "" and ref or nil)
        end
      end)
    else
      -- false → nil (uncommitted), any string → branch ref
      do_open_or_refresh(choice.ref ~= false and choice.ref or nil)
    end
  end)
end

-- Re-parse the diff and re-render in the existing tab (or open a new one).
function M.refresh()
  do_open_or_refresh(state.base_ref)
  if is_alive() then
    ui.notify("PR view refreshed", vim.log.levels.INFO)
  end
end

-- Close the PR view tab.
function M.close()
  -- Cleanup timer
  if state.timer ~= nil then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
    state.timer_end = nil
  end

  -- Cleanup sticky header float
  if state.sticky_autocmd ~= nil then
    vim.api.nvim_del_autocmd(state.sticky_autocmd)
    state.sticky_autocmd = nil
  end
  if state.sticky_win and vim.api.nvim_win_is_valid(state.sticky_win) then
    vim.api.nvim_win_close(state.sticky_win, true)
    state.sticky_win = nil
  end
  state.sticky_buf = nil

  -- Cleanup focus mode
  if state.focus_level > 0 then
    if state.focus_level == 2 and state.buf then
      pcall(vim.keymap.del, "n", "<Space>", { buffer = state.buf })
    end
    if state.dim_ns then
      pcall(vim.api.nvim_buf_clear_namespace, state.buf, state.dim_ns, 0, -1)
    end
    if state.hunk_dim_ns then
      pcall(vim.api.nvim_buf_clear_namespace, state.buf, state.hunk_dim_ns, 0, -1)
    end
    if state.saved_ui.laststatus ~= nil then
      vim.o.laststatus = state.saved_ui.laststatus
    end
    if state.saved_ui.showtabline ~= nil then
      vim.o.showtabline = state.saved_ui.showtabline
    end
    state.focus_level = 0
    state.focus_queue = {}
    state.saved_ui = {}
  end

  -- Cleanup hunk context namespace
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
  state.tabpage = nil
  state.buf     = nil
  state.line_map    = {}
  state.fold_ranges = {}
  state.file_header_lnums = {}
  state.hunk_header_lnums = {}
end

function M.show_help()
  local lines = {
    "locoreview PR view keymaps",
    "  v          mark file viewed + collapse",
    "  V          mark file unviewed + expand",
    "  <leader>v  mark all files in same directory as viewed",
    "  <CR>       toggle file fold",
    "  ]f / [f    next / previous file",
    "  ]c / [c    next / previous hunk",
    "  c          add review comment at cursor line",
    "  C          quick comment (one prompt, low severity)",
    "  K          show full comment popup",
    "  go         open source file at cursor line",
    "  <leader>T  start / cancel timed review session",
    "  <leader>F  cycle focus mode (Off → File → Hunk)",
    "  <Space>    advance to next hunk (Focus Hunk mode only)",
    "  zC / zO    collapse / expand hunk context",
    "  zCA / zOA  collapse / expand all hunks in file",
    "  <leader>f  open file jump picker",
    "  R          refresh diff",
    "  q          close",
    "  ?          this help",
  }
  ui.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
