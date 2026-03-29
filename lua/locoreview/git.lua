local M = {}

local function run_list(cmd)
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, table.concat(out or {}, "\n")
  end
  return out
end

local function branch_exists(branch)
  vim.fn.system({ "git", "rev-parse", "--verify", "--quiet", branch })
  return vim.v.shell_error == 0
end

function M.repo_root()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 then
    return vim.fn.getcwd()
  end

  local root = out[1]
  if not root or root == "" then
    return vim.fn.getcwd()
  end

  return root
end

function M.base_branch(cfg)
  if cfg and cfg.base_branch and cfg.base_branch ~= "" then
    return cfg.base_branch
  end

  local symbolic, _ = run_list({ "git", "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD" })
  if symbolic and symbolic[1] and symbolic[1] ~= "" then
    local branch = symbolic[1]:gsub("^refs/remotes/", "")
    if branch ~= "" then
      return branch
    end
  end

  if branch_exists("origin/main") then
    return "origin/main"
  end

  if branch_exists("origin/master") then
    return "origin/master"
  end

  return "origin/main"
end

function M.changed_lines(file, base_branch)
  if not file or file == "" then
    return {}, "file is required"
  end

  local root = M.repo_root()
  local rel = file
  if vim.startswith(file, root .. "/") then
    rel = file:sub(#root + 2)
  end

  local base = base_branch or M.base_branch({})
  local diff, err = run_list({ "git", "diff", "--unified=0", base .. "...HEAD", "--", rel })
  if not diff then
    return {}, err
  end

  local ranges = {}
  for _, line in ipairs(diff) do
    local start_s, len_s = line:match("^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
    if not start_s then
      start_s, len_s = line:match("^@@ %-%d+ %+(%d+) @@")
    end
    if start_s then
      local start_n = tonumber(start_s)
      local len_n = tonumber(len_s)
      if len_n == nil then
        len_n = 1
      end
      if len_n > 0 then
        table.insert(ranges, {
          start = start_n,
          ["end"] = start_n + len_n - 1,
        })
      end
    end
  end

  return ranges
end

function M.is_line_changed(file, line, base_branch)
  local ranges = M.changed_lines(file, base_branch)
  local lnum = tonumber(line) or 0
  for _, range in ipairs(ranges) do
    if lnum >= range.start and lnum <= range["end"] then
      return true
    end
  end
  return false
end

return M
