-- spec_integration_spec.lua
-- T18–T20 integration tests for spec review.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

if not _G.vim then
  _G.vim = {
    fn = {},
    v = { shell_error = 1 },
    deepcopy = function(t)
      if type(t) ~= "table" then return t end
      local out = {}
      for k, v in pairs(t) do out[k] = _G.vim.deepcopy(v) end
      return out
    end,
  }
end

describe("spec review integration", function()
  local session = require("locoreview.spec_session")
  local store   = require("locoreview.spec_store")

  local function tmpspec(content)
    local path = os.tmpname() .. ".md"
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
    return path
  end

  local function full_spec()
    return table.concat({
      "# Feature Spec",
      "",
      "## Goals",
      "",
      "- [ ] G1: Fast startup",
      "- [ ] G2: Low memory",
      "",
      "## Requirements",
      "",
      "- [ ] R1: User can open spec",
      "- [ ] R2: User can mark items",
      "- [ ] R3: State persists",
      "",
      "## Open Questions",
      "",
      "- [ ] Q1: Which format?",
    }, "\n")
  end

  after_each(function()
    session.close()
  end)

  -- T18: Full flow — open spec, mark ALL items reviewed, summary shows 100%.
  it("T18: full flow - all items reviewed, summary shows 100%", function()
    local path = tmpspec(full_spec())
    local result, err = session.open(path)
    assert.is_nil(err)
    assert.is_truthy(result)

    local items = session.all_items()
    assert.are.equal(6, #items)  -- G1 G2 R1 R2 R3 Q1

    -- Mark every item reviewed by cycling through all items.
    for i = 1, #items do
      -- Navigate to item i directly via next() / jump
      local item = items[i]
      -- Use jump_to_section or direct cursor manipulation:
      -- simplest: mark current, then advance.
      session.mark("reviewed")
      if i < #items then
        session.next()
      end
    end

    local s = session.summary()
    assert.are.equal(6, s.total)
    assert.are.equal(6, s.by_status.reviewed)
    assert.are.equal(0, s.by_status.unreviewed)
    assert.are.equal(0, s.review_debt)

    os.remove(path)
  end)

  -- T19: Resume — open, mark R1 reviewed, close, reopen, R1 is still reviewed.
  it("T19: resume - reviewed state persists across reopen", function()
    local path = tmpspec(full_spec())

    -- First session: open and mark R1 reviewed.
    local result, err = session.open(path)
    assert.is_nil(err)
    assert.is_truthy(result)

    -- Cursor starts at first unreviewed (G1 at index 1).
    -- Jump to R1 in requirements section.
    local r1_item = session.jump_to_section("requirements")
    assert.is_truthy(r1_item)
    assert.are.equal("R1", r1_item.id)

    local ok, mark_err = session.mark("reviewed")
    assert.is_nil(mark_err)
    assert.is_true(ok)
    assert.are.equal("reviewed", session.all_states()["R1"].status)

    session.close()

    -- Second session: reopen the same file.
    local result2, err2 = session.open(path)
    assert.is_nil(err2)
    assert.is_truthy(result2)

    -- R1 must still be reviewed.
    assert.are.equal("reviewed", session.all_states()["R1"].status)
    -- Other items are unreviewed.
    assert.are.equal("unreviewed", session.all_states()["G1"].status)

    os.remove(path)
  end)

  -- T20: Existing PR review mode unaffected after ReviewSpecOpen and close.
  it("T20: PR review store is unaffected by spec session open and close", function()
    local pr_store  = require("locoreview.store")
    local pr_parser = require("locoreview.parser")

    -- Write a minimal PR review file.
    local pr_path = os.tmpname() .. ".md"
    local pr_f = assert(io.open(pr_path, "w"))
    pr_f:write(table.concat({
      "# Review Comments",
      "",
      "## RV-0001",
      "file: src/main.lua",
      "line: 10",
      "end_line: ",
      "severity: medium",
      "status: open",
      "author: reviewer",
      "created_at: 2026-01-01T00:00:00Z",
      "updated_at: 2026-01-01T00:00:00Z",
      "",
      "issue:",
      "This is a test review item.",
      "",
      "requested_change:",
      "Please fix this.",
      "",
      "---",
    }, "\n"))
    pr_f:close()

    -- Open a spec session.
    local spec_path = tmpspec(full_spec())
    local spec_result, serr = session.open(spec_path)
    assert.is_nil(serr)
    assert.is_truthy(spec_result)

    -- Mark something in spec.
    session.mark("reviewed")

    -- Now load PR review items — must work correctly, independent of spec session.
    local pr_items, pr_err = pr_store.load(pr_path)
    assert.is_nil(pr_err, "PR store.load should not error: " .. tostring(pr_err))
    assert.is_truthy(pr_items)
    assert.are.equal(1, #pr_items)
    assert.are.equal("RV-0001", pr_items[1].id)
    assert.are.equal("open", pr_items[1].status)

    -- Close spec session; PR store should still be accessible.
    session.close()
    assert.is_false(session.is_open())

    local pr_items2, _ = pr_store.load(pr_path)
    assert.is_truthy(pr_items2)
    assert.are.equal(1, #pr_items2)

    os.remove(spec_path)
    os.remove(pr_path)
  end)

  -- Extra: E1 — spec with headings but no items: 0-item summary, no crash.
  it("E1: spec with no recognised items produces zero summary", function()
    local path = tmpspec(table.concat({
      "# Spec",
      "",
      "## Requirements",
      "",
      "Just prose here, no checkbox items.",
    }, "\n"))
    local result, err = session.open(path)
    assert.is_nil(err)
    assert.is_truthy(result)
    assert.are.equal(0, #result.parse_result.items)

    local s = session.summary()
    assert.are.equal(0, s.total)
    assert.are.equal(0, s.by_status.reviewed)
    assert.are.equal(0, s.by_status.unreviewed)
    assert.are.equal(0, s.review_debt)

    os.remove(path)
  end)

  -- Extra: E2 — duplicate IDs: first occurrence wins, warning emitted.
  it("E2: duplicate item IDs - first wins, warning recorded", function()
    local path = tmpspec(table.concat({
      "# Spec",
      "",
      "## Requirements",
      "",
      "- [ ] R1: First definition",
      "- [ ] R1: Duplicate definition",
      "- [ ] R2: Normal item",
    }, "\n"))
    local result, err = session.open(path)
    assert.is_nil(err)

    -- Only 2 items (R1 first, R2); duplicate R1 skipped.
    assert.are.equal(2, #result.parse_result.items)
    assert.are.equal("R1", result.parse_result.items[1].id)
    assert.are.equal("First definition", result.parse_result.items[1].text)

    -- At least one warning about the duplicate.
    local has_dup_warn = false
    for _, w in ipairs(result.warnings or {}) do
      if w:find("duplicate") or w:find("R1") then
        has_dup_warn = true
      end
    end
    assert.is_true(has_dup_warn, "expected a duplicate ID warning")

    os.remove(path)
  end)

  -- Extra: E3 — spec changes after state saved: stale IDs discarded on reload.
  it("E3: stale IDs from previous parse are discarded on reload with warning", function()
    -- Write spec with R1, R2, R3.
    local path = tmpspec(full_spec())
    local r1, _ = session.open(path)
    assert.is_truthy(r1)
    session.jump_to_section("requirements")
    session.mark("reviewed")   -- R1 reviewed
    session.close()

    -- Now overwrite spec removing R1.
    local new_content = table.concat({
      "# Feature Spec",
      "",
      "## Requirements",
      "",
      "- [ ] R2: User can mark items",
      "- [ ] R3: State persists",
    }, "\n")
    local f = assert(io.open(path, "w"))
    f:write(new_content)
    f:close()

    -- Reopen: R1 is now stale.
    local result2, err2 = session.open(path)
    assert.is_nil(err2)

    -- R1 must not appear in states.
    assert.is_nil(session.all_states()["R1"])
    -- R2 and R3 are unreviewed.
    assert.are.equal("unreviewed", session.all_states()["R2"].status)

    -- A stale warning must have been issued.
    local has_stale = false
    for _, w in ipairs(result2.warnings or {}) do
      if w:find("stale") then has_stale = true end
    end
    assert.is_true(has_stale, "expected a stale-state warning")

    os.remove(path)
  end)
end)
