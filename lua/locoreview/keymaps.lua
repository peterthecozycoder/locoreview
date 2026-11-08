local M = {}

local defaults = {
  add = "<leader>ra",
  add_range = "<leader>ra",
  show = "<leader>rv",
  list = "<leader>rl",
  pr = "<leader>rP",
}
local commands = {
  add = "ReviewAdd", add_range = "ReviewAdd", show = "ReviewShow",
  list = "ReviewList", pr = "ReviewPR",
}

function M.setup(cfg)
  local keymaps = cfg and cfg.keymaps
  if keymaps == false or (keymaps ~= true and type(keymaps) ~= "table") then return end
  local merged = vim.tbl_extend("force", defaults, type(keymaps) == "table" and keymaps or {})
  for key, command in pairs(commands) do
    local lhs = merged[key]
    if type(lhs) == "string" and lhs ~= "" then
      local visual = key == "add_range"
      vim.keymap.set(visual and "x" or "n", lhs, (visual and ":" or "<cmd>") .. command .. "<CR>", {
        silent = true, desc = command,
      })
    end
  end
end

return M
