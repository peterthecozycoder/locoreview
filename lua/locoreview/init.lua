local config = require("locoreview.config")
local commands = require("locoreview.commands")
local keymaps = require("locoreview.keymaps")
local signs = require("locoreview.signs")

local M = {}

function M.setup(opts)
  local merged, err = config.setup(opts or {})
  if not merged then
    return nil, err
  end

  commands.register()
  signs.setup()
  keymaps.setup(merged)

  return merged
end

return M
