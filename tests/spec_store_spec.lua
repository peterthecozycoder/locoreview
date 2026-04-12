package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

-- Stub vim so modules that touch vim.fn don't crash in headless Busted.
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

describe("spec_store", function()
  local store   = require("locoreview.spec_store")
  local parser  = require("locoreview.spec_parser")

  -- Helper: write a temp file and return its path.
  local function tmpfile(content)
    local path = os.tmpname() .. ".md"
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
    return path
  end

  -- Helper: small valid spec content.
  local function basic_spec()
    return table.concat({
      "# Spec",
      "",
      "## Requirements",
      "",
      "- [ ] R1: User can login",
      "- [x] R2: User can logout",
      "",
      "## Goals",
      "",
      "- [ ] G1: Fast response",
    }, "\n")
  end

  -- T8: Round-trips state through save() / load().
  it("T8: round-trips state through save and load", function()
    local spec_path = tmpfile(basic_spec())

    -- Load initial state (all unreviewed).
    local result, err = store.load(spec_path)
    assert.is_nil(err)
    assert.is_truthy(result)
    assert.is_truthy(result.states)

    -- Mark R1 as reviewed.
    result.states["R1"].status = "reviewed"

    -- Save.
    local ok, save_err = store.save(spec_path, result.states, result.parse_result)
    assert.is_nil(save_err)
    assert.is_true(ok)

    -- Reload.
    local result2, err2 = store.load(spec_path)
    assert.is_nil(err2)
    assert.are.equal("reviewed", result2.states["R1"].status)
    assert.are.equal("unreviewed", result2.states["R2"].status)

    os.remove(spec_path)
  end)

  -- T9: Missing sidecar treated as all-unreviewed.
  it("T9: missing sidecar produces all-unreviewed states", function()
    local spec_path = tmpfile(basic_spec())

    local result, err = store.load(spec_path)
    assert.is_nil(err)

    for _, item in ipairs(result.parse_result.items) do
      assert.are.equal("unreviewed", result.states[item.id].status,
        "expected unreviewed for " .. item.id)
    end

    os.remove(spec_path)
  end)

  -- T10: Stale item IDs (not in current parse) are discarded on load.
  it("T10: stale item IDs are discarded on load", function()
    local spec_path = tmpfile(basic_spec())

    -- Load and save with a phantom item.
    local result, _ = store.load(spec_path)
    result.states["X99"] = {
      item_id    = "X99",
      status     = "reviewed",
      note       = "",
      updated_at = "2026-01-01T00:00:00Z",
    }
    store.save(spec_path, result.states, result.parse_result)

    -- Reload — X99 should not appear.
    local result2, _ = store.load(spec_path)
    assert.is_nil(result2.states["X99"])

    -- Warning should mention stale entries.
    local has_stale_warn = false
    for _, w in ipairs(result2.warnings) do
      if w:find("stale") then has_stale_warn = true end
    end
    assert.is_true(has_stale_warn, "expected a stale-entry warning")

    os.remove(spec_path)
  end)

  -- T11: Atomic write — save() does not corrupt existing sidecar on success.
  it("T11: save writes atomically and existing sidecar is not corrupted", function()
    local spec_path = tmpfile(basic_spec())

    local result, _ = store.load(spec_path)
    result.states["R1"].status = "reviewed"
    local ok = store.save(spec_path, result.states, result.parse_result)
    assert.is_truthy(ok)

    -- A second save with different data should not corrupt first.
    result.states["R2"].status = "unclear"
    store.save(spec_path, result.states, result.parse_result)

    local result2, _ = store.load(spec_path)
    assert.are.equal("reviewed", result2.states["R1"].status)
    assert.are.equal("unclear",  result2.states["R2"].status)

    os.remove(spec_path)
  end)

  -- Extra: transition validates and rejects invalid moves.
  it("transition allows valid and rejects invalid transitions", function()
    local states = {
      R1 = { item_id = "R1", status = "unreviewed", note = "", updated_at = "2026-01-01T00:00:00Z" },
    }

    local next_states, err = store.transition(states, "R1", "reviewed")
    assert.is_nil(err)
    assert.are.equal("reviewed", next_states["R1"].status)

    local _, err2 = store.transition(next_states, "R1", "blocked")
    assert.is_truthy(err2)
    assert.is_truthy(err2:find("invalid transition"))
  end)

  -- Extra: transition returns error for unknown item.
  it("transition returns error for unknown item id", function()
    local _, err = store.transition({}, "NOPE", "reviewed")
    assert.is_truthy(err)
    assert.is_truthy(err:find("not found"))
  end)
end)
