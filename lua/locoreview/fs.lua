local M = {}

local config = require("locoreview.config")

local function has_vim()
  return type(vim) == "table"
end

local function current_cwd()
  if has_vim() and vim.fn and vim.fn.getcwd then
    return vim.fn.getcwd()
  end
  local p = io.popen("pwd")
  if not p then
    return nil
  end
  local cwd = p:read("*l")
  p:close()
  return cwd
end

local function absolute_path(path)
  if not path or path == "" then
    return false
  end
  return path:sub(1, 1) == "/"
end

local function ensure_parent_dir(path)
  local dir = path:match("^(.*)/[^/]+$")
  if not dir or dir == "" then
    return true
  end

  if has_vim() and vim.fn and vim.fn.mkdir then
    vim.fn.mkdir(dir, "p")
    return true
  end

  local ok = os.execute(string.format('mkdir -p "%s"', dir))
  return ok == true or ok == 0
end

function M.repo_root()
  if has_vim() and vim.fn and vim.fn.systemlist then
    local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
    if vim.v and vim.v.shell_error == 0 and out[1] and out[1] ~= "" then
      return out[1]
    end
    return nil
  end

  local p = io.popen("git rev-parse --show-toplevel 2>/dev/null")
  if not p then
    return nil
  end
  local root = p:read("*l")
  p:close()
  if not root or root == "" then
    return nil
  end
  return root
end

function M.review_file_path()
  local root = M.repo_root() or current_cwd()
  if not root then
    return nil
  end

  local cfg = config.get()
  local review_file = (cfg and cfg.review_file) or "review.md"
  if absolute_path(review_file) then
    return review_file
  end
  return root .. "/" .. review_file
end

function M.exists(path)
  local file = io.open(path or "", "r")
  if file then
    file:close()
    return true
  end
  return false
end

function M.read(path)
  local file = io.open(path or "", "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

function M.write(path, content)
  if not path or path == "" then
    return false
  end
  if not ensure_parent_dir(path) then
    return false
  end

  local tmp = string.format("%s.tmp.%d", path, os.time())
  local file = io.open(tmp, "w")
  if file then
    file:write(content or "")
    file:close()
    local ok = os.rename(tmp, path)
    if ok then
      return true
    end
    os.remove(tmp)
  end

  local fallback = io.open(path, "w")
  if not fallback then
    return false
  end
  fallback:write(content or "")
  fallback:close()
  return true
end

function M.ensure_file(path, initial_content)
  if M.exists(path) then
    return true
  end
  return M.write(path, initial_content or "# Review Comments\n\n")
end

return M
