package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

describe("review quickfix", function()
  local captured = nil
  local notifications = {}
  local repo_root = "/repo"
  local qf

  setup(function()
    _G.vim = {
      fn = {
        setqflist = function(_, _, payload)
          captured = payload
        end,
      },
      api = {},
      log = { levels = { ERROR = 1 } },
    }
    package.loaded["locoreview.ui"] = {
      notify = function(msg)
        table.insert(notifications, msg)
      end,
    }
    package.loaded["locoreview.git"] = {
      repo_root = function()
        return repo_root
      end,
    }
    qf = require("locoreview.qf")
  end)

  before_each(function()
    captured = nil
    notifications = {}
    repo_root = "/repo"
  end)

  it("populates open items by default with formatted text", function()
    local entries = qf.populate({
      {
        id = "RV-0001",
        file = "a.lua",
        line = 1,
        end_line = nil,
        severity = "high",
        status = "open",
        issue = "This is an issue",
      },
      {
        id = "RV-0002",
        file = "b.lua",
        line = 2,
        end_line = nil,
        severity = "low",
        status = "fixed",
        issue = "Done",
      },
    })

    assert.are.equal(1, #entries)
    assert.are.equal(1, #captured.items)
    assert.are.equal("/repo/a.lua", captured.items[1].filename)
    assert.are.equal("[RV-0001][high][open] This is an issue", captured.items[1].text)
  end)

  it("supports all-items mode via custom filter", function()
    local entries = qf.populate({
      {
        id = "RV-0001",
        file = "a.lua",
        line = 1,
        end_line = nil,
        severity = "high",
        status = "open",
        issue = "a",
      },
      {
        id = "RV-0002",
        file = "b.lua",
        line = 2,
        end_line = nil,
        severity = "low",
        status = "fixed",
        issue = "b",
      },
    }, function()
      return true
    end)

    assert.are.equal(2, #entries)
    assert.are.equal(2, #captured.items)
  end)

  it("returns an error when repository root is unavailable", function()
    repo_root = nil
    local entries, err = qf.populate({
      {
        id = "RV-0001",
        file = "a.lua",
        line = 1,
        severity = "high",
        status = "open",
        issue = "x",
      },
    })

    assert.is_nil(entries)
    assert.are.equal("could not determine repository root", err)
    assert.are.equal(1, #notifications)
    assert.are.equal(nil, captured)
  end)
end)
