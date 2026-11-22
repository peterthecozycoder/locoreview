-- A read-only diff with source locations and review comments.
local M = {}
local git = require("locoreview.git")
local git_diff = require("locoreview.git_diff")
local fs = require("locoreview.fs")
local store = require("locoreview.store")
local ui = require("locoreview.ui")

local state = { buf = nil, win = nil, base = nil, rows = {}, files = {}, hunks = {} }
local ns = vim.api.nvim_create_namespace("locoreview.pr")

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function location()
  return state.rows[vim.api.nvim_win_get_cursor(state.win)[1]]
end

local function jump(rows, direction)
  local current = vim.api.nvim_win_get_cursor(state.win)[1]
  if direction > 0 then
    for _, row in ipairs(rows) do
      if row > current then
        vim.api.nvim_win_set_cursor(state.win, { row, 0 })
        return
      end
    end
  else
    for i = #rows, 1, -1 do
      if rows[i] < current then
        vim.api.nvim_win_set_cursor(state.win, { rows[i], 0 })
        return
      end
    end
  end
end

local function show_comments()
  local loc = location()
  if not loc or #loc.comments == 0 then
    ui.notify("no comments on this line")
    return
  end
  require("locoreview.commands").show_at(loc.file, loc.line, loc.side)
end

local function attach_maps()
  local function map(key, callback, desc)
    vim.keymap.set("n", key, callback, { buffer = state.buf, silent = true, desc = desc })
  end
  map("c", function()
    local loc = location()
    if not loc or not loc.line then
      ui.notify("place the cursor on a diff line to comment")
      return
    end
    require("locoreview.commands").add_at(loc.file, loc.line, nil, loc.side)
  end, "Add comment")
  map("K", show_comments, "Manage comments")
  map("L", function() vim.cmd("ReviewList") end, "Browse all review comments")
  map("go", function()
    local loc = location()
    if not loc or not loc.line then return end
    if loc.side == "old" then
      ui.notify("removed lines exist only in the base revision")
      return
    end
    local root = git.repo_root()
    if not root then return end
    vim.cmd("tabnew " .. vim.fn.fnameescape(root .. "/" .. loc.file))
    vim.api.nvim_win_set_cursor(0, { math.min(loc.line, vim.api.nvim_buf_line_count(0)), 0 })
  end, "Open source")
  map("]f", function() jump(state.files, 1) end, "Next file")
  map("[f", function() jump(state.files, -1) end, "Previous file")
  map("]c", function() jump(state.hunks, 1) end, "Next hunk")
  map("[c", function() jump(state.hunks, -1) end, "Previous hunk")
  map("R", M.refresh, "Refresh diff")
  map("q", M.close, "Close review")
  map("?", function()
    ui.notify("c add comment · K manage comments · L all comments · go source · ]f/[f files · ]c/[c hunks · R refresh · q close")
  end, "Review help")
end

function M.refresh()
  if not M.is_open() then return end
  local files, err = git_diff.parse(state.base)
  if not files then
    ui.notify(err, vim.log.levels.ERROR)
    return
  end
  local path = fs.review_file_path()
  local items = {}
  if path and fs.exists(path) then
    items, err = store.load(path)
    if not items then
      ui.notify(err, vim.log.levels.ERROR)
      return
    end
  end
  -- Index once, rather than scanning every comment for each rendered diff line.
  local by_file = {}
  for _, item in ipairs(items) do
    by_file[item.file] = by_file[item.file] or {}
    table.insert(by_file[item.file], item)
  end
  local lines, highlights = {}, {}
  state.rows, state.files, state.hunks = {}, {}, {}
  local function append(text, hl, loc)
    table.insert(lines, text)
    if hl then table.insert(highlights, { #lines - 1, hl }) end
    if loc then
      loc.comments = {}
      for _, item in ipairs(by_file[loc.file] or {}) do
        if (item.line_ref or "new") == loc.side and loc.line >= item.line
          and loc.line <= (item.end_line or item.line) then
          table.insert(loc.comments, item)
        end
      end
      state.rows[#lines] = loc
    end
  end
  for _, file in ipairs(files) do
    table.insert(state.files, #lines + 1)
    append(string.format("%s  +%d -%d", file.file, file.stats.added, file.stats.removed), "Title")
    if #file.hunks == 0 then append("  " .. file.status .. " (no text hunks)", "Comment") end
    for _, hunk in ipairs(file.hunks) do
      table.insert(state.hunks, #lines + 1)
      append(hunk.header, "DiffChange")
      for _, line in ipairs(hunk.lines) do
        local old = line.type == "remove"
        append(line.text, old and "DiffDelete" or (line.type == "add" and "DiffAdd" or nil), {
          file = old and file.old_file or file.file,
          line = old and line.old_line or line.new_line,
          side = old and "old" or "new",
        })
      end
    end
    append("")
  end
  if #lines == 0 then
    lines = { state.base and "  no changes against " .. state.base or "  no uncommitted changes" }
  end
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, entry in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(state.buf, ns, entry[1], 0, { line_hl_group = entry[2] })
  end
  for row, loc in pairs(state.rows) do
    if #loc.comments > 0 then
      vim.api.nvim_buf_set_extmark(state.buf, ns, row - 1, 0, {
        virt_text = { { string.format("  %d comment%s · K to read", #loc.comments, #loc.comments == 1 and "" or "s"), "DiagnosticInfo" } },
      })
    end
  end
  vim.api.nvim_win_set_cursor(state.win, { math.min(cursor[1], #lines), 0 })
end

function M.open(base)
  state.base = base or nil
  if M.is_open() then
    vim.api.nvim_set_current_win(state.win)
  else
    vim.cmd("tabnew")
    state.win = vim.api.nvim_get_current_win()
    state.buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(state.buf, "locoreview://pr-review")
    vim.bo[state.buf].buftype = "nofile"
    vim.bo[state.buf].bufhidden = "wipe"
    vim.bo[state.buf].swapfile = false
    vim.wo[state.win].wrap = false
    attach_maps()
  end
  M.refresh()
end

function M.close()
  if M.is_open() then vim.api.nvim_win_close(state.win, true) end
  state.win, state.buf = nil, nil
end

return M
