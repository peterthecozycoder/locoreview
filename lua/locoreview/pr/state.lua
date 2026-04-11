-- pr/state.lua
-- Shared mutable state for the PR view.
--
-- All pr/ sub-modules require this table directly.  Because Lua tables are
-- passed by reference, every module reads and writes the same object.
--
-- Namespaces are created lazily by `ensure_*_ns()` helpers so they survive
-- buffer lifecycle events without leaving stale IDs.

local M = {}

-- ── State table ───────────────────────────────────────────────────────────────

-- Initial (empty) values.  Used both as the live state and as the template
-- for reset().  Every field that is ever touched must appear here to prevent
-- accidental nil gaps after a reset.
local DEFAULTS = {
  buf               = nil,
  tabpage           = nil,
  line_map          = {},
  fold_ranges       = {},
  file_header_lnums = {},
  hunk_header_lnums = {},
  file_diffs        = {},
  base_ref          = nil,
  timer             = nil,
  timer_end         = nil,
  session_start     = nil,
  -- Sticky header float
  sticky_win        = nil,
  sticky_buf        = nil,
  sticky_autocmd    = nil,
  -- Rhythm mode
  rhythm_mode        = "overview",
  rhythm_queue       = {},
  rhythm_file_idx    = 1,
  rhythm_advance_lhs = nil,
  saved_ui           = {},
  -- Dimming namespaces
  dim_ns            = nil,
  -- Hunk spotlight
  hunk_spot_ns      = nil,
  active_file       = nil,
  active_hunk_lnum  = nil,
  -- Hunk context collapse
  hunk_ctx_ns       = nil,
  hunk_ctx_marks    = {},
  -- Heat map
  heat_ns           = nil,
  -- Action hint bar
  hint_win          = nil,
  hint_buf          = nil,
  hint_autocmd      = nil,
  -- Tint namespace
  tint_ns           = nil,
  -- Cursor persistence
  saved_cursor      = nil,
  saved_anchor      = nil,
  pending_cursor    = nil,
  pending_anchor    = nil,
  -- Session-local hide list
  hidden_files      = {},
  -- Debounce timer for in_progress marking
  _ip_timer         = nil,
}

-- Deep-copy a single default value (tables get a fresh empty table).
local function copy_default(v)
  if type(v) == "table" then return {} end
  return v
end

-- Live state object (shared by reference with all pr/ modules).
local state = {}
for k, v in pairs(DEFAULTS) do state[k] = copy_default(v) end

-- ── Reset helpers ─────────────────────────────────────────────────────────────

-- Reset every state field to its initial value.
-- Called from pr_view.lua close(), render_empty_view(), and BufDelete.
function M.reset()
  for k, v in pairs(DEFAULTS) do
    state[k] = copy_default(v)
  end
end

-- Reset only cursor/anchor fields (used before re-render to restore position).
function M.reset_cursor()
  state.saved_cursor   = nil
  state.saved_anchor   = nil
  state.pending_cursor = nil
  state.pending_anchor = nil
end

-- ── Main namespace ────────────────────────────────────────────────────────────

local _ns = nil
local NS_NAME = "locoreview_pr"

function M.ensure_ns()
  if not _ns then _ns = vim.api.nvim_create_namespace(NS_NAME) end
  return _ns
end

-- Expose the live state table so callers can do `local state = require(...).state`
M.state = state

return M
