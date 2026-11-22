package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return content
end

describe("review parser", function()
  local parser = require("locoreview.parser")
  local formatter = require("locoreview.formatter")

  it("parses basic fixture", function()
    local items = assert(parser.parse(read_file("tests/fixtures/review_basic.md")))
    assert.are.equal(2, #items)
    assert.are.equal("RV-0001", items[1].id)
    assert.are.equal("lua/review/store.lua", items[1].file)
    assert.are.equal(42, items[1].line)
    assert.is_nil(items[1].end_line)
    assert.are.equal("open", items[1].status)
    assert.are.equal("medium", items[1].severity)
    assert.are.equal("peter", items[1].author)
  end)

  it("parses multiline fields without trimming inner lines", function()
    local items = assert(parser.parse(read_file("tests/fixtures/review_multiline.md")))
    assert.are.equal(1, #items)
    assert.are.equal("First line of issue.\nSecond line of issue.\n\nThird paragraph.", items[1].issue)
    assert.are.equal("Do this.\nThen this.\n\nAnd this.", items[1].requested_change)
  end)

  it("parses mixed statuses", function()
    local items = assert(parser.parse(read_file("tests/fixtures/review_mixed_status.md")))
    local statuses = {}
    for _, item in ipairs(items) do
      table.insert(statuses, item.status)
    end
    assert.same({ "open", "fixed", "blocked", "wontfix" }, statuses)
  end)

  it("returns error on duplicate IDs", function()
    local content = table.concat({
      "# Review Comments",
      "",
      "## RV-0001",
      "file: a.lua",
      "line: 1",
      "end_line:",
      "severity: low",
      "status: open",
      "author:",
      "created_at: 2026-03-28T10:00:00Z",
      "updated_at: 2026-03-28T10:00:00Z",
      "",
      "issue:",
      "a",
      "",
      "requested_change:",
      "b",
      "",
      "---",
      "",
      "## RV-0001",
      "file: b.lua",
      "line: 2",
      "end_line:",
      "severity: low",
      "status: open",
      "author:",
      "created_at: 2026-03-28T10:00:00Z",
      "updated_at: 2026-03-28T10:00:00Z",
      "",
      "issue:",
      "c",
      "",
      "requested_change:",
      "d",
      "",
      "---",
      "",
    }, "\n")
    local _, err = parser.parse(content)
    assert.is_truthy(err)
    assert.is_truthy(err:match("duplicate id"))
  end)

  it("returns error on missing required file field", function()
    local content = table.concat({
      "# Review Comments",
      "",
      "## RV-0001",
      "line: 1",
      "end_line:",
      "severity: low",
      "status: open",
      "author:",
      "created_at: 2026-03-28T10:00:00Z",
      "updated_at: 2026-03-28T10:00:00Z",
      "",
      "issue:",
      "a",
      "",
      "requested_change:",
      "b",
      "",
      "---",
      "",
    }, "\n")
    local _, err = parser.parse(content)
    assert.is_truthy(err)
    assert.is_truthy(err:match("missing required field: file"))
  end)

  it("returns error on unknown status", function()
    local content = table.concat({
      "# Review Comments",
      "",
      "## RV-0001",
      "file: a.lua",
      "line: 1",
      "end_line:",
      "severity: low",
      "status: unknown",
      "author:",
      "created_at: 2026-03-28T10:00:00Z",
      "updated_at: 2026-03-28T10:00:00Z",
      "",
      "issue:",
      "a",
      "",
      "requested_change:",
      "b",
      "",
      "---",
      "",
    }, "\n")
    local _, err = parser.parse(content)
    assert.is_truthy(err)
    assert.is_truthy(err:match("unknown status"))
  end)

  it("formats sorted canonical output", function()
    local items = {
      {
        id = "RV-0002",
        file = "b.lua",
        line = 2,
        end_line = nil,
        severity = "medium",
        status = "open",
        author = nil,
        created_at = "2026-03-28T10:00:00Z",
        updated_at = "2026-03-28T10:00:00Z",
        issue = "b",
        requested_change = "",
      },
      {
        id = "RV-0001",
        file = "a.lua",
        line = 1,
        end_line = nil,
        severity = "low",
        status = "fixed",
        author = "alice",
        created_at = "2026-03-28T10:00:00Z",
        updated_at = "2026-03-28T10:00:00Z",
        issue = "a",
        requested_change = "c",
      },
    }

    local out = formatter.format(items)
    assert.are.equal("# Review Comments", out:sub(1, 17))
    assert.is_truthy(out:find("## RV%-0001"))
    assert.is_truthy(out:find("## RV%-0002"))
    assert.is_true(out:find("## RV%-0001") < out:find("## RV%-0002"))
    assert.are.equal("\n", out:sub(-1))
  end)

  it("round-trips parse -> format -> parse", function()
    local first = assert(parser.parse(read_file("tests/fixtures/review_basic.md")))
    local serialized = formatter.format(first)
    local second = assert(parser.parse(serialized))
    assert.are.equal(#first, #second)
    assert.same(first, second)
  end)
end)
