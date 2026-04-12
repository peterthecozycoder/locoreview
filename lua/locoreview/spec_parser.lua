local M = {}

local fs         = require("locoreview.fs")
local spec_schema = require("locoreview.spec_schema")
local util       = require("locoreview.util")

local function heading_text(line)
  local m = line:match("^##+ (.+)$")
  return m and m:match("^%s*(.-)%s*$")
end

function M.parse(content, source_path, schema)
  schema = schema or spec_schema.DEFAULT_SCHEMA

  local result = {
    items             = {},
    warnings          = {},
    unparsed_sections = {},
    schema_name       = schema.name,
  }

  if not content or content == "" then
    return result
  end

  local lines          = util.split_lines(content:gsub("\r\n", "\n"))
  local current_section = nil
  local seen_ids        = {}
  local seen_unparsed   = {}

  for lnum, line in ipairs(lines) do
    local heading = heading_text(line)
    if heading then
      local section = spec_schema.lookup_section(schema, heading)
      if section then
        current_section = section
      else
        current_section = nil
        if not seen_unparsed[heading] then
          seen_unparsed[heading] = true
          table.insert(result.unparsed_sections, heading)
        end
      end
    else
      local checkbox, item_id, text = line:match(spec_schema.ITEM_PATTERN)
      if checkbox and item_id then
        if current_section then
          local id_prefix = item_id:match("^([A-Z])")
          if id_prefix ~= current_section.prefix then
            table.insert(result.warnings, string.format(
              "line %d: item %s has prefix %q but section %q expects %q — skipped",
              lnum, item_id, id_prefix, current_section.name, current_section.prefix
            ))
          elseif text == "" then
            table.insert(result.warnings, string.format(
              "line %d: item %s has no text — skipped", lnum, item_id
            ))
          elseif seen_ids[item_id] then
            table.insert(result.warnings, string.format(
              "line %d: duplicate id %s — keeping first occurrence", lnum, item_id
            ))
          else
            seen_ids[item_id] = true
            table.insert(result.items, {
              id          = item_id,
              type        = id_prefix,
              text        = text,
              section     = current_section.name,
              line_start  = lnum,
              line_end    = lnum,
              source_path = source_path or "",
              schema_name = schema.name,
              checked     = (checkbox == "x"),
            })
          end
        end
      end
    end
  end

  return result
end

function M.parse_file(path, schema)
  local content = fs.read(path)
  if not content then
    return {
      items             = {},
      warnings          = { string.format("unable to read file: %s", tostring(path)) },
      unparsed_sections = {},
      schema_name       = (schema or spec_schema.DEFAULT_SCHEMA).name,
    }
  end
  return M.parse(content, path, schema)
end

return M
