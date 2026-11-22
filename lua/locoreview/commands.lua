local M = {}

local config = require("locoreview.config")
local fs = require("locoreview.fs")
local git = require("locoreview.git")
local store = require("locoreview.store")
local ui = require("locoreview.ui")

local function review_path()
  local path = fs.review_file_path()
  if not path then ui.notify("unable to resolve review file path", vim.log.levels.ERROR) end
  return path
end

local function buffer_path()
  local abs = vim.api.nvim_buf_get_name(0)
  if abs == "" or vim.bo.buftype ~= "" then
    ui.notify("place the cursor in a source file", vim.log.levels.WARN)
    return
  end
  local root = git.repo_root()
  if root and vim.startswith(abs, root .. "/") then return abs:sub(#root + 2) end
  return vim.fn.fnamemodify(abs, ":.")
end

function M.refresh(items)
  require("locoreview.signs").refresh(items)
  require("locoreview.qf").refresh()
  require("locoreview.pr_view").refresh()
end

function M.add_at(file, line, end_line, line_ref)
  local path = review_path()
  if not path then return end
  local cfg = config.get()
  return ui.edit_comment({ severity = cfg.default_severity, file = file, line = line }, function(fields)
    if not fs.ensure_file(path, "# Review Comments\n\n") then
      ui.notify("failed to create review file", vim.log.levels.ERROR)
      return false
    end
    local items, err = store.load(path)
    if not items then
      ui.notify(err, vim.log.levels.ERROR)
      return false
    end
    fields.file, fields.line, fields.end_line = file, line, end_line
    fields.line_ref, fields.status, fields.author = line_ref, "open", cfg.default_author
    local next_items, inserted = store.insert(items, fields)
    if not next_items then
      ui.notify(inserted, vim.log.levels.ERROR)
      return false
    end
    local ok, save_err = store.save(path, next_items)
    if not ok then
      ui.notify(save_err, vim.log.levels.ERROR)
      return false
    end
    M.refresh(next_items)
    ui.notify("added " .. inserted.id)
    return true
  end)
end

local function add(opts)
  local file = buffer_path()
  if not file then return end
  local line = opts.range > 0 and opts.line1 or vim.api.nvim_win_get_cursor(0)[1]
  local end_line = opts.range > 0 and opts.line2 or nil
  local cfg = config.get()
  if cfg.diff_only then
    local ranges = git.changed_lines(file, git.base_branch(cfg)) or {}
    for lnum = line, end_line or line do
      local changed = false
      for _, range in ipairs(ranges) do
        if lnum >= range.start and lnum <= range["end"] then changed = true; break end
      end
      if not changed then
        ui.notify("selection contains unchanged lines from base diff", vim.log.levels.WARN)
        return
      end
    end
  end
  M.add_at(file, line, end_line)
end

function M.show_at(file, line, side)
  local path = review_path()
  if not path then return end
  return require("locoreview.comment_view").open(path, { file = file, line = line, side = side or "new" })
end

function M.register()
  vim.api.nvim_create_user_command("ReviewAdd", add, { range = true, desc = "Add a comment on this line or range" })
  vim.api.nvim_create_user_command("ReviewShow", function()
    local file = buffer_path()
    if file then M.show_at(file, vim.api.nvim_win_get_cursor(0)[1]) end
  end, { desc = "Read and manage comments on this line" })
  vim.api.nvim_create_user_command("ReviewList", function()
    local path = review_path()
    if path then require("locoreview.comment_view").open(path) end
  end, { desc = "Browse and manage review comments" })
  vim.api.nvim_create_user_command("ReviewPR", function(opts)
    require("locoreview.pr_view").open(opts.args ~= "" and opts.args or nil)
  end, { nargs = "?", desc = "Review a diff" })
end

return M
