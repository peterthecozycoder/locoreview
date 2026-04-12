local M = {}

M.DEFAULT_SCHEMA = {
  name = "default_spec",

  sections = {
    { name = "goals",        aliases = { "goals", "goal" },               prefix = "G" },
    { name = "requirements", aliases = { "requirements", "requirement" }, prefix = "R" },
    { name = "non-goals",    aliases = { "non-goals", "non-goal" },       prefix = "N" },
    { name = "questions",    aliases = { "open questions", "questions" }, prefix = "Q" },
    { name = "edge-cases",   aliases = { "edge cases", "edge case" },     prefix = "E" },
    { name = "acceptance",   aliases = { "acceptance", "done when" },     prefix = "A" },
    { name = "flow",         aliases = { "user flow", "flow" },           prefix = "F" },
  },

  validation = {
    check_duplicate_ids = true,
    check_empty_text    = true,
  },
}

-- Build a lookup table: lowercased alias → section entry.
function M.alias_map(schema)
  local map = {}
  for _, section in ipairs((schema or M.DEFAULT_SCHEMA).sections) do
    for _, alias in ipairs(section.aliases) do
      map[alias:lower()] = section
    end
  end
  return map
end

-- Cached alias map for the default schema — avoids rebuilding on every heading line.
local _default_alias_map = M.alias_map(M.DEFAULT_SCHEMA)

function M.lookup_section(schema, heading)
  if not heading then
    return nil
  end
  local map = (schema == nil or schema == M.DEFAULT_SCHEMA)
              and _default_alias_map
              or  M.alias_map(schema)
  return map[heading:lower()]
end

function M.prefix_for_section(schema, section_name)
  for _, section in ipairs((schema or M.DEFAULT_SCHEMA).sections) do
    if section.name == section_name then
      return section.prefix
    end
  end
  return nil
end

-- Matches: `- [ ] R1: text` or `- [x] Q3: some text`
-- Captures: (checkbox_char, id_with_number, text)
M.ITEM_PATTERN = "^%-%s+%[([x ])%]%s+([A-Z]%d+):%s*(.-)%s*$"

return M
