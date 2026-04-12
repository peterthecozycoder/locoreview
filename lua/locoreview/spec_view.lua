-- spec_view.lua
-- UI layer for spec review: floating summary and item detail windows.
-- All business logic is delegated to spec_session.

local M = {}

local spec_session = require("locoreview.spec_session")
local ui           = require("locoreview.ui")

-- ── Floating window helper ────────────────────────────────────────────────────

local function make_float(lines, title)
  local width = title and (#title + 4) or 40
  for _, l in ipairs(lines) do
    width = math.max(width, #l + 4)
  end
  width = math.min(width, math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines, math.floor(vim.o.lines * 0.8))

  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

  local win_opts = {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
  }
  -- title requires Neovim ≥ 0.9
  if title and vim.fn.has("nvim-0.9") == 1 then
    win_opts.title     = " " .. title .. " "
    win_opts.title_pos = "center"
  end

  local win = vim.api.nvim_open_win(buf, true, win_opts)

  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local opts = { buffer = buf, noremap = true, silent = true, nowait = true }
  for _, key in ipairs({ "q", "<Esc>", "<CR>" }) do
    vim.keymap.set("n", key, close, opts)
  end

  return buf, win
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- summary() — open a floating progress summary window.
function M.summary()
  if not spec_session.is_open() then
    ui.notify("no active spec review session", vim.log.levels.INFO)
    return
  end

  local s = spec_session.summary()
  local lines = {}

  table.insert(lines, string.format("  Total: %d", s.total))
  table.insert(lines, "")
  table.insert(lines, string.format("  Reviewed  : %d", s.by_status.reviewed or 0))
  table.insert(lines, string.format("  Unreviewed: %d", s.by_status.unreviewed or 0))
  table.insert(lines, string.format("  Unclear   : %d", s.by_status.unclear or 0))
  table.insert(lines, string.format("  Blocked   : %d", s.by_status.blocked or 0))

  if s.review_debt > 0 then
    table.insert(lines, "")
    table.insert(lines, string.format("  Review debt (unclear + blocked): %d", s.review_debt))
  end

  if next(s.by_type) then
    table.insert(lines, "")
    table.insert(lines, "  By type:")
    local type_keys = {}
    for t in pairs(s.by_type) do
      table.insert(type_keys, t)
    end
    table.sort(type_keys)
    for _, t in ipairs(type_keys) do
      local tc = s.by_type[t]
      local total_t = (tc.reviewed or 0) + (tc.unreviewed or 0) + (tc.unclear or 0) + (tc.blocked or 0)
      table.insert(lines, string.format(
        "    %s  total=%-3d  reviewed=%-3d  unclear=%-3d  blocked=%-3d",
        t, total_t, tc.reviewed or 0, tc.unclear or 0, tc.blocked or 0
      ))
    end
  end

  if #s.unclear_items > 0 then
    table.insert(lines, "")
    table.insert(lines, "  Unresolved questions:")
    for _, item in ipairs(s.unclear_items) do
      table.insert(lines, string.format("    %s: %s", item.id, item.text:sub(1, 60)))
    end
  end

  table.insert(lines, "")
  table.insert(lines, "  q / <Esc> / <CR>  close")

  make_float(lines, "Spec Review Summary")
end

-- show_item(item, state) — open a floating detail panel for one spec item.
function M.show_item(item, state)
  if not item then
    ui.notify("no current spec item", vim.log.levels.INFO)
    return
  end

  local s = state or {}
  local lines = {}

  table.insert(lines, string.format("  %s  [%s]  %s", item.id, s.status or "unreviewed", item.section))
  table.insert(lines, string.format("  Type: %s    Line: %d", item.type, item.line_start))
  table.insert(lines, "")
  table.insert(lines, "  Text:")
  for _, l in ipairs(vim.split(item.text or "", "\n", { plain = true })) do
    table.insert(lines, "    " .. l)
  end

  if s.note and s.note ~= "" then
    table.insert(lines, "")
    table.insert(lines, "  Note:")
    for _, l in ipairs(vim.split(s.note, "\n", { plain = true })) do
      table.insert(lines, "    " .. l)
    end
  end

  table.insert(lines, "")
  table.insert(lines, "  q / <Esc> / <CR>  close")

  make_float(lines, "Spec Item: " .. item.id)
end

return M
