package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

describe("review store", function()
  local store = require("locoreview.store")

  it("returns RV-0001 for empty next_id", function()
    assert.are.equal("RV-0001", store.next_id({}))
  end)

  it("returns next max id", function()
    assert.are.equal("RV-0004", store.next_id({
      { id = "RV-0001" },
      { id = "RV-0003" },
    }))
  end)

  it("inserts and persists item via save/load", function()
    local items, inserted = assert(store.insert({}, {
      file = "lua/review/store.lua",
      line = 7,
      severity = "medium",
      status = "open",
      issue = "x",
      requested_change = "y",
    }))
    assert.are.equal("RV-0001", inserted.id)
    local path = os.tmpname()
    assert.is_true(assert(store.save(path, items)))
    local loaded = assert(store.load(path))
    assert.are.equal(1, #loaded)
    assert.are.equal("RV-0001", loaded[1].id)
    os.remove(path)
  end)

  it("allows valid transition and rejects invalid transition", function()
    local items = {
      {
        id = "RV-0001",
        file = "a.lua",
        line = 1,
        end_line = nil,
        severity = "low",
        status = "open",
        issue = "a",
        requested_change = "",
        author = nil,
        created_at = "2026-03-28T10:00:00Z",
        updated_at = "2026-03-28T10:00:00Z",
      },
    }
    local fixed = assert(store.transition(items, "RV-0001", "fixed"))
    assert.are.equal("fixed", fixed[1].status)
    local _, err = store.transition(fixed, "RV-0001", "blocked")
    assert.is_truthy(err)
  end)

  it("returns error when deleting missing item", function()
    local _, err = store.delete({}, "RV-9999")
    assert.is_truthy(err)
  end)

  it("updates item fields", function()
    local items = {
      {
        id = "RV-0001",
        file = "a.lua",
        line = 1,
        end_line = nil,
        severity = "low",
        status = "open",
        issue = "old",
        requested_change = "",
        author = nil,
        created_at = "2026-03-28T10:00:00Z",
        updated_at = "2026-03-28T10:00:00Z",
      },
    }
    local updated = assert(store.update(items, "RV-0001", {
      issue = "new",
      severity = "high",
    }))
    assert.are.equal("new", updated[1].issue)
    assert.are.equal("high", updated[1].severity)
  end)

  it("finds first open item by location", function()
    local items = {
      {
        id = "RV-0001",
        file = "a.lua",
        line = 4,
        end_line = 7,
        severity = "low",
        status = "open",
        issue = "x",
        requested_change = "",
        author = nil,
        created_at = "2026-03-28T10:00:00Z",
        updated_at = "2026-03-28T10:00:00Z",
      },
      {
        id = "RV-0002",
        file = "a.lua",
        line = 5,
        end_line = nil,
        severity = "low",
        status = "fixed",
        issue = "y",
        requested_change = "",
        author = nil,
        created_at = "2026-03-28T10:00:00Z",
        updated_at = "2026-03-28T10:00:00Z",
      },
    }

    local found = store.find_by_location(items, "a.lua", 6)
    assert.is_truthy(found)
    assert.are.equal("RV-0001", found.id)
  end)
end)
