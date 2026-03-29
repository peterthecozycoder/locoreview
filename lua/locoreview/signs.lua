local M = {}

local config = require("locoreview.config")
local git = require("locoreview.git")
local util = require("locoreview.util")

local GROUP = "locoreview.nvim"
local DEFAULT_PRIORITY = 20
local STATUS_SIGN = {
  open = "ReviewOpenSign",
  blocked = "ReviewBlockedSign",
}
local ns = nil
local enabled = true
local last_items = {}

local function sign_for_status(status)
  return STATUS_SIGN[status] or STATUS_SIGN.open
end

local function can_use_signs()
  return vim and vim.fn and vim.api
end

function M.setup()
  if not can_use_signs() then
    return
  end

  ns = vim.api.nvim_create_namespace("locoreview.nvim")
  local cfg = config.get()
  enabled = not (cfg.signs and cfg.signs.enabled == false)

  vim.fn.sign_define("ReviewOpenSign", {
    text = "R",
    texthl = "DiagnosticSignWarn",
  })
  vim.fn.sign_define("ReviewBlockedSign", {
    text = "B",
    texthl = "DiagnosticSignHint",
  })
end

function M.clear()
  if not can_use_signs() then
    return
  end

  vim.fn.sign_unplace(GROUP)
  if ns then
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    end
  end
end

function M.refresh(items)
  if not can_use_signs() then
    return
  end

  last_items = items or last_items
  M.clear()
  if not enabled then
    return
  end

  local cfg = config.get()
  local root = git.repo_root()
  local show_virtual = cfg.signs and cfg.signs.virtual_text == true
  local priority = (cfg.signs and cfg.signs.priority) or DEFAULT_PRIORITY

  local per_file = {}
  for _, item in ipairs(last_items) do
    if item.status == "open" or item.status == "blocked" then
      local abs = root .. "/" .. item.file
      per_file[abs] = per_file[abs] or {}
      local existing = per_file[abs][item.line]
      if not existing or (existing.status == "open" and item.status == "blocked") then
        per_file[abs][item.line] = item
      end
    end
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local abs = vim.api.nvim_buf_get_name(bufnr)
      local lines = per_file[abs]
      if lines then
        for line, item in pairs(lines) do
          vim.fn.sign_place(0, GROUP, sign_for_status(item.status), bufnr, {
            lnum = line,
            priority = priority,
          })

          if show_virtual and ns then
            vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
              virt_text = { { "review: " .. util.truncate(item.issue, 60), "Comment" } },
              virt_text_pos = "eol",
            })
          end
        end
      end
    end
  end
end

function M.toggle()
  enabled = not enabled
  if enabled then
    M.refresh(last_items)
  else
    M.clear()
  end
  return enabled
end

return M
