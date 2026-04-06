local M = {}
local util = require("locoreview.util")
local types = require("locoreview.types")

M.defaults = {
  review_file = "review.md",
  base_branch = nil,
  keymaps = true,
  default_severity = "medium",
  default_author = nil,
  signs = {
    enabled = true,
    priority = 20,
  },
  picker = {
    enabled = true,
    backend = "auto",
  },
  diff_only = false,
  agent = {
    enabled = false,
    cmd = "agent",
    open_in_split = true,
  },
  pr_view = {
    auto_advance_on_viewed = true,
    micro_rewards          = true,
    risky_threshold        = 150,   -- lines changed to flag a file as "risky"
    generated_patterns     = nil,   -- extra patterns appended to built-in list
    action_hints           = true,  -- show bottom hint bar
    rhythm_advance_key     = nil,   -- auto: <Space>, or <Tab> when mapleader is <Space>
  },
}

local function deep_merge(base, override)
  local out = util.deepcopy(base or {})
  for key, value in pairs(override or {}) do
    if type(value) == "table" and type(out[key]) == "table" then
      out[key] = deep_merge(out[key], value)
    else
      out[key] = util.deepcopy(value)
    end
  end
  return out
end

local function notify_error(msg)
  if type(vim) == "table" and vim.notify then
    vim.notify("[review] " .. msg, vim.log.levels.ERROR)
    return
  end
  io.stderr:write("[review] " .. msg .. "\n")
end

local state = util.deepcopy(M.defaults)

local VALID_PICKER_BACKEND = {
  auto = true,
  telescope = true,
  fzf_lua = true,
  snacks = true,
  none = true,
}

function M.normalize(opts)
  local normalized = deep_merge(M.defaults, opts or {})

  if not types.SEVERITY[normalized.default_severity] then
    return nil, string.format("invalid default_severity: %s", tostring(normalized.default_severity))
  end

  if type(normalized.picker) ~= "table" then
    return nil, string.format("picker must be a table, got: %s", type(normalized.picker))
  end

  if type(normalized.picker.backend) ~= "string" then
    return nil, string.format("picker.backend must be a string, got: %s", type(normalized.picker.backend))
  end

  if not VALID_PICKER_BACKEND[normalized.picker.backend] then
    return nil, string.format("invalid picker.backend: %s", tostring(normalized.picker.backend))
  end

  return normalized
end

function M.setup(opts)
  local normalized, err = M.normalize(opts)
  if not normalized then
    notify_error(err)
    return nil, err
  end

  state = normalized
  return state
end

function M.get()
  return state
end

return M
