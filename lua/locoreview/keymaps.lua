local M = {}

local defaults = {
  open = "<leader>ro",
  add = "<leader>ra",
  add_range = "<leader>rA",
  list = "<leader>rl",
  next = "<leader>rn",
  prev = "<leader>rp",
  mark_fixed = "<leader>rf",
  clean = "<leader>rc",
  reopen = "<leader>rr",
  diff = "<leader>rd",
  file_history = "<leader>rh",
  fix = "<leader>rx",
  edit = "<leader>re",
  delete = "<leader>rD",
  mark_blocked = "<leader>rb",
  mark_wontfix = "<leader>rw",
  refresh = "<leader>rR",
  picker = "<leader>rk",
  toggle_signs = "<leader>rs",
}

local command_for = {
  open = "ReviewOpen",
  add = "ReviewAdd",
  add_range = "ReviewAddRange",
  list = "ReviewList",
  next = "ReviewNext",
  prev = "ReviewPrev",
  mark_fixed = "ReviewMarkFixed",
  clean = "ReviewClean",
  reopen = "ReviewReopen",
  diff = "ReviewDiff",
  file_history = "ReviewFileHistory",
  fix = "ReviewFix",
  edit = "ReviewEdit",
  delete = "ReviewDelete",
  mark_blocked = "ReviewMarkBlocked",
  mark_wontfix = "ReviewMarkWontfix",
  refresh = "ReviewRefresh",
  picker = "ReviewPicker",
  toggle_signs = "ReviewToggleSigns",
}

function M.setup(cfg)
  local keymaps = cfg and cfg.keymaps
  if keymaps == false then
    return
  end
  if type(keymaps) ~= "table" and keymaps ~= true then
    return
  end

  local merged = vim.tbl_extend("force", defaults, type(keymaps) == "table" and keymaps or {})
  for key, lhs in pairs(merged) do
    local cmd = command_for[key]
    if cmd and type(lhs) == "string" and lhs ~= "" then
      vim.keymap.set("n", lhs, "<cmd>" .. cmd .. "<CR>", {
        noremap = true,
        silent = true,
      })
    end
  end
end

return M
