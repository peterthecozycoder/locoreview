-- pr/actions.lua
-- Mutating actions for the PR view: review state toggles, comments, file/hunk
-- git actions, timer, and action menu.

local M = {}

local config       = require("locoreview.config")
local fs           = require("locoreview.fs")
local git          = require("locoreview.git")
local store        = require("locoreview.store")
local ui           = require("locoreview.ui")
local viewed_state = require("locoreview.viewed_state")

local state_mod = require("locoreview.pr.state")
local state     = state_mod.state
local ensure_ns = state_mod.ensure_ns

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

local function load_review_items()
  local path = fs.review_file_path()
  if not path then return {} end
  local items, _ = store.load(path)
  return items or {}
end

local function run_system_list(cmd)
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then return nil, table.concat(out or {}, "\n") end
  return out
end

-- ── Review actions ────────────────────────────────────────────────────────────

function M.mark_reviewed_at_cursor()
  local meta, lnum = call_ctx("meta_at_cursor")
  if not meta or not meta.file then
    ui.notify("not on a diff line", vim.log.levels.WARN)
    return
  end

  local file = meta.file
  call_ctx("queue_cursor_restore", nil, lnum, 0)
  viewed_state.mark_reviewed(file, call_ctx("diff_hash_for", file))

  if config.get().pr_view.micro_rewards then
    local header_lnum = call_ctx("header_lnum_for_file", file)
    if header_lnum then
      local n = ensure_ns()
      vim.api.nvim_buf_set_extmark(state.buf, n, header_lnum - 1, 0, {
        virt_text     = { { "  ● reviewed ✦", "DiagnosticSignOk" } },
        virt_text_pos = "eol",
      })
    end
    vim.defer_fn(function() refresh() end, 350)
  else
    refresh()
  end

  if config.get().pr_view.auto_advance_on_viewed then
    local vst = viewed_state.load()
    for _, header_lnum in ipairs(state.file_header_lnums) do
      local hm = state.line_map[header_lnum]
      if hm and hm.file and hm.file ~= ""
          and call_ctx("get_entry_mood", vst[hm.file]) ~= "reviewed"
          and not viewed_state.is_snoozed(hm.file) then
        vim.api.nvim_win_set_cursor(0, { header_lnum, 0 })
        return
      end
    end
    ui.notify("all files reviewed ✦", vim.log.levels.INFO)
  end
end

M.mark_viewed_at_cursor = M.mark_reviewed_at_cursor

function M.mark_unviewed_at_cursor()
  local meta, lnum = call_ctx("meta_at_cursor")
  if not meta or not meta.file then return end
  call_ctx("queue_cursor_restore", nil, lnum, 0)
  viewed_state.mark_unviewed(meta.file)
  refresh()
end

function M.snooze_file_at_cursor()
  local meta, lnum = call_ctx("meta_at_cursor")
  if not meta or not meta.file then
    ui.notify("not on a file line", vim.log.levels.WARN)
    return
  end

  local file = meta.file
  call_ctx("queue_cursor_restore", nil, lnum, 0)
  if viewed_state.is_snoozed(file) then
    viewed_state.unsnooze(file)
    ui.notify("un-snoozed " .. file, vim.log.levels.INFO)
  else
    viewed_state.snooze(file)

    if config.get().pr_view.micro_rewards then
      local n = ensure_ns()
      local header_lnum = call_ctx("header_lnum_for_file", file)
      if header_lnum then
        vim.api.nvim_buf_set_extmark(state.buf, n, header_lnum - 1, 0, {
          virt_text     = { { "  ⏸ snoozed", "LocoMoodSnoozed" } },
          virt_text_pos = "eol",
        })
      end
      vim.defer_fn(function() refresh() end, 350)
    else
      refresh()
    end
    ui.notify("snoozed " .. file .. " — skipped in rhythm", vim.log.levels.INFO)
  end
end

function M.jump_next_unreviewed()
  local vst = viewed_state.load()
  for _, lnum in ipairs(state.file_header_lnums) do
    local hm = state.line_map[lnum]
    if hm and hm.file then
      local mood = call_ctx("get_entry_mood", vst[hm.file])
      if mood ~= "reviewed" and not viewed_state.is_snoozed(hm.file) then
        vim.api.nvim_win_set_cursor(0, { lnum, 0 })
        return
      end
    end
  end
  ui.notify("no unreviewed files remaining", vim.log.levels.INFO)
end

function M.batch_mark_directory()
  local meta, lnum = call_ctx("meta_at_cursor")
  if not meta or not meta.file then
    ui.notify("cursor not on a diff line", vim.log.levels.WARN)
    return
  end

  local dir = vim.fn.fnamemodify(meta.file, ":h")
  if dir == "." then dir = "" end

  local files_in_dir = {}
  for _, fd in ipairs(state.file_diffs) do
    local matches = (dir == "") and not string.find(fd.file, "/")
        or vim.startswith(fd.file, dir .. "/")
    if matches then table.insert(files_in_dir, fd) end
  end

  if #files_in_dir == 0 then
    ui.notify("no files found in directory", vim.log.levels.WARN)
    return
  end

  vim.ui.select({ "Yes", "No" }, {
    prompt = "Mark " .. #files_in_dir .. " files in "
        .. (dir ~= "" and dir or "/") .. "/ as reviewed?",
  }, function(choice)
    if choice == "Yes" then
      call_ctx("queue_cursor_restore", nil, lnum, 0)
      for _, fd in ipairs(files_in_dir) do
        viewed_state.mark_reviewed(fd.file, fd.diff_hash)
      end
      refresh()
      ui.notify("marked " .. #files_in_dir .. " files reviewed", vim.log.levels.INFO)
    end
  end)
end

-- ── Comment actions ───────────────────────────────────────────────────────────

function M.add_comment_at_cursor()
  local meta, lnum = call_ctx("meta_at_cursor")
  if not meta or not meta.file then
    ui.notify("place cursor on a diff line to comment", vim.log.levels.WARN)
    return
  end

  local line, line_ref = call_ctx("resolve_comment_line", meta)
  if not line then
    ui.notify("place cursor on an added, context, or removed line to comment", vim.log.levels.WARN)
    return
  end

  local cur = vim.api.nvim_win_get_cursor(0)
  call_ctx("queue_cursor_restore", meta, lnum or cur[1], cur[2] or 0)
  require("locoreview.commands").add_at(meta.file, line, nil, line_ref)
end

function M.add_quick_comment_at_cursor()
  local meta, lnum = call_ctx("meta_at_cursor")
  if not meta or not meta.file then
    ui.notify("place cursor on a diff line to comment", vim.log.levels.WARN)
    return
  end

  local line, line_ref = call_ctx("resolve_comment_line", meta)
  if not line then
    ui.notify("place cursor on an added, context, or removed line to comment", vim.log.levels.WARN)
    return
  end

  local cur = vim.api.nvim_win_get_cursor(0)
  call_ctx("queue_cursor_restore", meta, lnum or cur[1], cur[2] or 0)

  vim.ui.input({ prompt = "Quick note: " }, function(text)
    if not text or text:match("^%s*$") then return end

    local items = load_review_items()
    local next_items, new_item = store.insert(items, {
      file             = meta.file,
      line             = line,
      line_ref         = line_ref,
      severity         = "low",
      status           = "open",
      issue            = text,
      requested_change = "",
    })

    if not next_items then
      ui.notify("failed to add comment", vim.log.levels.ERROR)
      return
    end

    local path = fs.review_file_path()
    if not path then
      ui.notify("unable to find review file", vim.log.levels.ERROR)
      return
    end

    local ok, save_err = store.save(path, next_items)
    if not ok then
      ui.notify(save_err or "failed to save review file", vim.log.levels.ERROR)
      return
    end
    refresh()
    ui.notify("added note " .. new_item.id, vim.log.levels.INFO)
  end)
end

local STATUS_TRANSITION_ORDER = { "fixed", "blocked", "wontfix", "open" }

local function next_status_for(current_status)
  local types_mod = require("locoreview.types")
  local transitions = types_mod.VALID_TRANSITIONS[current_status] or {}
  for _, status in ipairs(STATUS_TRANSITION_ORDER) do
    if transitions[status] then return status end
  end
  return nil
end

function M.show_comment_popup()
  local meta = call_ctx("meta_at_cursor")
  if not meta or not meta.file then
    ui.notify("no comment here", vim.log.levels.WARN)
    return
  end

  local review_items = load_review_items()
  local comment_map  = call_ctx("build_comment_map", review_items)
  local fc           = comment_map and comment_map[meta.file]
  local items        = nil

  if fc then
    if meta.type == "remove" and meta.old_line then
      items = fc.old and fc.old[meta.old_line]
    elseif meta.new_line then
      items = fc.new and fc.new[meta.new_line]
    end
  end

  if not items or #items == 0 then
    ui.notify("no comment here", vim.log.levels.WARN)
    return
  end

  local item = items[1]

  local lines = {
    "ID: " .. item.id,
    "Status: " .. item.status,
    "Severity: " .. item.severity,
    "",
    "Issue:",
  }
  for line in (item.issue .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  if item.requested_change and item.requested_change ~= "" then
    table.insert(lines, "")
    table.insert(lines, "Requested change:")
    for line in (item.requested_change .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, line)
    end
  end
  table.insert(lines, "")
  table.insert(lines, "[e] edit  [s] status  [d] delete  [q] close")

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, #line)
  end
  width = math.min(width + 4, vim.o.columns - 4)

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[float_buf].buftype = "nofile"
  vim.bo[float_buf].bufhidden = "wipe"
  vim.bo[float_buf].modifiable = true
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].modifiable = false

  local float_win = vim.api.nvim_open_win(float_buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
  })

  local fk = { noremap = true, silent = true, buffer = float_buf }

  local function close_float()
    if vim.api.nvim_win_is_valid(float_win) then
      vim.api.nvim_win_close(float_win, true)
    end
  end

  vim.keymap.set("n", "e", function()
    local path = fs.review_file_path()
    if not path then
      ui.notify("unable to find review file", vim.log.levels.ERROR)
      return
    end
    close_float()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.fn.search("^## " .. item.id)
  end, fk)

  vim.keymap.set("n", "s", function()
    local next_status = next_status_for(item.status)
    if not next_status then
      ui.notify("no valid transition from " .. item.status, vim.log.levels.WARN)
      return
    end

    local updated, transition_err = store.transition(review_items, item.id, next_status)
    if not updated then
      ui.notify(transition_err or "failed to update note status", vim.log.levels.ERROR)
      return
    end

    local path = fs.review_file_path()
    if not path then
      ui.notify("unable to find review file", vim.log.levels.ERROR)
      return
    end

    local ok, save_err = store.save(path, updated)
    if not ok then
      ui.notify(save_err or "failed to save review file", vim.log.levels.ERROR)
      return
    end

    close_float()
    refresh()
  end, fk)

  vim.keymap.set("n", "d", function()
    vim.ui.select({ "Delete", "Cancel" }, { prompt = "Delete this note?" }, function(choice)
      if choice ~= "Delete" then return end

      local updated, delete_err = store.delete(review_items, item.id)
      if not updated then
        ui.notify(delete_err or "failed to delete note", vim.log.levels.ERROR)
        return
      end

      local path = fs.review_file_path()
      if not path then
        ui.notify("unable to find review file", vim.log.levels.ERROR)
        return
      end

      local ok, save_err = store.save(path, updated)
      if not ok then
        ui.notify(save_err or "failed to save review file", vim.log.levels.ERROR)
        return
      end

      close_float()
      refresh()
    end)
  end, fk)

  vim.keymap.set("n", "q", close_float, fk)
  vim.keymap.set("n", "<Esc>", close_float, fk)

  local autocmd_id = vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = state.buf,
    callback = function()
      if vim.api.nvim_win_is_valid(float_win) then
        close_float()
        vim.api.nvim_del_autocmd(autocmd_id)
      end
    end,
  })
end

function M.remove_resolved_comments()
  local path = fs.review_file_path()
  if not path then
    ui.notify("unable to resolve review file path", vim.log.levels.ERROR)
    return
  end

  local items, err = store.load(path)
  if not items then
    ui.notify(err or "unable to load review notes", vim.log.levels.ERROR)
    return
  end

  local next_items, removed = store.delete_by_statuses(items, { "fixed", "wontfix" })
  if removed == 0 then
    ui.notify("no resolved notes to remove", vim.log.levels.INFO)
    return
  end

  local ok, save_err = store.save(path, next_items)
  if not ok then
    ui.notify(save_err or "failed to save review file", vim.log.levels.ERROR)
    return
  end

  refresh()
  ui.notify("removed " .. removed .. " resolved notes", vim.log.levels.INFO)
end

-- ── Timer ─────────────────────────────────────────────────────────────────────

function M.start_or_manage_timer()
  if state.timer ~= nil then
    vim.ui.select({ "Cancel timer", "Keep going" }, { prompt = "Timer is running" },
      function(choice)
        if choice == "Cancel timer" then
          state.timer:stop()
          state.timer:close()
          state.timer = nil
          state.timer_end = nil
          refresh()
        end
      end)
  else
    vim.ui.input({ prompt = "Minutes: " }, function(input)
      if not input or input:match("^%s*$") then return end
      local minutes = tonumber(input)
      if not minutes or minutes <= 0 then
        ui.notify("please enter a positive number", vim.log.levels.WARN)
        return
      end
      state.timer_end = os.time() + (minutes * 60)
      state.timer = vim.loop.new_timer()
      state.timer:start(0, 1000, vim.schedule_wrap(function() refresh() end))
      refresh()
      ui.notify("timer started: " .. minutes .. " minutes", vim.log.levels.INFO)
    end)
  end
end

-- ── File / hunk actions ───────────────────────────────────────────────────────

local function file_path_at_cursor()
  local meta = call_ctx("meta_at_cursor")
  if not meta or not meta.file then
    ui.notify("cursor is not on a file line", vim.log.levels.WARN)
    return nil
  end
  return meta.file
end

local function absolute_path_for(file)
  local root = git.repo_root()
  if not root or root == "" then return nil end
  return root .. "/" .. file
end

local function repo_root_or_notify()
  local root = git.repo_root()
  if not root or root == "" then
    ui.notify("could not determine repository root", vim.log.levels.ERROR)
    return nil
  end
  return root
end

local function refresh_after_worktree_change()
  refresh()
end

function M.open_source_at_cursor()
  local meta = call_ctx("meta_at_cursor")
  if not meta or not meta.file then
    ui.notify("cursor is not on a file line", vim.log.levels.WARN)
    return
  end
  local line = meta.new_line or meta.old_line or 1
  local root = repo_root_or_notify()
  if not root then return end
  pcall(vim.cmd, "tabprevious")
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. meta.file))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end

function M.open_in_split_at_cursor()
  local meta = call_ctx("meta_at_cursor")
  if not meta or not meta.file then
    ui.notify("cursor is not on a file line", vim.log.levels.WARN)
    return
  end
  local line = meta.new_line or meta.old_line or 1
  local root = repo_root_or_notify()
  if not root then return end
  pcall(vim.cmd, "tabprevious")
  vim.cmd("vsplit " .. vim.fn.fnameescape(root .. "/" .. meta.file))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end

function M.delete_file_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end
  local path = absolute_path_for(file)
  if not path then
    ui.notify("could not determine repository root", vim.log.levels.ERROR)
    return
  end

  local rc = vim.fn.delete(path)
  if rc ~= 0 then
    ui.notify("failed to delete " .. file, vim.log.levels.ERROR)
    return
  end
  if state.base_ref ~= nil then
    state.hidden_files[file] = true
  end
  refresh_after_worktree_change()
  ui.notify("deleted " .. file, vim.log.levels.INFO)
end

function M.rename_file_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end
  local old_path = absolute_path_for(file)
  if not old_path then
    ui.notify("could not determine repository root", vim.log.levels.ERROR)
    return
  end
  local root = repo_root_or_notify()
  if not root then return end

  vim.ui.input({ prompt = "Rename file to: ", default = file }, function(input)
    if not input then return end
    local target = (input:gsub("^%s+", ""):gsub("%s+$", ""))
    if target == "" or target == file then return end
    if target:sub(1, 1) == "/" then
      if vim.startswith(target, root .. "/") then
        target = target:sub(#root + 2)
      else
        ui.notify("path must be inside repository", vim.log.levels.ERROR)
        return
      end
    end
    local new_path = absolute_path_for(target)
    if not new_path then
      ui.notify("could not determine repository root", vim.log.levels.ERROR)
      return
    end
    local dir = vim.fn.fnamemodify(new_path, ":h")
    if dir and dir ~= "" then
      vim.fn.mkdir(dir, "p")
    end
    if vim.fn.rename(old_path, new_path) ~= 0 then
      ui.notify("failed to rename " .. file, vim.log.levels.ERROR)
      return
    end
    refresh_after_worktree_change()
    ui.notify("renamed " .. file .. " → " .. target, vim.log.levels.INFO)
  end)
end

function M.copy_file_path_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end
  local copied = false
  for _, reg in ipairs({ "+", "*" }) do
    local ok = pcall(vim.fn.setreg, reg, file)
    copied = copied or ok
  end
  if not copied then pcall(vim.fn.setreg, '"', file) end
  ui.notify("copied: " .. file, vim.log.levels.INFO)
end

function M.view_file_diff_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end

  local cmd = { "git", "diff", "--unified=3" }
  if state.base_ref then
    table.insert(cmd, state.base_ref .. "...HEAD")
  else
    table.insert(cmd, "HEAD")
  end
  table.insert(cmd, "--")
  table.insert(cmd, file)

  local lines, err = run_system_list(cmd)
  if not lines then
    ui.notify("git diff failed: " .. (err or ""), vim.log.levels.ERROR)
    return
  end
  if #lines == 0 then
    ui.notify("no diff for " .. file, vim.log.levels.INFO)
    return
  end

  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "diff"
  pcall(vim.api.nvim_buf_set_name, buf, "locoreview://file-diff/" .. file)
end

function M.add_to_gitignore_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end
  local root = repo_root_or_notify()
  if not root then return end
  local f = io.open(root .. "/.gitignore", "a")
  if not f then
    ui.notify("failed to open .gitignore", vim.log.levels.ERROR)
    return
  end
  f:write(file .. "\n")
  f:close()
  ui.notify("added " .. file .. " to .gitignore", vim.log.levels.INFO)
end

function M.remove_from_tracking_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end
  local root = repo_root_or_notify()
  if not root then return end
  vim.fn.system({ "git", "-C", root, "rm", "--cached", "--", file })
  if vim.v.shell_error ~= 0 then
    ui.notify("git rm --cached failed", vim.log.levels.ERROR)
    return
  end
  if state.base_ref ~= nil then
    state.hidden_files[file] = true
  end
  refresh_after_worktree_change()
  ui.notify("removed " .. file .. " from tracking", vim.log.levels.INFO)
end

function M.reset_file_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end
  local root = repo_root_or_notify()
  if not root then return end
  vim.fn.system({ "git", "-C", root, "checkout", "--", file })
  if vim.v.shell_error ~= 0 then
    ui.notify("git checkout -- failed", vim.log.levels.ERROR)
    return
  end
  refresh_after_worktree_change()
  ui.notify("reverted " .. file, vim.log.levels.INFO)
end

function M.reset_hunk_at_cursor()
  local meta = call_ctx("meta_at_cursor")
  if not meta or not meta.hunk_idx or not meta.file_idx then
    ui.notify("cursor is not on a hunk line", vim.log.levels.WARN)
    return
  end
  local fd   = state.file_diffs[meta.file_idx]
  local hunk = fd and fd.hunks[meta.hunk_idx]
  if not hunk then return end

  local patch_text = call_ctx("build_hunk_patch", fd, hunk)

  local tmpfile = vim.fn.tempname()
  local f = io.open(tmpfile, "w")
  if not f then
    ui.notify("failed to create temp file", vim.log.levels.ERROR)
    return
  end
  f:write(patch_text)
  f:close()

  local root = repo_root_or_notify()
  if not root then
    vim.fn.delete(tmpfile)
    return
  end
  vim.fn.system({ "git", "-C", root, "apply", "--reverse", tmpfile })
  vim.fn.delete(tmpfile)
  if vim.v.shell_error ~= 0 then
    ui.notify("revert hunk failed", vim.log.levels.ERROR)
    return
  end

  refresh_after_worktree_change()
  ui.notify("reverted hunk in " .. fd.file, vim.log.levels.INFO)
end

function M.stage_file_at_cursor()
  local file = file_path_at_cursor()
  if not file then return end
  local root = repo_root_or_notify()
  if not root then return end
  vim.fn.system({ "git", "-C", root, "add", "--", file })
  if vim.v.shell_error ~= 0 then
    ui.notify("git add failed", vim.log.levels.ERROR)
    return
  end
  refresh_after_worktree_change()
  ui.notify("staged " .. file, vim.log.levels.INFO)
end

function M.stage_hunk_at_cursor()
  local meta = call_ctx("meta_at_cursor")
  if not meta or not meta.hunk_idx or not meta.file_idx then
    ui.notify("cursor is not on a hunk line", vim.log.levels.WARN)
    return
  end
  local fd   = state.file_diffs[meta.file_idx]
  local hunk = fd and fd.hunks[meta.hunk_idx]
  if not hunk then return end

  local patch_text = call_ctx("build_hunk_patch", fd, hunk)

  local tmpfile = vim.fn.tempname()
  local f = io.open(tmpfile, "w")
  if not f then
    ui.notify("failed to create temp file", vim.log.levels.ERROR)
    return
  end
  f:write(patch_text)
  f:close()

  local root = repo_root_or_notify()
  if not root then
    vim.fn.delete(tmpfile)
    return
  end
  vim.fn.system({ "git", "-C", root, "apply", "--cached", tmpfile })
  vim.fn.delete(tmpfile)
  if vim.v.shell_error ~= 0 then
    ui.notify("git apply --cached failed", vim.log.levels.ERROR)
    return
  end

  refresh_after_worktree_change()
  ui.notify("staged hunk in " .. fd.file, vim.log.levels.INFO)
end

function M.open_related_test_file()
  local file = file_path_at_cursor()
  if not file then return end
  local root = repo_root_or_notify()
  if not root then return end
  local base = vim.fn.fnamemodify(file, ":t:r")
  local ext  = vim.fn.fnamemodify(file, ":e")
  local dir  = vim.fn.fnamemodify(file, ":h")

  local candidates = {
    dir .. "/" .. base .. "_test." .. ext,
    dir .. "/" .. base .. ".test." .. ext,
    dir .. "/" .. base .. "_spec." .. ext,
    dir .. "/" .. base .. ".spec." .. ext,
    "spec/" .. base .. "_spec." .. ext,
    "test/" .. base .. "_test." .. ext,
    "tests/" .. base .. "_test." .. ext,
    "__tests__/" .. base .. ".test." .. ext,
  }

  for _, candidate in ipairs(candidates) do
    if vim.fn.filereadable(root .. "/" .. candidate) == 1 then
      pcall(vim.cmd, "tabprevious")
      vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. candidate))
      return
    end
  end
  ui.notify("no related test file found for " .. file, vim.log.levels.WARN)
end

function M.open_file_actions_menu()
  local meta = call_ctx("meta_at_cursor")
  if not meta or not meta.file then return end

  local actions = {
    { label = "Mark reviewed", run = M.mark_reviewed_at_cursor },
    { label = "Snooze / un-snooze file", run = M.snooze_file_at_cursor },
    { label = "Jump to next unreviewed", run = M.jump_next_unreviewed },
    { label = "Stage file  (git add)", run = M.stage_file_at_cursor },
    { label = "Open in editor", run = M.open_source_at_cursor },
    { label = "Open in split", run = M.open_in_split_at_cursor },
    { label = "Copy file path", run = M.copy_file_path_at_cursor },
    { label = "Open related test file", run = M.open_related_test_file },
    { label = "View file diff (new tab)", run = M.view_file_diff_at_cursor },
    { label = "── maintenance ──────────────────", run = nil },
    { label = "Rename file", run = M.rename_file_at_cursor },
    { label = "Revert file  (git checkout --)", run = M.reset_file_at_cursor },
    { label = "Add to .gitignore", run = M.add_to_gitignore_at_cursor },
    { label = "Remove from tracking  (git rm)", run = M.remove_from_tracking_at_cursor },
    { label = "Delete file", run = M.delete_file_at_cursor },
  }

  if meta.hunk_idx then
    table.insert(actions, 5, { label = "Stage hunk  (git apply --cached)", run = M.stage_hunk_at_cursor })
    table.insert(actions, 6, { label = "Revert hunk  (git apply --reverse)", run = M.reset_hunk_at_cursor })
  end

  vim.ui.select(actions, {
    prompt = "Actions: " .. meta.file,
    format_item = function(item) return item.label end,
  }, function(choice)
    if choice and choice.run then
      choice.run()
    end
  end)
end

return M
