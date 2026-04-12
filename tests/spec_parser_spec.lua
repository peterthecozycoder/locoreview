package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

describe("spec_parser", function()
  local parser = require("locoreview.spec_parser")

  -- T1: Parses spec_basic.md — correct item count, IDs, types, sections, line numbers.
  it("T1: parses spec_basic.md fixture", function()
    local result = parser.parse_file("tests/fixtures/spec_basic.md")
    assert.are.equal(0, #result.warnings)
    -- 2 goals + 3 requirements + 1 non-goal + 2 questions + 1 edge-case + 2 acceptance + 1 flow
    assert.are.equal(12, #result.items)

    local function find(id)
      for _, item in ipairs(result.items) do
        if item.id == id then return item end
      end
    end

    local g1 = find("G1")
    assert.is_truthy(g1)
    assert.are.equal("G", g1.type)
    assert.are.equal("goals", g1.section)
    assert.is_false(g1.checked)
    assert.is_truthy(g1.text:find("authentication"))

    local g2 = find("G2")
    assert.is_truthy(g2)
    assert.is_true(g2.checked)

    local r1 = find("R1")
    assert.is_truthy(r1)
    assert.are.equal("R", r1.type)
    assert.are.equal("requirements", r1.section)

    local q1 = find("Q1")
    assert.is_truthy(q1)
    assert.are.equal("questions", q1.section)

    local e1 = find("E1")
    assert.is_truthy(e1)
    assert.are.equal("edge-cases", e1.section)

    local a1 = find("A1")
    assert.is_truthy(a1)
    assert.are.equal("acceptance", a1.section)

    local f1 = find("F1")
    assert.is_truthy(f1)
    assert.are.equal("flow", f1.section)
  end)

  -- T2: Extracts checked = true for [x] items.
  it("T2: extracts checked state correctly", function()
    local result = parser.parse_file("tests/fixtures/spec_basic.md")
    local function find(id)
      for _, item in ipairs(result.items) do
        if item.id == id then return item end
      end
    end
    assert.is_false(find("G1").checked)
    assert.is_true(find("G2").checked)
    assert.is_true(find("R3").checked)
    assert.is_false(find("R1").checked)
  end)

  -- T3: Warns on duplicate IDs; first occurrence kept.
  it("T3: warns on duplicate IDs and keeps first occurrence", function()
    local result = parser.parse_file("tests/fixtures/spec_malformed.md")

    local dup_warn = false
    for _, w in ipairs(result.warnings) do
      if w:find("duplicate id R3") then
        dup_warn = true
        break
      end
    end
    assert.is_true(dup_warn, "expected duplicate-id warning for R3")

    -- Count R3 occurrences in items — should be exactly one.
    local r3_count = 0
    for _, item in ipairs(result.items) do
      if item.id == "R3" then r3_count = r3_count + 1 end
    end
    assert.are.equal(1, r3_count)
  end)

  -- T4: Returns empty items (no error) for empty sections.
  it("T4: returns empty items for empty sections", function()
    local content = "# Spec\n\n## Requirements\n\n## Goals\n"
    local result = parser.parse(content)
    assert.are.equal(0, #result.items)
    assert.are.equal(0, #result.warnings)
  end)

  -- T5: Ignores unsupported prose without crashing.
  it("T5: ignores prose lines without crashing", function()
    local content = table.concat({
      "# Spec",
      "",
      "This is a paragraph of prose that should be ignored.",
      "",
      "## Requirements",
      "",
      "Some more prose here.",
      "",
      "- [ ] R1: A real item",
      "",
      "Another prose line.",
    }, "\n")
    local result = parser.parse(content)
    assert.are.equal(1, #result.items)
    assert.are.equal("R1", result.items[1].id)
    assert.are.equal(0, #result.warnings)
  end)

  -- T6: Returns warnings for malformed items (no text after prefix).
  it("T6: warns on items with no text after prefix", function()
    local result = parser.parse_file("tests/fixtures/spec_malformed.md")
    local empty_warn = false
    for _, w in ipairs(result.warnings) do
      if w:find("no text") then
        empty_warn = true
        break
      end
    end
    assert.is_true(empty_warn, "expected empty-text warning for R4")
  end)

  -- T7: Handles spec with no recognised sections — items = [], warnings = [].
  it("T7: returns empty result for spec with no recognised sections", function()
    local content = table.concat({
      "# Spec",
      "",
      "## Introduction",
      "",
      "- [ ] I1: This section is not in the schema",
      "",
      "## Background",
      "",
      "Just prose here.",
    }, "\n")
    local result = parser.parse(content)
    assert.are.equal(0, #result.items)
    assert.are.equal(0, #result.warnings)
    assert.are.equal(2, #result.unparsed_sections)
  end)

  -- Extra: items carry source_path and schema_name.
  it("items include source_path and schema_name", function()
    local result = parser.parse_file("tests/fixtures/spec_basic.md")
    assert.is_truthy(result.items[1].source_path:find("spec_basic.md"))
    assert.are.equal("default_spec", result.items[1].schema_name)
  end)

  -- Extra: line_start is set correctly.
  it("items carry correct line_start", function()
    local result = parser.parse_file("tests/fixtures/spec_basic.md")
    local function find(id)
      for _, item in ipairs(result.items) do
        if item.id == id then return item end
      end
    end
    -- G1 is on line 5 in spec_basic.md (blank line separates heading from first item)
    assert.are.equal(5, find("G1").line_start)
    assert.are.equal(5, find("G1").line_end)
  end)

  -- Extra: items in unrecognised sections are skipped and section is tracked.
  it("items in unrecognised sections are skipped, heading tracked", function()
    local result = parser.parse_file("tests/fixtures/spec_malformed.md")
    local has_unsupported = false
    for _, h in ipairs(result.unparsed_sections) do
      if h == "Unsupported Section" then
        has_unsupported = true
        break
      end
    end
    assert.is_true(has_unsupported)
  end)
end)
