local M = {}

local config = require("locoreview.config")
local fs = require("locoreview.fs")
local git = require("locoreview.git")
local qf = require("locoreview.qf")
local store = require("locoreview.store")
local signs = require("locoreview.signs")
local ui = require("locoreview.ui")
local diffview = require("locoreview.diffview")
local picker = require("locoreview.picker")
local agent = require("locoreview.agent")

local registered = false
local REVIEW_FILE_INITIAL_CONTENT = "# Review Comments\n\n"
local ERR_REVIEW_PATH = "unable to resolve review file path"

local function refresh_views(items)
  qf.refresh()
  if signs.refresh then
    signs.refresh(items)
  end
end

local function review_path_or_notify()
  local path = fs.review_file_path()
  if path then
    return path
  end
  ui.notify(ERR_REVIEW_PATH, vim.log.levels.ERROR)
  return nil
end

local function path_for_buffer()
  local abs = vim.api.nvim_buf_get_name(0)
  if abs == "" then
    return nil, nil, "current buffer has no file path"
  end

  local root = git.repo_root()
  if vim.startswith(abs, root .. "/") then
    return abs:sub(#root + 2), abs
  end

  return vim.fn.fnamemodify(abs, ":."), abs
end

local function load_items(path)
  local items, err = store.load(path)
  if not items then
    ui.notify(err, vim.log.levels.ERROR)
    return nil
  end
  return items
end

local function save_items(path, items)
  local ok, err = store.save(path, items)
  if not ok then
    ui.notify(err, vim.log.levels.ERROR)
    return false
  end
  return true
end

local function item_matches_location(item, rel_file, line)
  if item.file ~= rel_file then
    return false
  end
  if item.end_line then
    return line >= item.line and line <= item.end_line
  end
  return item.line == line
end

local function find_item(items, rel_file, line, status_pred)
  local lnum = tonumber(line) or 0
  for _, item in ipairs(items) do
    if (not status_pred or status_pred(item.status)) and item_matches_location(item, rel_file, lnum) then
      return item
    end
  end
end

local function sort_open_items(items)
  local open = {}
  for _, item in ipairs(items) do
    if item.status == "open" then
      table.insert(open, item)
    end
  end

  table.sort(open, function(a, b)
    if a.file == b.file then
      return a.line < b.line
    end
    return a.file < b.file
  end)
  return open
end

local function jump_to_item(item)
  local root = git.repo_root()
  local abs = root .. "/" .. item.file
  vim.cmd("edit " .. vim.fn.fnameescape(abs))
  vim.api.nvim_win_set_cursor(0, { item.line, 0 })
end

local function command_open()
  local path = review_path_or_notify()
  if not path then
    return
  end

  if not fs.ensure_file(path, REVIEW_FILE_INITIAL_CONTENT) then
    ui.notify("failed to create review file", vim.log.levels.ERROR)
    return
  end

  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

local function perform_add(start_line, end_line, rel_file)
  local cfg = config.get()
  if not rel_file then
    local path_err
    rel_file, _, path_err = path_for_buffer()
    if not rel_file then
      ui.notify(path_err, vim.log.levels.ERROR)
      return
    end
  end

  local review_path = review_path_or_notify()
  if not review_path then
    return
  end
  fs.ensure_file(review_path, REVIEW_FILE_INITIAL_CONTENT)

  ui.prompt_issue(function(issue)
    if issue == nil then
      return
    end
    ui.prompt_requested_change(function(requested_change)
      if requested_change == nil then
        return
      end
      ui.prompt_severity(cfg.default_severity, function(severity)
        if severity == nil then
          return
        end

        local items = load_items(review_path)
        if not items then
          return
        end

        local next_items, inserted_or_err = store.insert(items, {
          file = rel_file,
          line = start_line,
          end_line = end_line,
          severity = severity,
          status = "open",
          issue = issue,
          requested_change = requested_change,
          author = cfg.default_author,
        })
        if not next_items then
          ui.notify(inserted_or_err, vim.log.levels.ERROR)
          return
        end

        if not save_items(review_path, next_items) then
          return
        end

        refresh_views(next_items)
        ui.notify("added review item " .. inserted_or_err.id, vim.log.levels.INFO)
      end)
    end)
  end)
end

local function ensure_diff_line(file, line)
  local cfg = config.get()
  local base = git.base_branch(cfg)
  if not git.is_line_changed(file, line, base) then
    ui.notify("current line is not changed from base diff", vim.log.levels.ERROR)
    return false
  end
  return true
end

local function ensure_diff_range(file, start_line, end_line)
  local cfg = config.get()
  local base = git.base_branch(cfg)
  local ranges = git.changed_lines(file, base)
  for line = start_line, end_line do
    local lnum = tonumber(line) or 0
    local changed = false
    for _, r in ipairs(ranges) do
      if lnum >= r.start and lnum <= r["end"] then
        changed = true
        break
      end
    end
    if not changed then
      ui.notify("visual selection contains unchanged lines from base diff", vim.log.levels.ERROR)
      return false
    end
  end
  return true
end

local function command_add()
  local rel_file, _, err = path_for_buffer()
  if not rel_file then
    ui.notify(err, vim.log.levels.ERROR)
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local cfg = config.get()
  if cfg.diff_only and not ensure_diff_line(rel_file, line) then
    return
  end
  perform_add(line, nil, rel_file)
end

local function command_add_range()
  local rel_file, _, err = path_for_buffer()
  if not rel_file then
    ui.notify(err, vim.log.levels.ERROR)
    return
  end

  local start_line = vim.fn.getpos("'<")[2]
  local end_line = vim.fn.getpos("'>")[2]
  if start_line == 0 or end_line == 0 then
    ui.notify("visual selection not found", vim.log.levels.ERROR)
    return
  end
  if end_line < start_line then
    start_line, end_line = end_line, start_line
  end
  local cfg = config.get()
  if cfg.diff_only and not ensure_diff_range(rel_file, start_line, end_line) then
    return
  end
  perform_add(start_line, end_line, rel_file)
end

local function command_add_diff()
  local rel_file, _, err = path_for_buffer()
  if not rel_file then
    ui.notify(err, vim.log.levels.ERROR)
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if not ensure_diff_line(rel_file, line) then
    return
  end
  perform_add(line, nil, rel_file)
end

local function command_list()
  local path = review_path_or_notify()
  if not path then
    return
  end
  fs.ensure_file(path, REVIEW_FILE_INITIAL_CONTENT)

  local items = load_items(path)
  if not items then
    return
  end

  qf.populate(items, function(item)
    return item.status == "open"
  end)
  vim.cmd("copen")
end

local function parse_list_all_args(arg_string)
  local out = {}
  for token in tostring(arg_string or ""):gmatch("%S+") do
    local key, value = token:match("^(%w+)=([^=]+)$")
    if key and value then
      out[key] = value
    end
  end
  return out
end

local function command_list_all(opts)
  local path = review_path_or_notify()
  if not path then
    return
  end
  fs.ensure_file(path, REVIEW_FILE_INITIAL_CONTENT)

  local items = load_items(path)
  if not items then
    return
  end

  local filters = parse_list_all_args(opts.args)
  qf.populate(items, function(item)
    if filters.status and item.status ~= filters.status then
      return false
    end
    if filters.severity and item.severity ~= filters.severity then
      return false
    end
    if filters.file and item.file ~= filters.file then
      return false
    end
    return true
  end)
  vim.cmd("copen")
end

local function jump_relative(direction)
  local rel_file, _, err = path_for_buffer()
  if not rel_file then
    ui.notify(err, vim.log.levels.ERROR)
    return
  end

  local path = review_path_or_notify()
  if not path then
    return
  end

  local items = load_items(path)
  if not items then
    return
  end
  local open_items = sort_open_items(items)
  if #open_items == 0 then
    ui.notify("no open review items", vim.log.levels.INFO)
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  if direction > 0 then
    for _, item in ipairs(open_items) do
      if item.file > rel_file or (item.file == rel_file and item.line > line) then
        jump_to_item(item)
        return
      end
    end
    jump_to_item(open_items[1])
    return
  end

  for i = #open_items, 1, -1 do
    local item = open_items[i]
    if item.file < rel_file or (item.file == rel_file and item.line < line) then
      jump_to_item(item)
      return
    end
  end
  jump_to_item(open_items[#open_items])
end

local function transition_item(new_status)
  local rel_file, _, err = path_for_buffer()
  if not rel_file then
    ui.notify(err, vim.log.levels.ERROR)
    return
  end

  local path = review_path_or_notify()
  if not path then
    return
  end

  local items = load_items(path)
  if not items then
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local target
  if new_status == "open" then
    target = find_item(items, rel_file, line, function(s) return s ~= "open" end)
  else
    target = find_item(items, rel_file, line, function(s) return s == "open" end)
  end
  if not target then
    ui.notify("review item not found at current location", vim.log.levels.ERROR)
    return
  end

  local next_items, transition_err = store.transition(items, target.id, new_status)
  if not next_items then
    ui.notify(transition_err, vim.log.levels.ERROR)
    return
  end

  if not save_items(path, next_items) then
    return
  end
  refresh_views(next_items)
  ui.notify(string.format("%s -> %s", target.id, new_status), vim.log.levels.INFO)
end

local function command_edit()
  local rel_file, _, err = path_for_buffer()
  if not rel_file then
    ui.notify(err, vim.log.levels.ERROR)
    return
  end

  local path = review_path_or_notify()
  if not path then
    return
  end
  local items = load_items(path)
  if not items then
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local target = find_item(items, rel_file, line)
  if not target then
    ui.notify("review item not found at current location", vim.log.levels.ERROR)
    return
  end

  ui.prompt_issue(function(issue)
    if issue == nil then
      return
    end
    ui.prompt_requested_change(function(requested_change)
      if requested_change == nil then
        return
      end
      ui.prompt_severity(target.severity, function(severity)
        if severity == nil then
          return
        end

        local next_items, update_err = store.update(items, target.id, {
          issue = issue,
          requested_change = requested_change,
          severity = severity,
        })
        if not next_items then
          ui.notify(update_err, vim.log.levels.ERROR)
          return
        end
        if not save_items(path, next_items) then
          return
        end
        refresh_views(next_items)
        ui.notify("updated " .. target.id, vim.log.levels.INFO)
      end)
    end, target.requested_change)
  end, target.issue)
end

local function command_delete()
  local rel_file, _, err = path_for_buffer()
  if not rel_file then
    ui.notify(err, vim.log.levels.ERROR)
    return
  end

  local path = review_path_or_notify()
  if not path then
    return
  end
  local items = load_items(path)
  if not items then
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local target = find_item(items, rel_file, line)
  if not target then
    ui.notify("review item not found at current location", vim.log.levels.ERROR)
    return
  end

  ui.prompt_confirm("Delete?", function(confirmed)
    if not confirmed then
      return
    end
    local next_items, delete_err = store.delete(items, target.id)
    if not next_items then
      ui.notify(delete_err, vim.log.levels.ERROR)
      return
    end
    if not save_items(path, next_items) then
      return
    end
    refresh_views(next_items)
    ui.notify("deleted " .. target.id, vim.log.levels.INFO)
  end)
end

local function command_clean()
  local path = review_path_or_notify()
  if not path then
    return
  end

  local items = load_items(path)
  if not items then
    return
  end

  local next_items = {}
  local removed = 0
  for _, item in ipairs(items) do
    if item.status == "fixed" then
      removed = removed + 1
    else
      table.insert(next_items, item)
    end
  end

  if removed == 0 then
    ui.notify("no fixed review items to clean", vim.log.levels.INFO)
    return
  end

  if not save_items(path, next_items) then
    return
  end
  refresh_views(next_items)
  ui.notify(string.format("removed %d fixed item%s", removed, removed == 1 and "" or "s"), vim.log.levels.INFO)
end

local function command_refresh()
  local path = review_path_or_notify()
  if not path then
    return
  end

  local items = load_items(path)
  if not items then
    return
  end

  refresh_views(items)
  ui.notify("refresh complete", vim.log.levels.INFO)
end

local function ensure_diffview_enabled(cfg)
  if cfg.diffview and cfg.diffview.enabled == false then
    ui.notify("diffview integration is disabled", vim.log.levels.ERROR)
    return false
  end
  if not diffview.is_available() then
    ui.notify("diffview.nvim is not available", vim.log.levels.ERROR)
    return false
  end
  return true
end

local function command_diff()
  local cfg = config.get()
  if not ensure_diffview_enabled(cfg) then
    return
  end

  local base = git.base_branch(cfg)
  diffview.open_diff(base)
end

local function command_file_history()
  local cfg = config.get()
  if not ensure_diffview_enabled(cfg) then
    return
  end

  diffview.open_file_history()
end

local function command_picker()
  local path = review_path_or_notify()
  if not path then
    return
  end

  local items = load_items(path)
  if not items then
    return
  end

  picker.open(items)
end

local function command_fix()
  local cfg = config.get()
  if cfg.agent and cfg.agent.enabled == false then
    ui.notify("agent integration is disabled", vim.log.levels.INFO)
    return
  end

  local path = review_path_or_notify()
  if not path then
    return
  end
  local items = load_items(path)
  if not items then
    return
  end

  local ok = agent.run(items, git.repo_root(), path, cfg.agent or {})
  if cfg.agent and cfg.agent.open_in_split == false then
    if ok then
      ui.notify("agent command completed", vim.log.levels.INFO)
    else
      ui.notify("agent command failed", vim.log.levels.ERROR)
    end
  end
end

function M.register()
  if registered then
    return
  end

  vim.api.nvim_create_user_command("ReviewOpen", command_open, {})
  vim.api.nvim_create_user_command("ReviewAdd", command_add, {})
  vim.api.nvim_create_user_command("ReviewAddRange", command_add_range, { range = true })
  vim.api.nvim_create_user_command("ReviewAddDiff", command_add_diff, {})
  vim.api.nvim_create_user_command("ReviewList", command_list, {})
  vim.api.nvim_create_user_command("ReviewListAll", command_list_all, { nargs = "*" })
  vim.api.nvim_create_user_command("ReviewNext", function()
    jump_relative(1)
  end, {})
  vim.api.nvim_create_user_command("ReviewPrev", function()
    jump_relative(-1)
  end, {})
  vim.api.nvim_create_user_command("ReviewMarkFixed", function()
    transition_item("fixed")
  end, {})
  vim.api.nvim_create_user_command("ReviewReopen", function()
    transition_item("open")
  end, {})
  vim.api.nvim_create_user_command("ReviewMarkBlocked", function()
    transition_item("blocked")
  end, {})
  vim.api.nvim_create_user_command("ReviewMarkWontfix", function()
    transition_item("wontfix")
  end, {})
  vim.api.nvim_create_user_command("ReviewEdit", command_edit, {})
  vim.api.nvim_create_user_command("ReviewDelete", command_delete, {})
  vim.api.nvim_create_user_command("ReviewClean", command_clean, {})
  vim.api.nvim_create_user_command("ReviewToggleSigns", function()
    if not signs.toggle then
      ui.notify("signs module unavailable", vim.log.levels.ERROR)
      return
    end
    local state = signs.toggle()
    ui.notify("signs " .. (state and "enabled" or "disabled"), vim.log.levels.INFO)
  end, {})
  vim.api.nvim_create_user_command("ReviewRefresh", command_refresh, {})
  vim.api.nvim_create_user_command("ReviewDiff", command_diff, {})
  vim.api.nvim_create_user_command("ReviewFileHistory", command_file_history, {})
  vim.api.nvim_create_user_command("ReviewPicker", command_picker, {})
  vim.api.nvim_create_user_command("ReviewFix", command_fix, {})

  registered = true
end

return M
