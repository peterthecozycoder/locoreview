describe("comment workflow", function()
  local path, source
  local function press(key)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      if vim.api.nvim_replace_termcodes(map.lhs, true, false, true) == vim.api.nvim_replace_termcodes(key, true, false, true) then return map.callback() end
    end
    error("save mapping not found")
  end
  before_each(function()
    path = vim.fn.tempname()
    require("locoreview").setup({ review_file = path, keymaps = false })
    vim.cmd("edit README.md")
    source = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
  end)
  after_each(function()
    vim.cmd("stopinsert")
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then vim.api.nvim_win_close(win, true) end
    end
    vim.fn.delete(path)
  end)
  it("adds, views, edits and resolves a comment through real commands", function()
    vim.cmd("ReviewAdd")
    assert.are.equal(2, #vim.api.nvim_list_wins())
    assert.is_false(require("locoreview.fs").exists(path))
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "First comment" })
    press("<C-s>")
    assert.are.equal(source, vim.api.nvim_get_current_win())
    local store = require("locoreview.store")
    assert.are.equal("First comment", store.load(path)[1].issue)
    vim.cmd("ReviewShow")
    local popup
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then popup = win end
    end
    assert.is_truthy(popup)
    assert.matches("First comment", table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(popup), 0, -1, false), "\n"))
    press("e")
    -- A second comment arrives while the editor is open.
    local latest = store.insert(store.load(path), { file = "README.md", line = 8, severity = "low", status = "open", issue = "Concurrent comment" })
    assert.is_true(store.save(path, latest))
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "Edited comment" })
    press("<C-s>")
    local items = store.load(path)
    assert.are.equal(2, #items)
    assert.are.equal("Edited comment", items[1].issue)
    assert.are.equal("Concurrent comment", items[2].issue)
    assert.are.equal(popup, vim.api.nvim_get_current_win())
    press("f")
    assert.are.equal("fixed", store.load(path)[1].status)
  end)
end)
