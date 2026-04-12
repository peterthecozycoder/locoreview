package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

-- Stub vim for headless Busted.
if not _G.vim then
  _G.vim = {
    -- systemlist intentionally absent so fs.repo_root() falls through to io.popen
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

describe("spec_session", function()
  local session = require("locoreview.spec_session")

  -- Helper: write a temp spec file.
  local function tmpspec(content)
    local path = os.tmpname() .. ".md"
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
    return path
  end

  -- Helper: a small valid spec with R1, R2, R3, Q1.
  local function make_spec()
    return table.concat({
      "# Spec",
      "",
      "## Requirements",
      "",
      "- [ ] R1: First requirement",
      "- [ ] R2: Second requirement",
      "- [ ] R3: Third requirement",
      "",
      "## Open Questions",
      "",
      "- [ ] Q1: Should we foo?",
    }, "\n")
  end

  after_each(function()
    session.close()
  end)

  -- T12: next() skips reviewed items, returns next unreviewed.
  it("T12: next_unreviewed skips reviewed items", function()
    local path = tmpspec(make_spec())
    local result, err = session.open(path)
    assert.is_nil(err)
    assert.is_truthy(result)

    -- Mark R1 reviewed.
    session.mark("reviewed")

    -- Advance; should land on R2 (first unreviewed after R1).
    local item = session.next_unreviewed()
    assert.is_truthy(item)
    assert.are.equal("R2", item.id)

    os.remove(path)
  end)

  -- T13: summary() returns accurate counts per type and status.
  it("T13: summary returns accurate counts", function()
    local path = tmpspec(make_spec())
    session.open(path)

    -- Initially all unreviewed.
    local s = session.summary()
    assert.are.equal(4, s.total)
    assert.are.equal(4, s.by_status.unreviewed)
    assert.are.equal(0, s.by_status.reviewed)

    -- Mark R1 reviewed, Q1 unclear.
    session.mark("reviewed")       -- current = R1
    -- Move to Q1 (index 4).
    session.next(); session.next(); session.next()  -- R2, R3, Q1
    session.mark("unclear")

    local s2 = session.summary()
    assert.are.equal(1, s2.by_status.reviewed)
    assert.are.equal(1, s2.by_status.unclear)
    assert.are.equal(2, s2.by_status.unreviewed)
    assert.are.equal(1, s2.review_debt)   -- unclear only (no blocked)
    assert.are.equal(1, #s2.unclear_items)

    os.remove(path)
  end)

  -- T14: mark("reviewed") updates state and cursor can advance.
  it("T14: mark reviewed updates state", function()
    local path = tmpspec(make_spec())
    session.open(path)

    local item = session.current_item()
    assert.are.equal("R1", item.id)
    assert.are.equal("unreviewed", session.current_state().status)

    local ok, err = session.mark("reviewed")
    assert.is_nil(err)
    assert.is_true(ok)

    assert.are.equal("reviewed", session.all_states()["R1"].status)

    os.remove(path)
  end)

  -- T15: Invalid transition returns error, state unchanged.
  it("T15: invalid transition returns error and leaves state unchanged", function()
    local path = tmpspec(make_spec())
    session.open(path)

    -- Start: unreviewed. Try: unreviewed → blocked (valid).
    session.mark("blocked")
    assert.are.equal("blocked", session.all_states()["R1"].status)

    -- Now: blocked → reviewed is invalid per spec types.
    local ok, err = session.mark("reviewed")
    assert.is_truthy(err)
    -- State is still blocked.
    assert.are.equal("blocked", session.all_states()["R1"].status)

    os.remove(path)
  end)

  -- T16: set_note() persists note without changing status.
  it("T16: set_note persists note and does not change status", function()
    local path = tmpspec(make_spec())
    session.open(path)

    local ok, err = session.set_note("needs discussion")
    assert.is_nil(err)
    assert.is_true(ok)

    local state = session.current_state()
    assert.are.equal("needs discussion", state.note)
    assert.are.equal("unreviewed", state.status)

    os.remove(path)
  end)

  -- T17: open() on file with no recognised items shows 0-item summary, no crash.
  it("T17: open with no recognised items shows zero summary, no crash", function()
    local path = tmpspec("# Empty Spec\n\nJust prose, no items.\n")
    local result, err = session.open(path)
    assert.is_nil(err)
    assert.is_truthy(result)
    assert.are.equal(0, #result.parse_result.items)

    local s = session.summary()
    assert.are.equal(0, s.total)
    assert.are.equal(0, s.by_status.unreviewed)

    os.remove(path)
  end)

  -- Extra: prev() and next() wrap correctly.
  it("prev and next wrap around item list", function()
    local path = tmpspec(make_spec())
    session.open(path)

    -- cursor starts at 1 (R1). prev() should wrap to last item (Q1 = index 4).
    local item = session.prev()
    assert.is_truthy(item)
    assert.are.equal("Q1", item.id)

    -- next() from last wraps to first.
    item = session.next()
    assert.are.equal("R1", item.id)

    os.remove(path)
  end)

  -- Extra: jump_to_section filters navigation context.
  it("jump_to_section moves cursor to first item in section", function()
    local path = tmpspec(make_spec())
    session.open(path)

    local item = session.jump_to_section("questions")
    assert.is_truthy(item)
    assert.are.equal("Q1", item.id)
    assert.are.equal(item.id, session.current_item().id)

    os.remove(path)
  end)

  -- Extra: is_open returns false after close.
  it("is_open returns false after close", function()
    local path = tmpspec(make_spec())
    session.open(path)
    assert.is_true(session.is_open())
    session.close()
    assert.is_false(session.is_open())
    os.remove(path)
  end)
end)
