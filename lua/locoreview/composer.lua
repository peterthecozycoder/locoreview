local M = {}

local ui = require("locoreview.ui")
local util = require("locoreview.util")
local CHANGE_HEADER = "## Requested change (optional)"
local severities = { "low", "medium", "high" }
local next_status = { open = "fixed", fixed = "blocked", blocked = "wontfix", wontfix = "open" }

function M.open(item, on_submit)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  local lines = vim.split(item.issue or "", "\n", { plain = true })
  vim.list_extend(lines, { "", CHANGE_HEADER, "" })
  vim.list_extend(lines, vim.split(item.requested_change or "", "\n", { plain = true }))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local severity = item.severity or "medium"
  local status = item.id and item.status or nil
  local width = math.max(1, math.min(80, vim.o.columns - 4))
  local height = math.max(1, math.min(16, vim.o.lines - 6))
  local function title()
    return string.format(" %s:%s · %s priority%s ", item.file, item.line, severity, status and " · " .. status or "")
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = "rounded",
    width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    title = title(), title_pos = "center",
    footer = " Ctrl-S save · Ctrl-G priority" .. (status and " · Ctrl-T status" or "") .. " · Ctrl-C cancel ", footer_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  local function close()
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  local function submit()
    local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local issue, change = {}, {}
    local target = issue
    for _, line in ipairs(content) do
      if line == CHANGE_HEADER then
        target = change
      else
        table.insert(target, line)
      end
    end
    local fields = {
      issue = util.trim(table.concat(issue, "\n")),
      requested_change = util.trim(table.concat(change, "\n")),
      severity = severity,
      status = status,
    }
    if fields.issue == "" then
      ui.notify("write a comment before saving", vim.log.levels.WARN)
      return
    end
    if on_submit(fields) then close() end
  end
  local opts = { buffer = buf, silent = true }
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, opts)
  vim.keymap.set({ "n", "i" }, "<C-c>", close, opts)
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set({ "n", "i" }, "<C-g>", function()
    for i, value in ipairs(severities) do
      if value == severity then
        severity = severities[i % #severities + 1]
        break
      end
    end
    vim.api.nvim_win_set_config(win, { title = title() })
  end, opts)
  if status then
    vim.keymap.set({ "n", "i" }, "<C-t>", function()
      status = next_status[status]
      vim.api.nvim_win_set_config(win, { title = title() })
    end, opts)
  end
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd("startinsert")
  return buf, win
end

return M
