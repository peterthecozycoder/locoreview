describe("PR review", function()
  local pr, path, files, added
  local original_parse
  local function press(key)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      if map.lhs == key then return map.callback() end
    end
    error("missing mapping: " .. key)
  end
  before_each(function()
    path = vim.fn.tempname()
    require("locoreview.config").setup({ review_file = path })
    original_parse = require("locoreview.git_diff").parse
    files = {{
      file = "new.lua", old_file = "old.lua", status = "renamed",
      stats = { added = 1, removed = 1 },
      hunks = {{ header = "@@ -2 +2 @@", lines = {
        { type = "remove", text = "-old", old_line = 2 },
        { type = "add", text = "+new", new_line = 2 },
      } }},
    }}
    require("locoreview.git_diff").parse = function() return files end
    pr = require("locoreview.pr_view")
    pr.open(false)
    added = nil
  end)
  after_each(function()
    pr.close()
    require("locoreview.git_diff").parse = original_parse
    vim.fn.delete(path)
  end)
  it("clears stale diff lines when there are no changes", function()
    files = {}
    pr.refresh()
    assert.are.same({ "  no uncommitted changes" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)
  it("anchors removed lines to the old path and revision", function()
    local commands = require("locoreview.commands")
    local original_add = commands.add_at
    commands.add_at = function(file, line, _, side) added = { file, line, side } end
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    press("c")
    commands.add_at = original_add
    assert.are.same({ "old.lua", 2, "old" }, added)
  end)
  it("shows badges only on the matching side of a diff", function()
    local store = require("locoreview.store")
    local items = store.insert({}, {
      file = "old.lua", line = 2, line_ref = "old", severity = "medium", status = "open", issue = "Check removal",
    })
    assert.is_true(store.save(path, items))
    pr.refresh()
    local ns = vim.api.nvim_get_namespaces()["locoreview.pr"]
    local badges = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
      if mark[4].virt_text then table.insert(badges, mark[2]) end
    end
    assert.are.same({ 2 }, badges)
  end)
  it("keeps the current view when git fails", function()
    local before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    require("locoreview.git_diff").parse = function() return nil, "bad ref" end
    pr.refresh()
    assert.are.same(before, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)
end)
