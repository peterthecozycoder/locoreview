local M = {}

local config = require("locoreview.config")
local git = require("locoreview.git")
local ui = require("locoreview.ui")
local util = require("locoreview.util")
local AUTO_BACKENDS = { "telescope", "fzf_lua", "snacks" }

local function to_entries(items)
  local entries = {}
  for _, item in ipairs(items or {}) do
    table.insert(entries, {
      value = item,
      text = string.format("%s %s:%d [%s][%s] %s", item.id, item.file, item.line, item.severity, item.status, util.truncate(item.issue, 70)),
    })
  end
  return entries
end

local function jump_to(item)
  local root = git.repo_root()
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. item.file))
  vim.api.nvim_win_set_cursor(0, { item.line, 0 })
end

local function open_select(entries)
  if not vim.ui or not vim.ui.select then
    ui.notify("no picker backend available", vim.log.levels.ERROR)
    return false
  end
  vim.ui.select(entries, {
    prompt = "Review items",
    format_item = function(entry)
      return entry.text
    end,
  }, function(choice)
    if choice then
      jump_to(choice.value)
    end
  end)
  return true
end

local function open_telescope(entries)
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  if not ok_pickers then
    return false
  end
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = "Review items",
    finder = finders.new_table({
      results = entries,
      entry_maker = function(entry)
        return {
          value = entry.value,
          display = entry.text,
          ordinal = entry.text,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(bufnr, _)
      actions.select_default:replace(function()
        local selected = action_state.get_selected_entry()
        actions.close(bufnr)
        if selected and selected.value then
          jump_to(selected.value)
        end
      end)
      return true
    end,
  }):find()
  return true
end

local function open_fzf_lua(entries)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    return false
  end
  local lines = {}
  local lookup = {}
  for _, entry in ipairs(entries) do
    table.insert(lines, entry.text)
    lookup[entry.text] = entry.value
  end

  fzf.fzf_exec(lines, {
    prompt = "Review> ",
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] and lookup[selected[1]] then
          jump_to(lookup[selected[1]])
        end
      end,
    },
  })
  return true
end

local function open_snacks(entries)
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.picker then
    return false
  end
  snacks.picker.pick({
    title = "Review items",
    items = entries,
    format = function(entry)
      return { entry.text }
    end,
    confirm = function(_, entry)
      if entry and entry.value then
        jump_to(entry.value)
      end
    end,
  })
  return true
end

function M.open(items)
  local cfg = config.get()
  if cfg.picker and cfg.picker.enabled == false then
    ui.notify("picker integration is disabled", vim.log.levels.INFO)
    return false
  end

  local entries = to_entries(items)
  if #entries == 0 then
    ui.notify("no review items found", vim.log.levels.INFO)
    return false
  end

  local backend = (cfg.picker and cfg.picker.backend) or "auto"
  if backend == "none" then
    ui.notify("picker backend disabled", vim.log.levels.INFO)
    return false
  end

  local backends = {
    telescope = {
      open = open_telescope,
      unavailable = "telescope backend unavailable",
    },
    fzf_lua = {
      open = open_fzf_lua,
      unavailable = "fzf-lua backend unavailable",
    },
    snacks = {
      open = open_snacks,
      unavailable = "snacks backend unavailable",
    },
  }

  if backend == "auto" then
    for _, name in ipairs(AUTO_BACKENDS) do
      if backends[name].open(entries) then
        return true
      end
    end
    return open_select(entries)
  end

  local selected = backends[backend]
  if selected then
    if selected.open(entries) then
      return true
    end
    ui.notify(selected.unavailable, vim.log.levels.ERROR)
    return false
  end

  ui.notify("unknown picker backend: " .. tostring(backend), vim.log.levels.ERROR)
  return false
end

return M
