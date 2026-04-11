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

local state_mod    = require("locoreview.pr.state")
local state        = state_mod.state
local ensure_ns    = state_mod.ensure_ns

local render_mod   = require("locoreview.pr.render")
local deco         = require("locoreview.pr.decorations")
local actions_mod  = require("locoreview.pr.actions")
local chrome_mod   = require("locoreview.pr.chrome")
local rhythm_mod   = require("locoreview.pr.rhythm")

local setup_hl         = deco.setup_hl
local apply_highlights = deco.apply_highlights
local apply_comment_badges  = deco.apply_comment_badges
local apply_heat_map        = deco.apply_heat_map
local apply_hunk_spotlight  = deco.apply_hunk_spotlight
local apply_active_file_tint = deco.apply_active_file_tint
local apply_dim_layer       = deco.apply_dim_layer
local apply_sweep_dim       = deco.apply_sweep_dim
local apply_rhythm_dims     = deco.apply_rhythm_dims

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

-- Aliases for render_mod helpers used throughout this file.
local MOOD_DOT                = render_mod.MOOD_DOT
local get_entry_mood          = render_mod.get_entry_mood
local build_comment_map       = render_mod.build_comment_map
local comment_count_for       = render_mod.comment_count_for
local get_file_effective_mood = render_mod.get_file_effective_mood
local sort_file_diffs         = render_mod.sort_file_diffs

-- ── Folds ─────────────────────────────────────────────────────────────────────

local function setup_folds(win, fold_ranges)
  chrome_mod.setup_folds(win, fold_ranges)
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

chrome_mod.setup({
  ctx = {
    get_win = get_win,
    fold_range_for = fold_range_for,
  },
})

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

-- ── Shared local helpers ──────────────────────────────────────────────────────

-- Return the display line number of the file-header line for `file`, or nil.
local function header_lnum_for_file(file)
  for _, lnum in ipairs(state.file_header_lnums) do
    if state.line_map[lnum] and state.line_map[lnum].file == file then
      return lnum
    end
  end
  return nil
end

-- Given a diff-line meta table, return (line_number, line_ref) for a comment,
-- or (nil, nil) if the line type cannot carry a comment.
local function resolve_comment_line(meta)
  if meta.type == "remove" and meta.old_line then
    return meta.old_line, "old"
  elseif (meta.type == "add" or meta.type == "context") and meta.new_line then
    return meta.new_line, "new"
  end
  return nil, nil
end

-- Build a unified-diff patch string for a single hunk.
local function build_hunk_patch(fd, hunk)
  local patch_lines = { "--- a/" .. fd.old_file, "+++ b/" .. fd.file, hunk.header }
  for _, dl in ipairs(hunk.lines) do table.insert(patch_lines, dl.text) end
  return table.concat(patch_lines, "\n") .. "\n"
end

rhythm_mod.setup({
  ctx = {
    load_review_items = load_review_items,
    build_comment_map = build_comment_map,
    get_file_effective_mood = get_file_effective_mood,
    get_entry_mood = get_entry_mood,
    header_lnum_for_file = header_lnum_for_file,
    apply_dim_layer = apply_dim_layer,
    apply_sweep_dim = apply_sweep_dim,
  },
  refresh = function() M.refresh() end,
})

-- ── Navigation ────────────────────────────────────────────────────────────────

-- Generic forward/backward navigation through a sorted list of line numbers.
local function navigate_list(list, direction)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if direction > 0 then
    for _, hl in ipairs(list) do
      if hl > lnum then vim.api.nvim_win_set_cursor(0, { hl, 0 }); return end
    end
  else
    for i = #list, 1, -1 do
      if list[i] < lnum then vim.api.nvim_win_set_cursor(0, { list[i], 0 }); return end
    end
  end
end

local function navigate_files(direction) navigate_list(state.file_header_lnums, direction) end
local function navigate_hunks(direction)  navigate_list(state.hunk_header_lnums,  direction) end

-- ── Sticky header float ───────────────────────────────────────────────────────

local function update_sticky_header()
  chrome_mod.update_sticky_header()
end

local function create_sticky_header(win)
  chrome_mod.create_sticky_header(win)
end

-- ── Action hint bar ───────────────────────────────────────────────────────────

local function hint_text_for(meta)
  return chrome_mod.hint_text_for(meta)
end

local function update_hint_bar(meta)
  chrome_mod.update_hint_bar(meta)
end

local function create_hint_bar(win)
  chrome_mod.create_hint_bar(win)
end

-- ── Hunk context collapse ─────────────────────────────────────────────────────

local function get_context_lnums_for_hunk(hunk_header_lnum)
  return chrome_mod.get_context_lnums_for_hunk(hunk_header_lnum)
end

local function collapse_hunk_context(hunk_header_lnum)
  chrome_mod.collapse_hunk_context(hunk_header_lnum)
end

local function expand_hunk_context(hunk_header_lnum)
  chrome_mod.expand_hunk_context(hunk_header_lnum)
end

-- ── Rhythm mode (replaces focus modes) ───────────────────────────────────────

local function cycle_rhythm()
  rhythm_mod.cycle_rhythm()
end

-- ── File picker ───────────────────────────────────────────────────────────────

local function toggle_fold_at(lnum)
  chrome_mod.toggle_fold_at(lnum)
end

local function open_file_picker()
  local review_items = load_review_items()
  local comment_map  = build_comment_map(review_items)
  local vst          = viewed_state.load()

  local entries = {}
  for _, fd in ipairs(state.file_diffs) do
    local header_lnum = header_lnum_for_file(fd.file)

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


-- ── Actions module ───────────────────────────────────────────────────────────

actions_mod.setup({
  ctx = {
    meta_at_cursor      = meta_at_cursor,
    queue_cursor_restore = queue_cursor_restore,
    header_lnum_for_file = header_lnum_for_file,
    diff_hash_for       = diff_hash_for,
    build_hunk_patch    = build_hunk_patch,
    resolve_comment_line = resolve_comment_line,
    build_comment_map   = build_comment_map,
    get_entry_mood      = get_entry_mood,
  },
  refresh = function() M.refresh() end,
})

-- ── Keymaps ───────────────────────────────────────────────────────────────────

local function attach_keymaps(buf)
  local opts = { noremap = true, silent = true, buffer = buf }
  local function bmap(lhs, fn) vim.keymap.set("n", lhs, fn, opts) end

  bmap("v",           actions_mod.mark_reviewed_at_cursor)
  bmap("V",           actions_mod.mark_unviewed_at_cursor)
  bmap("s",           actions_mod.snooze_file_at_cursor)
  bmap("<leader>v",   actions_mod.batch_mark_directory)
  bmap("<leader>T",   actions_mod.start_or_manage_timer)
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
  bmap("c",          actions_mod.add_comment_at_cursor)
  bmap("C",          actions_mod.add_quick_comment_at_cursor)
  bmap("K",          actions_mod.show_comment_popup)
  bmap("d",          actions_mod.open_file_actions_menu)
  bmap("<leader>a",  actions_mod.open_file_actions_menu)
  bmap("<leader>R",  actions_mod.remove_resolved_comments)
  bmap("go",         actions_mod.open_source_at_cursor)
  bmap("R",          function() M.refresh() end)
  bmap("q",          function() M.close()   end)
  bmap("?",          function() M.show_help() end)
end

-- ── Core render / open logic ──────────────────────────────────────────────────

local function render_empty_view(desc)
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end

  state.hidden_files      = {}
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
    ensure_ns(),
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

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  no " .. desc })
  vim.bo[buf].modifiable = false

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
  local lm, fr, fhl, hhl = render_mod.render(file_diffs, review_items, vst, state.buf)
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

local function do_open_or_refresh(base_ref)
  local prev_base_ref = state.base_ref
  setup_hl()
  state.base_ref = base_ref

  if state.base_ref == nil or prev_base_ref ~= state.base_ref then
    state.hidden_files = {}
  end

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

  if state.base_ref ~= nil and next(state.hidden_files) ~= nil then
    local filtered = {}
    for _, fd in ipairs(file_diffs) do
      if not state.hidden_files[fd.file] then
        table.insert(filtered, fd)
      end
    end
    file_diffs = filtered
  end

  state.file_diffs   = file_diffs

  local is_new_buf = not state.buf or not vim.api.nvim_buf_is_valid(state.buf)
  if is_new_buf then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
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
        state.hidden_files = {}
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
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap = false
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
  rhythm_mod.clear_rhythm_advance_map(state.buf)

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
  local advance_lhs = rhythm_mod.rhythm_advance_lhs()
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
