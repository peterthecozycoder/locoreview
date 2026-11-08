describe("comment editor", function()
  local buf, win, submitted
  local function press(key)
    local term = vim.api.nvim_replace_termcodes(key, true, false, true)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if vim.api.nvim_replace_termcodes(map.lhs, true, false, true) == term then
        return map.callback()
      end
    end
    error("missing mapping " .. key)
  end
  before_each(function() submitted = nil end)
  after_each(function()
    vim.cmd("stopinsert")
    if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end)
  local function open(item, save)
    buf, win = require("locoreview.composer").open(vim.tbl_extend("force", {
      file = "example.lua", line = 4, severity = "medium",
    }, item or {}), save or function(fields) submitted = fields; return true end)
  end
  it("saves a multiline comment with no required suggestion", function()
    open()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "First paragraph", "", "Second paragraph" })
    press("<C-s>")
    assert.are.same({ issue = "First paragraph\n\nSecond paragraph", requested_change = "", severity = "medium" }, submitted)
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)
  it("preserves existing suggestions and lets severity change in place", function()
    open({ issue = "Problem", requested_change = "Suggested change\nMore context", severity = "high" })
    press("<C-g>")
    press("<C-s>")
    assert.are.equal("Suggested change\nMore context", submitted.requested_change)
    assert.are.equal("low", submitted.severity)
  end)
  it("cancels without calling save", function()
    open({ issue = "Discard me" })
    press("<C-c>")
    assert.is_nil(submitted)
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)
  it("keeps an empty draft open", function()
    open()
    press("<C-s>")
    assert.is_nil(submitted)
    assert.is_true(vim.api.nvim_win_is_valid(win))
  end)
  it("retains the draft when persistence fails", function()
    open({ issue = "Keep me" }, function() return false end)
    press("<C-s>")
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.are.equal("Keep me", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)
end)
