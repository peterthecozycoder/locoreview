-- pr/rhythm.lua
-- Rhythm modes (overview/focus/sweep), queue building, advance mapping, and
-- mode transitions.

local M = {}

local config       = require("locoreview.config")
local ui           = require("locoreview.ui")
local viewed_state = require("locoreview.viewed_state")
local state_mod    = require("locoreview.pr.state")
local state        = state_mod.state

local ctx = {}
local refresh_cb = function() end

function M.setup(opts)
  opts = opts or {}
  ctx = opts.ctx or {}
  refresh_cb = opts.refresh or function() end
end

local function refresh()
  refresh_cb()
end

local function call_ctx(name, ...)
  local fn = ctx[name]
  if type(fn) ~= "function" then return nil end
  return fn(...)
end

function M.build_rhythm_queue()
  local vst          = viewed_state.load()
  local review_items = call_ctx("load_review_items")
  local comment_map  = call_ctx("build_comment_map", review_items)

  local priority = {
    blocked = 0,
    risky = 1,
    in_progress = 2,
    untouched = 3,
    generated = 4,
    snoozed = 5,
    reviewed = 6,
  }

  local items = {}
  for _, fd in ipairs(state.file_diffs) do
    local mood = call_ctx("get_file_effective_mood", fd.file, vst, comment_map, fd)
    table.insert(items, { file = fd.file, mood = mood, pri = priority[mood] or 99 })
  end
  table.sort(items, function(a, b) return a.pri < b.pri end)

  local queue = {}
  for _, item in ipairs(items) do
    table.insert(queue, item.file)
  end
  return queue
end

function M.resolve_rhythm_advance_lhs()
  local cfg = config.get().pr_view or {}
  if type(cfg.rhythm_advance_key) == "string" and cfg.rhythm_advance_key ~= "" then
    return cfg.rhythm_advance_key
  end
  if vim.g.mapleader == " " then
    return "<Tab>"
  end
  return "<Space>"
end

function M.rhythm_advance_lhs()
  return state.rhythm_advance_lhs or M.resolve_rhythm_advance_lhs()
end

function M.clear_rhythm_advance_map(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    state.rhythm_advance_lhs = nil
    return
  end
  local lhs = M.rhythm_advance_lhs()
  pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  state.rhythm_advance_lhs = nil
end

function M.set_rhythm_advance_map(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local lhs = M.resolve_rhythm_advance_lhs()
  M.clear_rhythm_advance_map(buf)
  vim.keymap.set("n", lhs, M.rhythm_advance, { noremap = true, silent = true, buffer = buf })
  state.rhythm_advance_lhs = lhs
end

function M.rhythm_advance()
  if state.rhythm_mode == "overview" then
    local key = vim.api.nvim_replace_termcodes(M.rhythm_advance_lhs(), true, false, true)
    vim.api.nvim_feedkeys(key, "n", false)
    return
  end

  local vst = viewed_state.load()

  local candidates = {}
  for _, file in ipairs(state.rhythm_queue) do
    local mood = call_ctx("get_entry_mood", vst[file])
    if state.rhythm_mode == "focus" then
      if not viewed_state.is_snoozed(file) then
        table.insert(candidates, file)
      end
    else
      if mood ~= "reviewed" and not viewed_state.is_snoozed(file) then
        table.insert(candidates, file)
      end
    end
  end

  if #candidates == 0 then
    ui.notify("all files handled", vim.log.levels.INFO)
    return
  end

  local current_file = state.rhythm_queue[state.rhythm_file_idx]
  local next_file    = candidates[1]
  local found_current = false
  for _, f in ipairs(candidates) do
    if found_current then
      next_file = f
      break
    end
    if f == current_file then
      found_current = true
    end
  end

  local next_lnum = call_ctx("header_lnum_for_file", next_file)
  if next_lnum then
    for i, f in ipairs(state.rhythm_queue) do
      if f == next_file then
        state.rhythm_file_idx = i
        break
      end
    end
    vim.api.nvim_win_set_cursor(0, { next_lnum, 0 })
    vim.cmd("normal! zz")
    if state.rhythm_mode == "focus" then
      call_ctx("apply_dim_layer", next_file)
    end
  end
end

function M.cycle_rhythm()
  local modes = { "overview", "focus", "sweep" }
  local cur_idx = 1
  for i, m in ipairs(modes) do
    if m == state.rhythm_mode then
      cur_idx = i
      break
    end
  end
  local next_mode = modes[(cur_idx % #modes) + 1]
  state.rhythm_mode = next_mode

  if state.dim_ns and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, state.dim_ns, 0, -1)
  end

  local buf = state.buf

  if next_mode == "overview" then
    if state.saved_ui.laststatus then vim.o.laststatus = state.saved_ui.laststatus end
    if state.saved_ui.showtabline then vim.o.showtabline = state.saved_ui.showtabline end
    state.saved_ui = {}
    state.rhythm_queue = {}

    M.clear_rhythm_advance_map(buf)

    refresh()
    vim.api.nvim_echo({ { "  Rhythm: overview — scanning", "ModeMsg" } }, false, {})

  elseif next_mode == "focus" then
    state.saved_ui.laststatus = vim.o.laststatus
    state.saved_ui.showtabline = vim.o.showtabline
    vim.o.laststatus = 0
    vim.o.showtabline = 0

    state.rhythm_queue = M.build_rhythm_queue()
    state.rhythm_file_idx = 1

    if #state.rhythm_queue > 0 then
      local first = state.rhythm_queue[1]
      call_ctx("apply_dim_layer", first)
      local first_lnum = call_ctx("header_lnum_for_file", first)
      if first_lnum then
        vim.api.nvim_win_set_cursor(0, { first_lnum, 0 })
        vim.cmd("normal! zz")
      end
    end

    M.set_rhythm_advance_map(buf)

    refresh()
    vim.api.nvim_echo(
      { { "  Rhythm: focus — in flow  (" .. M.rhythm_advance_lhs() .. " next, s snooze)", "ModeMsg" } },
      false,
      {}
    )

  elseif next_mode == "sweep" then
    if state.saved_ui.laststatus then vim.o.laststatus = state.saved_ui.laststatus end
    if state.saved_ui.showtabline then vim.o.showtabline = state.saved_ui.showtabline end
    state.saved_ui = {}

    state.rhythm_queue = M.build_rhythm_queue()
    state.rhythm_file_idx = 1
    call_ctx("apply_sweep_dim")

    M.set_rhythm_advance_map(buf)

    refresh()
    vim.api.nvim_echo(
      { { "  Rhythm: sweep — wrapping up  (" .. M.rhythm_advance_lhs() .. " next unreviewed)", "ModeMsg" } },
      false,
      {}
    )
  end
end

return M
