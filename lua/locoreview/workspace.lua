-- workspace.lua
-- Manages the ephemeral diff review tabpage.
--
-- Architecture (per SKILL.md):
--   review.md         – durable source of truth (written by sync helpers below)
--   diff workspace    – a tabpage with two scratch buffers in diff mode
--
-- The workspace is disposable: it can be closed and rebuilt from review.md at
-- any time via M.refresh().

local M = {}

local diff_view = require("locoreview.diff_view")
local fs = require("locoreview.fs")
local git = require("locoreview.git")
local store = require("locoreview.store")
local ui = require("locoreview.ui")

-- Workspace-scoped state.  Reset on close.
local state = {
  tabpage = nil,
  left_buf = nil,
  right_buf = nil,
  item = nil,    -- current ReviewItem
  items = nil,   -- sorted list of items being reviewed
  item_index = nil,
  ns = nil,      -- extmark namespace (persists across sessions)
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function is_alive()
  return state.tabpage ~= nil and vim.api.nvim_tabpage_is_valid(state.tabpage)
end

local EXT_MAP = {
  lua = "lua", py = "python",
  ts = "typescript", tsx = "typescriptreact",
  js = "javascript", jsx = "javascriptreact",
  go = "go", rs = "rust", rb = "ruby",
  java = "java", c = "c", cpp = "cpp", h = "c",
  sh = "sh", yaml = "yaml", yml = "yaml",
  json = "json", md = "markdown",
}

local function filetype_for(file_path)
  if not file_path then return "" end
  local ext = file_path:match("%.([^.]+)$")
  return ext and (EXT_MAP[ext] or "") or ""
end

local function make_scratch(ft)
  local buf = vim.api.nvim_create_buf(false, true) -- unlisted, scratch
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  if ft and ft ~= "" then
    vim.api.nvim_buf_set_option(buf, "filetype", ft)
  end
  return buf
end

local function fill_buf(buf, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

-- ---------------------------------------------------------------------------
-- Review file I/O  (thin wrappers so workspace stays decoupled from paths)
-- ---------------------------------------------------------------------------

local function review_path()
  return fs.review_file_path()
end

local function load_items_from_disk()
  local path = review_path()
  if not path then return nil end
  local items, err = store.load(path)
  if not items then
    ui.notify(err, vim.log.levels.ERROR)
    return nil
  end
  return items
end

local function persist_items(items)
  local path = review_path()
  if not path then return false end
  local ok, err = store.save(path, items)
  if not ok then
    ui.notify(err, vim.log.levels.ERROR)
    return false
  end
  return true
end

local function refresh_global_views(items)
  local qf = require("locoreview.qf")
  local signs = require("locoreview.signs")
  qf.refresh()
  if signs.refresh then
    signs.refresh(items)
  end
end

-- ---------------------------------------------------------------------------
-- Sorting
-- ---------------------------------------------------------------------------

-- Build the sorted list of items shown in the workspace.
-- Prefers open/blocked; falls back to all items if none qualify.
local function sorted_items(items)
  local active = {}
  for _, it in ipairs(items) do
    if it.status == "open" or it.status == "blocked" then
      table.insert(active, it)
    end
  end
  local list = #active > 0 and active or vim.deepcopy(items)
  table.sort(list, function(a, b)
    if a.file ~= b.file then return a.file < b.file end
    return a.line < b.line
  end)
  return list
end

local function find_index(list, id)
  for i, it in ipairs(list) do
    if it.id == id then return i end
  end
  return 1
end

-- ---------------------------------------------------------------------------
-- Decoration (virtual text, not inline content)
-- ---------------------------------------------------------------------------

local function ensure_ns()
  if not state.ns then
    state.ns = vim.api.nvim_create_namespace("locoreview_workspace")
  end
end

local function decorate(item, payload)
  ensure_ns()
  vim.api.nvim_buf_clear_namespace(state.left_buf, state.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(state.right_buf, state.ns, 0, -1)

  if vim.api.nvim_buf_line_count(state.left_buf) == 0 then return end

  local loc = item.end_line
    and string.format("%s:%d-%d", item.file, item.line, item.end_line)
    or string.format("%s:%d", item.file, item.line)
  local header = string.format(" %s  %s  [%s][%s]", item.id, loc, item.severity, item.status)

  vim.api.nvim_buf_set_extmark(state.left_buf, state.ns, 0, 0, {
    virt_lines_above = true,
    virt_lines = {
      { { header, "Comment" } },
      { { " " .. item.issue, "DiagnosticVirtualTextWarn" } },
    },
  })

  local right_label = payload.has_suggestion and " suggested change" or " (no suggestion – showing context)"
  vim.api.nvim_buf_set_extmark(state.right_buf, state.ns, 0, 0, {
    virt_lines_above = true,
    virt_lines = {
      { { right_label, "Comment" } },
    },
  })
end

-- ---------------------------------------------------------------------------
-- Core render – populates buffers and enables diff mode
-- ---------------------------------------------------------------------------

local function render_current()
  local item = state.items[state.item_index]
  local payload, err = diff_view.build_payload(item)
  if not payload then
    ui.notify("ReviewOpenDiff: " .. (err or "failed to build diff payload"), vim.log.levels.ERROR)
    return false
  end

  local ft = filetype_for(item.file)
  vim.api.nvim_buf_set_option(state.left_buf, "filetype", ft)
  vim.api.nvim_buf_set_option(state.right_buf, "filetype", ft)

  fill_buf(state.left_buf, payload.left_lines)
  fill_buf(state.right_buf, payload.right_lines)

  state.item = item

  -- (Re-)enable diff mode on both windows
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if buf == state.left_buf or buf == state.right_buf then
      vim.api.nvim_win_call(win, function()
        vim.cmd("diffthis")
      end)
    end
  end
  vim.cmd("diffupdate")

  decorate(item, payload)
  return true
end

-- ---------------------------------------------------------------------------
-- Keymaps (buffer-local, self-contained workspace UX)
-- ---------------------------------------------------------------------------

local function attach_keymaps(bufs)
  local opts = { noremap = true, silent = true }
  for _, buf in ipairs(bufs) do
    local function bmap(lhs, fn)
      vim.keymap.set("n", lhs, fn, vim.tbl_extend("force", opts, { buffer = buf }))
    end

    bmap("q",   function() M.close() end)
    bmap("]r",  function() M.navigate(1) end)
    bmap("[r",  function() M.navigate(-1) end)
    bmap("go",  function() M.open_source() end)
    bmap("gr",  function() M.action_transition("fixed") end)
    bmap("gb",  function() M.action_transition("blocked") end)
    bmap("gw",  function() M.action_transition("wontfix") end)
    bmap("gd",  function() M.action_delete() end)
    bmap("ga",  function() M.action_apply() end)
    bmap("R",   function() M.refresh() end)
    bmap("?",   function() M.show_help() end)
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Open (or focus) the diff workspace for `item`, showing it in context of
-- the full `items` list for navigation.
function M.open(item, items)
  local list = sorted_items(items)
  if #list == 0 then
    ui.notify("no review items to display", vim.log.levels.INFO)
    return
  end

  local idx = find_index(list, item.id)

  -- Reuse an existing workspace if still alive
  if is_alive() then
    vim.api.nvim_set_current_tabpage(state.tabpage)
    state.items = list
    state.item_index = idx
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
      vim.api.nvim_win_call(win, function() vim.cmd("diffoff") end)
    end
    render_current()
    return
  end

  -- Fresh workspace
  state.items = list
  state.item_index = idx

  local ft = filetype_for(item.file)
  state.left_buf = make_scratch(ft)
  state.right_buf = make_scratch(ft)

  vim.cmd("tabnew")
  state.tabpage = vim.api.nvim_get_current_tabpage()

  -- Left window (current after tabnew)
  vim.api.nvim_win_set_buf(0, state.left_buf)
  -- Right window
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, state.right_buf)

  attach_keymaps({ state.left_buf, state.right_buf })
  render_current()

  -- Put cursor in the left window
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
    if vim.api.nvim_win_get_buf(win) == state.left_buf then
      vim.api.nvim_set_current_win(win)
      break
    end
  end
end

-- Navigate to the next (+1) or previous (-1) item in the sorted list.
function M.navigate(direction)
  if not is_alive() then
    ui.notify("no active review workspace", vim.log.levels.WARN)
    return
  end
  if not state.items or #state.items == 0 then return end

  state.item_index = ((state.item_index - 1 + direction) % #state.items) + 1

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
    vim.api.nvim_win_call(win, function() vim.cmd("diffoff") end)
  end
  render_current()
end

-- Jump to the source file at the review item's line in the previous tabpage.
function M.open_source()
  if not state.item then return end
  local root = git.repo_root()
  if not root then
    ui.notify("could not determine repository root", vim.log.levels.ERROR)
    return
  end
  local abs = root .. "/" .. state.item.file
  vim.cmd("tabprevious")
  vim.cmd("edit " .. vim.fn.fnameescape(abs))
  vim.api.nvim_win_set_cursor(0, { state.item.line, 0 })
end

-- Transition the current item to `new_status` and persist to review.md.
function M.action_transition(new_status)
  if not state.item then return end

  local items = load_items_from_disk()
  if not items then return end

  local next_items, err = store.transition(items, state.item.id, new_status)
  if not next_items then
    ui.notify(err, vim.log.levels.ERROR)
    return
  end
  if not persist_items(next_items) then return end
  refresh_global_views(next_items)
  ui.notify(string.format("%s -> %s", state.item.id, new_status), vim.log.levels.INFO)

  -- Update in-memory copy so decorations reflect the new status
  for _, it in ipairs(next_items) do
    if it.id == state.item.id then
      state.item = it
      state.items[state.item_index] = it
      break
    end
  end

  local payload = diff_view.build_payload(state.item)
  if payload then decorate(state.item, payload) end
end

-- Delete the current item (with confirmation) and advance to the next.
function M.action_delete()
  if not state.item then return end
  local target_id = state.item.id

  ui.prompt_confirm("Delete " .. target_id .. "?", function(confirmed)
    if not confirmed then return end

    local items = load_items_from_disk()
    if not items then return end

    local next_items, err = store.delete(items, target_id)
    if not next_items then
      ui.notify(err, vim.log.levels.ERROR)
      return
    end
    if not persist_items(next_items) then return end
    refresh_global_views(next_items)
    ui.notify("deleted " .. target_id, vim.log.levels.INFO)

    table.remove(state.items, state.item_index)
    if #state.items == 0 then
      M.close()
      return
    end
    state.item_index = math.min(state.item_index, #state.items)

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
      vim.api.nvim_win_call(win, function() vim.cmd("diffoff") end)
    end
    render_current()
  end)
end

-- Write the suggested change to the source file and mark the item fixed.
-- Requires item.requested_change to be non-empty.
function M.action_apply()
  if not state.item then return end
  if not state.item.requested_change or state.item.requested_change == "" then
    ui.notify("no suggested change to apply", vim.log.levels.WARN)
    return
  end

  local target = state.item
  ui.prompt_confirm(
    string.format("Apply suggestion to %s:%d?", target.file, target.line),
    function(confirmed)
      if not confirmed then return end

      local root = git.repo_root()
      if not root then
        ui.notify("could not determine repository root", vim.log.levels.ERROR)
        return
      end

      local source_path = root .. "/" .. target.file
      local content = fs.read(source_path)
      if not content then
        ui.notify("could not read " .. target.file, vim.log.levels.ERROR)
        return
      end

      local file_lines = vim.split(content, "\n", { plain = true })
      if file_lines[#file_lines] == "" then table.remove(file_lines) end

      local end_line = target.end_line or target.line
      local suggestion = vim.split(target.requested_change, "\n", { plain = true })

      local new_lines = {}
      for i = 1, target.line - 1 do
        table.insert(new_lines, file_lines[i] or "")
      end
      for _, l in ipairs(suggestion) do
        table.insert(new_lines, l)
      end
      for i = end_line + 1, #file_lines do
        table.insert(new_lines, file_lines[i] or "")
      end

      if not fs.write(source_path, table.concat(new_lines, "\n") .. "\n") then
        ui.notify("failed to write " .. target.file, vim.log.levels.ERROR)
        return
      end

      -- Reload the buffer if open
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == source_path then
          vim.api.nvim_buf_call(buf, function() vim.cmd("edit") end)
          break
        end
      end

      ui.notify("applied suggestion to " .. target.file, vim.log.levels.INFO)
      M.action_transition("fixed")
    end
  )
end

-- Reload items from review.md and re-render the workspace.
function M.refresh()
  if not is_alive() then
    ui.notify("no active review workspace", vim.log.levels.WARN)
    return
  end

  local items = load_items_from_disk()
  if not items then return end

  local current_id = state.item and state.item.id
  local list = sorted_items(items)
  if #list == 0 then
    M.close()
    ui.notify("no review items remaining", vim.log.levels.INFO)
    return
  end

  state.items = list
  state.item_index = current_id and find_index(list, current_id) or 1

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
    vim.api.nvim_win_call(win, function() vim.cmd("diffoff") end)
  end
  render_current()
  ui.notify("workspace refreshed", vim.log.levels.INFO)
end

-- Close the workspace tab and reset state.
function M.close()
  if is_alive() then
    local ok = pcall(function()
      vim.api.nvim_set_current_tabpage(state.tabpage)
      vim.cmd("tabclose")
    end)
    if not ok then
      pcall(function() vim.api.nvim_buf_delete(state.left_buf, { force = true }) end)
      pcall(function() vim.api.nvim_buf_delete(state.right_buf, { force = true }) end)
    end
  end
  state.tabpage = nil
  state.left_buf = nil
  state.right_buf = nil
  state.item = nil
  state.items = nil
  state.item_index = nil
end

-- Show a brief keymap reference in a notification.
function M.show_help()
  local lines = {
    "locoreview workspace keymaps",
    "  ]r / [r  next / previous comment",
    "  go       open source at review line",
    "  gr       mark fixed",
    "  gb       mark blocked",
    "  gw       mark wontfix",
    "  gd       delete comment",
    "  ga       apply suggestion to source",
    "  R        refresh from review.md",
    "  q        close workspace",
    "  ?        this help",
  }
  ui.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
