describe("plugin entrypoint", function()
  it("does not call setup automatically", function()
    local setup_calls = 0
    local old_vim = _G.vim
    local old_review = package.loaded["review"]
    local old_loaded = old_vim and old_vim.g and old_vim.g.loaded_locoreview_nvim

    _G.vim = {
      g = {},
    }
    package.loaded["review"] = {
      setup = function()
        setup_calls = setup_calls + 1
      end,
    }

    dofile("plugin/locoreview.lua")

    assert.are.equal(1, vim.g.loaded_locoreview_nvim)
    assert.are.equal(0, setup_calls)

    package.loaded["review"] = old_review
    _G.vim = old_vim
    if _G.vim and _G.vim.g then
      _G.vim.g.loaded_locoreview_nvim = old_loaded
    end
  end)
end)
