package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

describe("review picker", function()
  local old_vim
  local state
  local repo_root

  before_each(function()
    old_vim = _G.vim
    state = {
      commands = {},
      cursor = nil,
      notifications = {},
    }
    repo_root = "/repo"

    _G.vim = {
      ui = {
        select = function(items, _, cb)
          cb(items[1])
        end,
      },
      fn = {
        fnameescape = function(value)
          return value
        end,
      },
      api = {
        nvim_win_set_cursor = function(_, pos)
          state.cursor = pos
        end,
      },
      cmd = function(command)
        table.insert(state.commands, command)
      end,
      log = {
        levels = { INFO = 1, ERROR = 2 },
      },
    }

    package.loaded["locoreview.config"] = {
      get = function()
        return {
          picker = {
            enabled = true,
            backend = "auto",
          },
        }
      end,
    }
    package.loaded["locoreview.git"] = {
      repo_root = function()
        return repo_root
      end,
    }
    package.loaded["locoreview.ui"] = {
      notify = function(msg)
        table.insert(state.notifications, msg)
      end,
    }
    package.loaded["locoreview.util"] = nil
    package.loaded["locoreview.picker"] = nil
  end)

  after_each(function()
    _G.vim = old_vim
    package.loaded["locoreview.picker"] = nil
    package.loaded["locoreview.config"] = nil
    package.loaded["locoreview.git"] = nil
    package.loaded["locoreview.ui"] = nil
  end)

  it("opens selected item when repo root is available", function()
    local picker = require("locoreview.picker")
    local ok = picker.open({
      {
        id = "RV-0001",
        file = "lua/a.lua",
        line = 12,
        severity = "medium",
        status = "open",
        issue = "needs tweak",
        requested_change = "",
        created_at = "2026-01-01T00:00:00Z",
      },
    })

    assert.is_true(ok)
    assert.are.equal("edit /repo/lua/a.lua", state.commands[1])
    assert.are.same({ 12, 0 }, state.cursor)
  end)

  it("notifies when repo root is unavailable", function()
    repo_root = nil
    local picker = require("locoreview.picker")
    local ok = picker.open({
      {
        id = "RV-0001",
        file = "lua/a.lua",
        line = 12,
        severity = "medium",
        status = "open",
        issue = "needs tweak",
        requested_change = "",
        created_at = "2026-01-01T00:00:00Z",
      },
    })

    assert.is_true(ok)
    assert.are.equal(0, #state.commands)
    assert.are.equal("could not determine repository root", state.notifications[1])
  end)
end)
