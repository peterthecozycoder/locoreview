describe("review commands", function()
  local path, source, original_changed
  local function press(key)
    local term = vim.api.nvim_replace_termcodes(key, true, false, true)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      if vim.api.nvim_replace_termcodes(map.lhs, true, false, true) == term then return map.callback() end
    end
    error("missing mapping " .. key)
  end
  before_each(function()
    path = vim.fn.tempname()
    require("locoreview").setup({ review_file = path, keymaps = false })
    vim.cmd("edit README.md")
    source = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    original_changed = require("locoreview.git").changed_lines
  end)
  after_each(function()
    vim.cmd("stopinsert")
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then vim.api.nvim_win_close(win, true) end
    end
    require("locoreview.git").changed_lines = original_changed
    vim.fn.delete(path)
  end)
  it("registers only four global review commands", function()
    local names = {}
    for name in pairs(vim.api.nvim_get_commands({})) do
      if name:match("^Review") then table.insert(names, name) end
    end
    table.sort(names)
    assert.are.same({ "ReviewAdd", "ReviewList", "ReviewPR", "ReviewShow" }, names)
  end)
  it("adds a comment on the current line", function()
    vim.cmd("ReviewAdd")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "A comment" })
    press("<C-s>")
    local item = require("locoreview.store").load(path)[1]
    assert.are.equal("README.md", item.file)
    assert.are.equal(5, item.line)
    assert.is_nil(item.end_line)
    assert.are.equal(source, vim.api.nvim_get_current_win())
  end)
  it("accepts a range on the same command", function()
    vim.cmd("2,4ReviewAdd")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "A range comment" })
    press("<C-s>")
    local item = require("locoreview.store").load(path)[1]
    assert.are.equal(2, item.line)
    assert.are.equal(4, item.end_line)
  end)
  it("rejects a range containing unchanged lines in diff_only mode", function()
    require("locoreview.config").setup({ review_file = path, diff_only = true })
    require("locoreview.git").changed_lines = function() return { { start = 2, ["end"] = 3 } } end
    vim.cmd("2,4ReviewAdd")
    assert.are.equal(source, vim.api.nvim_get_current_win())
    assert.is_false(require("locoreview.fs").exists(path))
  end)
  it("does not create a file when cancelled", function()
    vim.cmd("ReviewAdd")
    press("<C-c>")
    assert.is_false(require("locoreview.fs").exists(path))
  end)
  it("opens an empty list without creating a review file", function()
    vim.cmd("ReviewList")
    assert.matches("No open comments", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    assert.is_false(require("locoreview.fs").exists(path))
  end)
  it("leaves unrelated quickfix entries alone when saving", function()
    vim.fn.setqflist({}, " ", { title = "Build errors", items = { { filename = "README.md", lnum = 1, text = "Build error" } } })
    vim.cmd("ReviewAdd")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "A comment" })
    press("<C-s>")
    assert.are.equal("Build errors", vim.fn.getqflist({ title = 1 }).title)
  end)
end)
