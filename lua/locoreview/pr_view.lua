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
    LocoFileHeader  = { link = "Title" },
    LocoFileViewed  = { link = "Comment" },
    LocoHunkHeader  = { link = "Special" },
    LocoViewed      = { link = "DiagnosticSignOk" },
    LocoUnviewed    = { link = "DiagnosticSignWarn" },
    LocoComment     = { link = "DiagnosticVirtualTextInfo" },
    LocoDiffSep     = { link = "LineNr" },
    LocoBinaryNote  = { link = "Comment" },
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

-- ── Rendering ───────────────────────────────────────────────────────────────

local SEP = string.rep("─", 64)

-- Build {file → {new_line → [items]}} for fast lookup during decoration.
local function build_comment_map(items)
  local map = {}
  for _, item in ipairs(items or {}) do
    map[item.file] = map[item.file] or {}
    map[item.file][item.line] = map[item.file][item.line] or {}
    table.insert(map[item.file][item.line], item)
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

  for fi, fd in ipairs(file_diffs) do
    local is_viewed = vst[fd.file] and vst[fd.file].viewed == true

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
    if meta.type == "file_header" then
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
    if meta.new_line and meta.file
        and (meta.type == "add" or meta.type == "context") then
      local file_comments = comment_map[meta.file]
      local items = file_comments and file_comments[meta.new_line]
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
  viewed_state.mark_viewed(meta.file, diff_hash_for(meta.file))
  M.refresh()
end

local function mark_unviewed_at_cursor()
  local meta = meta_at_cursor()
  if not meta or not meta.file then return end
  viewed_state.mark_unviewed(meta.file)
  M.refresh()
end

local function add_comment_at_cursor()
  local meta = meta_at_cursor()
  if not meta or not meta.new_line then
    ui.notify("place cursor on an added or context line to comment", vim.log.levels.WARN)
    return
  end
  if meta.type ~= "add" and meta.type ~= "context" then
    ui.notify("comments can only be added to added (+) or context lines", vim.log.levels.WARN)
    return
  end
  -- Delegate to the commands module so the full ReviewAdd flow runs.
  require("locoreview.commands").add_at(meta.file, meta.new_line, nil)
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

  bmap("v",    mark_viewed_at_cursor)
  bmap("V",    mark_unviewed_at_cursor)
  bmap("<CR>", function()
    local _, lnum = meta_at_cursor()
    toggle_fold_at(lnum)
  end)
  bmap("]f",   function() navigate_files(1)  end)
  bmap("[f",   function() navigate_files(-1) end)
  bmap("]c",   function() navigate_hunks(1)  end)
  bmap("[c",   function() navigate_hunks(-1) end)
  bmap("c",    add_comment_at_cursor)
  bmap("go",   open_source_at_cursor)
  bmap("R",    function() M.refresh() end)
  bmap("q",    function() M.close()   end)
  bmap("?",    function() M.show_help() end)
end

-- ── Core open / refresh logic ────────────────────────────────────────────────

local function do_render(file_diffs, review_items, vst)
  local comment_map = build_comment_map(review_items)
  local lm, fr, fhl, hhl = render(file_diffs, review_items, vst)
  state.line_map          = lm
  state.fold_ranges       = fr
  state.file_header_lnums = fhl
  state.hunk_header_lnums = hhl
  apply_highlights(lm)
  apply_comment_badges(lm, comment_map)
end

local function load_review_items()
  local path = fs.review_file_path()
  if not path then return {} end
  local items, _ = store.load(path)
  return items or {}
end

local function do_open_or_refresh(base_ref)
  setup_hl()
  local cfg = config.get()
  base_ref = base_ref or state.base_ref or git.base_branch(cfg)
  state.base_ref = base_ref

  -- Parse diff
  local file_diffs, err = git_diff.parse(base_ref)
  if not file_diffs then
    ui.notify("ReviewPR: " .. (err or "git diff failed"), vim.log.levels.ERROR)
    return
  end
  if #file_diffs == 0 then
    ui.notify("no changes relative to " .. base_ref, vim.log.levels.INFO)
    return
  end
  state.file_diffs = file_diffs

  local review_items = load_review_items()

  -- Sync viewed state (auto-reset changed files)
  local vst = viewed_state.sync(file_diffs)

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
  end
end

-- ── Public API ───────────────────────────────────────────────────────────────

-- Open the PR diff view.  base_ref defaults to the configured base branch.
function M.open(base_ref)
  do_open_or_refresh(base_ref)
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
    "  <CR>       toggle file fold",
    "  ]f / [f    next / previous file",
    "  ]c / [c    next / previous hunk",
    "  c          add review comment at cursor line",
    "  go         open source file at cursor line",
    "  R          refresh diff",
    "  q          close",
    "  ?          this help",
  }
  ui.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
