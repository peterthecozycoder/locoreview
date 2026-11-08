-- A focused, read-only comment browser. Actions always use the selected ID.
local M = {}
local fs = require("locoreview.fs")
local store = require("locoreview.store")
local ui = require("locoreview.ui")
local severity_next = { low = "medium", medium = "high", high = "low" }

function M.open(path, location)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  local width = math.max(1, math.min(96, vim.o.columns - 4))
  local height = math.max(1, math.min(26, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = "rounded",
    width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    title = " Review comments ", title_pos = "center",
    footer = " e edit · f resolve/reopen · Ctrl-G priority · ? help · q close ", footer_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].cursorline = true
  local all = location ~= nil
  local rows, starts, visible = {}, {}, {}

  local function selected()
    if vim.api.nvim_win_is_valid(win) then return rows[vim.api.nvim_win_get_cursor(win)[1]] end
  end
  local function matches(item)
    if not all and item.status ~= "open" then return false end
    return not location or (item.file == location.file and (item.line_ref or "new") == location.side
      and location.line >= item.line and location.line <= (item.end_line or item.line))
  end
  local function load()
    if not fs.exists(path) then return {} end
    local items, err = store.load(path)
    if not items then ui.notify(err, vim.log.levels.ERROR) end
    return items
  end
  local function render(items)
    if not vim.api.nvim_win_is_valid(win) then return end
    local current = selected()
    local cursor = vim.api.nvim_win_get_cursor(win)[1]
    rows, starts, visible = {}, {}, {}
    local lines = {}
    for _, item in ipairs(items) do
      if matches(item) then
        table.insert(visible, item)
        local first = #lines + 1
        table.insert(starts, first)
        if current and current.id == item.id then cursor = first end
        local range = tostring(item.line) .. (item.end_line and "–" .. item.end_line or "")
        table.insert(lines, string.format("## %s · %s:%s%s", item.id, item.file, range,
          item.line_ref == "old" and " (removed)" or ""))
        table.insert(lines, string.format("%s · %s priority", item.status, item.severity))
        table.insert(lines, "")
        vim.list_extend(lines, vim.split(item.issue, "\n", { plain = true }))
        if item.requested_change ~= "" then
          vim.list_extend(lines, { "", "Requested change:" })
          vim.list_extend(lines, vim.split(item.requested_change, "\n", { plain = true }))
        end
        table.insert(lines, "")
        for row = first, #lines do rows[row] = item end
      end
    end
    if #lines == 0 then lines = { "No " .. (all and "" or "open ") .. "comments. Press a to toggle open/all, or q to close." } end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    local scope = location and string.format("%s:%d", location.file, location.line) or "repository"
    vim.api.nvim_win_set_config(win, { title = string.format(" %s · %s · %d comment%s ", scope, all and "all" or "open", #visible, #visible == 1 and "" or "s") })
    vim.api.nvim_win_set_cursor(win, { math.min(cursor, #lines), 0 })
  end
  local function refresh()
    local items = load()
    if items then
      render(items)
      require("locoreview.commands").refresh(items)
    end
  end
  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  -- Reload for every mutation, including after an editor or confirmation dialog.
  local function mutate(id, operation, value)
    local items = load()
    if not items then return false end
    local next_items, err = operation(items, id, value)
    if not next_items then ui.notify(err, vim.log.levels.ERROR); return false end
    local ok, save_err = store.save(path, next_items)
    if not ok then ui.notify(save_err, vim.log.levels.ERROR); return false end
    render(next_items)
    require("locoreview.commands").refresh(next_items)
    return true
  end
  local function map(key, callback, desc)
    vim.keymap.set("n", key, callback, { buffer = buf, silent = true, desc = desc })
  end
  local function on_item(key, callback, desc)
    map(key, function()
      local item = selected()
      if item then callback(item) end
    end, desc)
  end
  on_item("e", function(item)
    ui.edit_comment(item, function(fields) return mutate(item.id, store.update, fields) end)
  end, "Edit comment, priority and status")
  on_item("f", function(item)
    mutate(item.id, store.transition, item.status == "open" and "fixed" or "open")
  end, "Resolve or reopen comment")
  on_item("<C-g>", function(item)
    mutate(item.id, store.update, { severity = severity_next[item.severity] })
  end, "Cycle priority")
  on_item("d", function(item)
    ui.prompt_confirm("Delete " .. item.id .. "?", function(confirmed)
      if confirmed then mutate(item.id, store.delete) end
    end)
  end, "Delete comment")
  on_item("<CR>", function(item)
    if item.line_ref == "old" then
      ui.notify("removed lines exist only in the base revision; use the diff view")
      return
    end
    local root = require("locoreview.git").repo_root()
    if not root then return end
    close()
    if vim.bo.buftype ~= "" then vim.cmd("tabnew") end
    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. item.file))
    vim.api.nvim_win_set_cursor(0, { math.min(item.line, vim.api.nvim_buf_line_count(0)), 0 })
  end, "Go to source")
  local function jump(direction)
    local item = selected()
    for i, first in ipairs(starts) do
      if rows[first] == item then
        vim.api.nvim_win_set_cursor(win, { starts[(i - 1 + direction) % #starts + 1], 0 })
        return
      end
    end
  end
  map("]c", function() jump(1) end, "Next comment")
  map("[c", function() jump(-1) end, "Previous comment")
  map("a", function() all = not all; refresh() end, "Toggle open/all comments")
  map("R", refresh, "Refresh review")
  map("O", function()
    if not fs.ensure_file(path, "# Review Comments\n\n") then
      ui.notify("failed to create review file", vim.log.levels.ERROR)
      return
    end
    close()
    if vim.bo.buftype ~= "" then vim.cmd("tabnew") end
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end, "Open review Markdown")
  map("Q", function()
    -- Capture this view's filters so later quickfix refreshes use the same scope.
    local included = {}
    for _, item in ipairs(visible) do included[item.id] = true end
    require("locoreview.qf").populate(visible, function(item) return included[item.id] == true end)
    close()
    vim.cmd("copen")
  end, "Send visible comments to quickfix")
  map("p", function()
    local items = visible
    close()
    require("locoreview.picker").open(items)
  end, "Pick a visible comment")
  map("S", function()
    local enabled = require("locoreview.signs").toggle()
    ui.notify("signs " .. (enabled and "enabled" or "disabled"))
  end, "Toggle signs")
  map("?", function()
    ui.notify("e edit · f resolve/reopen · Ctrl-G priority · d delete · Enter source · ]c/[c navigate · / search\n"
      .. "a open/all · R refresh · O Markdown · Q quickfix · p picker · S signs · q close")
  end, "Comment view help")
  map("q", close, "Close comments")
  map("<Esc>", close, "Close comments")
  local items = load()
  if not items then close(); return end
  render(items)
  return buf, win
end

return M
