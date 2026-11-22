describe("review keymaps", function()
  it("installs four normal mappings and reuses add in visual mode", function()
    require("locoreview.keymaps").setup({ keymaps = true })
    local installed = {}
    for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
      if map.rhs and map.rhs:match("Review") then table.insert(installed, map.rhs:match("Review%w+")) end
    end
    table.sort(installed)
    assert.are.same({ "ReviewAdd", "ReviewList", "ReviewPR", "ReviewShow" }, installed)
    assert.are.equal(":ReviewAdd<CR>", vim.fn.maparg("<leader>ra", "x"))
  end)
end)
