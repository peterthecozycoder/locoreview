-- pr/chrome.lua
-- Window chrome for PR view: folds, sticky header, action hint bar, and hunk
-- context collapse/expand controls.

local M = {}

local config    = require("locoreview.config")
local state_mod = require("locoreview.pr.state")
local state     = state_mod.state
local ensure_ns = state_mod.ensure_ns

local ctx = {}

function M.setup(opts)
  opts = opts or {}
  ctx = opts.ctx or {}
end

local function call_ctx(name, ...)
  local fn = ctx[name]
  if type(fn) ~= "function" then return nil end
  return fn(...)
end

function M.setup_folds(win, fold_ranges)
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

function M.update_sticky_header()
  if not state.sticky_win or not vim.api.nvim_win_is_valid(state.sticky_win) then return end
  local win = call_ctx("get_win")
  if not win then return end

  local top = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)

  local header_lnum = nil
  for i = #state.file_header_lnums, 1, -1 do
    if state.file_header_lnums[i] <= top then
      header_lnum = state.file_header_lnums[i]
      break
    end
  end

  vim.bo[state.sticky_buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(state.sticky_buf, ensure_ns(), 0, -1)
  if not header_lnum or header_lnum == top then
    local top_text = vim.api.nvim_buf_get_lines(state.buf, top - 1, top, false)[1]
    vim.api.nvim_buf_set_lines(state.sticky_buf, 0, -1, false, { top_text or "" })
  else
    local text = vim.api.nvim_buf_get_lines(state.buf, header_lnum - 1, header_lnum, false)[1]
    vim.api.nvim_buf_set_lines(state.sticky_buf, 0, -1, false, { text or "" })
    local meta = state.line_map[header_lnum]
    local hl = (meta and meta.mood == "reviewed") and "LocoFileViewed" or "LocoFileHeader"
    vim.api.nvim_buf_add_highlight(state.sticky_buf, ensure_ns(), hl, 0, 0, -1)
  end
  vim.bo[state.sticky_buf].modifiable = false
end

function M.create_sticky_header(win)
  if state.sticky_win and vim.api.nvim_win_is_valid(state.sticky_win) then return end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"

  local float_win = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = win,
    row = 0,
    col = 0,
    width = vim.api.nvim_win_get_width(win),
    height = 1,
    focusable = false,
    style = "minimal",
    zindex = 50,
  })
  state.sticky_win = float_win
  state.sticky_buf = buf
  state.sticky_autocmd = vim.api.nvim_create_autocmd("WinScrolled", {
    callback = function()
      M.update_sticky_header()
    end,
  })
end

M.HINT_CONTEXTS = {
  file_header = "  v reviewed  ·  s snooze  ·  <CR> expand  ·  go open  ·  d/<leader>a actions  ·  ? help",
  hunk_header = "  c comment  ·  zC collapse  ·  ]c next hunk  ·  v reviewed  ·  s snooze",
  diff = "  c comment  ·  C quick note  ·  K show note  ·  v reviewed  ·  ]f next file",
  default = "  ]f/[f files  ·  ]c/[c hunks  ·  <leader>F rhythm  ·  R refresh  ·  q close",
}

function M.hint_text_for(meta)
  if not meta then return M.HINT_CONTEXTS.default end
  local t = meta.type
  if t == "file_header" then return M.HINT_CONTEXTS.file_header end
  if t == "hunk_header" then return M.HINT_CONTEXTS.hunk_header end
  if t == "add" or t == "remove" or t == "context" then return M.HINT_CONTEXTS.diff end
  return M.HINT_CONTEXTS.default
end

function M.update_hint_bar(meta)
  if not state.hint_win or not vim.api.nvim_win_is_valid(state.hint_win) then return end
  local text = M.hint_text_for(meta)
  vim.bo[state.hint_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.hint_buf, 0, -1, false, { text })
  vim.bo[state.hint_buf].modifiable = false
end

function M.create_hint_bar(win)
  if not (config.get().pr_view and config.get().pr_view.action_hints ~= false) then return end
  if state.hint_win and vim.api.nvim_win_is_valid(state.hint_win) then return end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"

  local win_height = vim.api.nvim_win_get_height(win)
  local win_width = vim.api.nvim_win_get_width(win)

  local hint_win = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = win,
    row = win_height - 1,
    col = 0,
    width = win_width,
    height = 1,
    focusable = false,
    style = "minimal",
    zindex = 49,
  })

  vim.wo[hint_win].winhl = "Normal:StatusLine"

  state.hint_win = hint_win
  state.hint_buf = buf

  M.update_hint_bar(nil)
end

function M.get_context_lnums_for_hunk(hunk_header_lnum)
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

function M.collapse_hunk_context(hunk_header_lnum)
  if state.hunk_ctx_marks[hunk_header_lnum] then return end
  local lnums = M.get_context_lnums_for_hunk(hunk_header_lnum)
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

  local win = call_ctx("get_win")
  if win then
    vim.wo[win].conceallevel = 2
  end
end

function M.expand_hunk_context(hunk_header_lnum)
  local ids = state.hunk_ctx_marks[hunk_header_lnum]
  if not ids then return end
  for _, id in ipairs(ids) do
    if state.hunk_ctx_ns then
      pcall(vim.api.nvim_buf_del_extmark, state.buf, state.hunk_ctx_ns, id)
    end
  end
  state.hunk_ctx_marks[hunk_header_lnum] = nil
  if not next(state.hunk_ctx_marks) then
    local win = call_ctx("get_win")
    if win then
      vim.wo[win].conceallevel = 0
    end
  end
end

function M.toggle_fold_at(lnum)
  local meta = state.line_map[lnum]
  if meta and meta.type == "file_header" then
    local fr = call_ctx("fold_range_for", meta.file)
    if fr then
      vim.api.nvim_win_set_cursor(0, { fr.start, 0 })
      vim.cmd("normal! za")
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    end
  else
    vim.cmd("normal! za")
  end
end

return M
