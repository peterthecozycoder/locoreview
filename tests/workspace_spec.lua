package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

describe("review workspace actions", function()
  local old_vim
  local state
  local qf_calls
  local signs_calls
  local pr_refresh_calls
  local pr_open
  local store_items

  local function upvalue(fn, name)
    for i = 1, 30 do
      local n, v = debug.getupvalue(fn, i)
      if not n then break end
      if n == name then return v end
    end
    return nil
  end

  before_each(function()
    old_vim = _G.vim
    state = nil
    qf_calls = 0
    signs_calls = 0
    pr_refresh_calls = 0
    pr_open = true
    store_items = {
      {
        id = "RV-0001",
        file = "lua/a.lua",
        line = 4,
        end_line = nil,
        severity = "medium",
        status = "open",
        issue = "x",
        requested_change = "",
      },
    }

    _G.vim = {
      log = { levels = { INFO = 1, ERROR = 2 } },
      api = {},
    }

    package.loaded["locoreview.diff_view"] = {
      build_payload = function()
        return nil
      end,
    }
    package.loaded["locoreview.fs"] = {
      review_file_path = function()
        return "/repo/review.md"
      end,
    }
    package.loaded["locoreview.git"] = {
      repo_root = function()
        return "/repo"
      end,
    }
    package.loaded["locoreview.store"] = {
      load = function()
        return store_items
      end,
      save = function(_, items)
        store_items = items
        return true
      end,
      transition = function(items, id, status)
        local out = {}
        for _, item in ipairs(items) do
          local copy = {}
          for k, v in pairs(item) do copy[k] = v end
          if copy.id == id then copy.status = status end
          table.insert(out, copy)
        end
        return out
      end,
      delete = function()
        return {}
      end,
    }
    package.loaded["locoreview.ui"] = {
      notify = function() end,
      prompt_confirm = function(_, cb)
        cb(true)
      end,
    }
    package.loaded["locoreview.qf"] = {
      refresh = function()
        qf_calls = qf_calls + 1
      end,
    }
    package.loaded["locoreview.signs"] = {
      refresh = function()
        signs_calls = signs_calls + 1
      end,
    }
    package.loaded["locoreview.pr_view"] = {
      is_open = function()
        return pr_open
      end,
      refresh = function()
        pr_refresh_calls = pr_refresh_calls + 1
      end,
    }

    package.loaded["locoreview.workspace"] = nil
    local workspace = require("locoreview.workspace")
    state = upvalue(workspace.action_transition, "state")
    assert.is_truthy(state)
    state.item = {
      id = "RV-0001",
      file = "lua/a.lua",
      line = 4,
      severity = "medium",
      status = "open",
      issue = "x",
      requested_change = "",
    }
    state.items = { state.item }
    state.item_index = 1
  end)

  after_each(function()
    _G.vim = old_vim
    package.loaded["locoreview.workspace"] = nil
  end)

  it("refreshes PR view on transition when PR view is open", function()
    local workspace = require("locoreview.workspace")
    workspace.action_transition("fixed")

    assert.are.equal(1, qf_calls)
    assert.are.equal(1, signs_calls)
    assert.are.equal(1, pr_refresh_calls)
    assert.are.equal("fixed", state.item.status)
  end)

  it("refreshes PR view on delete when PR view is open", function()
    local workspace = require("locoreview.workspace")
    workspace.action_delete()

    assert.are.equal(1, qf_calls)
    assert.are.equal(1, signs_calls)
    assert.are.equal(1, pr_refresh_calls)
  end)
end)
