local M = {}

local fs = require("locoreview.fs")
local git = require("locoreview.git")

local CONTEXT_LINES = 5
local ITEM_ID_PATTERN = "^##%s+(RV%-%d%d%d%d)%s*$"

-- Split text into lines, stripping a trailing empty element from a file that
-- ends with a newline (the common case).
local function split_lines(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

-- Return the review item the cursor is currently positioned on inside a
-- review.md buffer.  Scans backward from the cursor to find the nearest
-- "## RV-NNNN" header, then locates that item in the supplied list.
function M.item_at_cursor(buf, items)
  buf = buf or vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] -- 1-indexed
  -- nvim_buf_get_lines: 0-indexed start, exclusive end → returns lines 1..cursor_line
  local lines = vim.api.nvim_buf_get_lines(buf, 0, cursor_line, false)

  for i = #lines, 1, -1 do
    local id = lines[i]:match(ITEM_ID_PATTERN)
    if id then
      for _, item in ipairs(items) do
        if item.id == id then
          return item
        end
      end
      return nil
    end
  end
  return nil
end

-- Build the left/right diff payload for a review item.
--
-- left_lines  – original file slice with CONTEXT_LINES of surrounding context
-- right_lines – same slice with item.requested_change substituted for the
--               commented range (or identical to left if no suggestion)
-- line_map    – {left_buf_line_index = source_file_line_number (1-indexed)}
-- source_path – absolute path to the source file
-- ctx_start   – first source line included in the slice (1-indexed)
-- ctx_end     – last  source line included in the slice (1-indexed)
-- range_start – item.line
-- range_end   – item.end_line or item.line
-- has_suggestion – bool
--
-- Returns payload, nil   on success
--         nil, err_msg   on failure
function M.build_payload(item)
  local root = git.repo_root()
  if not root then
    return nil, "could not determine repository root"
  end

  local source_path = root .. "/" .. item.file
  local content = fs.read(source_path)
  if not content then
    return nil, "could not read source file: " .. item.file
  end

  local file_lines = split_lines(content)
  local end_line = item.end_line or item.line
  local ctx_start = math.max(1, item.line - CONTEXT_LINES)
  local ctx_end = math.min(#file_lines, end_line + CONTEXT_LINES)

  -- Left buffer: original slice with context
  local left_lines = {}
  local line_map = {}
  for i = ctx_start, ctx_end do
    table.insert(left_lines, file_lines[i] or "")
    line_map[#left_lines] = i
  end

  -- Right buffer: same context with the suggestion substituted in
  local has_suggestion = item.requested_change and item.requested_change ~= ""
  local right_lines = {}

  if has_suggestion then
    for i = ctx_start, item.line - 1 do
      table.insert(right_lines, file_lines[i] or "")
    end
    for _, l in ipairs(split_lines(item.requested_change)) do
      table.insert(right_lines, l)
    end
    for i = end_line + 1, ctx_end do
      table.insert(right_lines, file_lines[i] or "")
    end
  else
    for _, l in ipairs(left_lines) do
      table.insert(right_lines, l)
    end
  end

  return {
    left_lines = left_lines,
    right_lines = right_lines,
    line_map = line_map,
    source_path = source_path,
    ctx_start = ctx_start,
    ctx_end = ctx_end,
    range_start = item.line,
    range_end = end_line,
    has_suggestion = has_suggestion,
  }
end

return M
