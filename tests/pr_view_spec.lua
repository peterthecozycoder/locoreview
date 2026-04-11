package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

describe("pr view", function()
  local old_vim
  local parse_queue

  local function basename(path)
    return (path:match("([^/]+)$")) or path
  end

  local function dirname(path)
    local dir = path:match("^(.*)/[^/]+$")
    return dir or "."
  end

  local function stem(path)
    local base = basename(path)
    return (base:gsub("%.[^%.]+$", ""))
  end

  local function ext(path)
    return (path:match("%.([^%.]+)$")) or ""
  end

  local function setup_fake_vim()
    local ns_by_name = {}
    local next_ns = 1

    local next_buf = 1
    local next_win = 1
    local next_tab = 1
    local next_extmark = 1
    local next_autocmd = 1

    local buffers = {}
    local wins = {}
    local tabs = {}
    local current_win = nil
    local current_tab = nil

    local function create_buffer(name)
      local id = next_buf
      next_buf = next_buf + 1
      buffers[id] = { name = name or "", lines = { "" }, options = {}, valid = true }
      return id
    end

    local function create_tab_with_buffer(buf)
      local win = next_win
      next_win = next_win + 1
      wins[win] = { buf = buf, cursor = { 1, 0 }, valid = true, width = 120, height = 30, options = {} }

      local tab = next_tab
      next_tab = next_tab + 1
      tabs[tab] = { wins = { win }, valid = true }

      current_tab = tab
      current_win = win
      return tab, win
    end

    local initial_buf = create_buffer("")
    create_tab_with_buffer(initial_buf)

    local function normalize_stop(lines, stop)
      if stop == -1 then return #lines end
      return stop
    end

    _G.vim = {
      api = {
        nvim_create_namespace = function(name)
          if ns_by_name[name] then return ns_by_name[name] end
          local id = next_ns
          next_ns = next_ns + 1
          ns_by_name[name] = id
          return id
        end,
        nvim_set_hl = function() end,
        nvim_buf_is_valid = function(buf)
          return buffers[buf] ~= nil and buffers[buf].valid ~= false
        end,
        nvim_create_buf = function()
          return create_buffer("")
        end,
        nvim_buf_set_option = function(buf, opt, val)
          if buffers[buf] then buffers[buf].options[opt] = val end
        end,
        nvim_buf_get_option = function(buf, opt)
          return buffers[buf] and buffers[buf].options[opt]
        end,
        nvim_buf_set_lines = function(buf, start, stop, _, lines)
          local b = assert(buffers[buf], "invalid buffer")
          if start == 0 and stop == -1 then
            b.lines = {}
            for _, line in ipairs(lines or {}) do
              table.insert(b.lines, line)
            end
            return
          end

          local s = start + 1
          local e = normalize_stop(b.lines, stop)
          for _ = s, e do
            table.remove(b.lines, s)
          end
          local idx = s
          for _, line in ipairs(lines or {}) do
            table.insert(b.lines, idx, line)
            idx = idx + 1
          end
        end,
        nvim_buf_get_lines = function(buf, start, stop, _)
          local b = assert(buffers[buf], "invalid buffer")
          local s = start + 1
          local e = normalize_stop(b.lines, stop)
          local out = {}
          for i = s, e do
            if b.lines[i] ~= nil then table.insert(out, b.lines[i]) end
          end
          return out
        end,
        nvim_buf_set_name = function(buf, name)
          if buffers[buf] then buffers[buf].name = name end
        end,
        nvim_buf_get_name = function(buf)
          return (buffers[buf] and buffers[buf].name) or ""
        end,
        nvim_buf_clear_namespace = function() end,
        nvim_buf_add_highlight = function() end,
        nvim_buf_set_extmark = function()
          local id = next_extmark
          next_extmark = next_extmark + 1
          return id
        end,
        nvim_buf_del_extmark = function() end,
        nvim_get_current_tabpage = function()
          return current_tab
        end,
        nvim_set_current_tabpage = function(tab)
          current_tab = tab
          current_win = tabs[tab] and tabs[tab].wins[1] or current_win
        end,
        nvim_tabpage_is_valid = function(tab)
          return tabs[tab] ~= nil and tabs[tab].valid ~= false
        end,
        nvim_tabpage_list_wins = function(tab)
          return (tabs[tab] and tabs[tab].wins) or {}
        end,
        nvim_win_get_buf = function(win)
          return wins[win] and wins[win].buf
        end,
        nvim_win_set_buf = function(win, buf)
          if wins[win] then wins[win].buf = buf end
        end,
        nvim_get_current_win = function()
          return current_win
        end,
        nvim_set_current_win = function(win)
          current_win = win
        end,
        nvim_win_is_valid = function(win)
          return wins[win] ~= nil and wins[win].valid ~= false
        end,
        nvim_win_get_cursor = function(win)
          local w = wins[win or current_win]
          return w and { w.cursor[1], w.cursor[2] } or { 1, 0 }
        end,
        nvim_win_set_cursor = function(win, pos)
          if wins[win] then
            wins[win].cursor = { pos[1], pos[2] }
          end
        end,
        nvim_win_get_width = function(win)
          return (wins[win] and wins[win].width) or 120
        end,
        nvim_win_get_height = function(win)
          return (wins[win] and wins[win].height) or 30
        end,
        nvim_win_set_option = function(win, opt, val)
          if wins[win] then wins[win].options[opt] = val end
        end,
        nvim_open_win = function(buf, _, _)
          local win = next_win
          next_win = next_win + 1
          wins[win] = { buf = buf, cursor = { 1, 0 }, valid = true, width = 120, height = 30, options = {} }
          return win
        end,
        nvim_win_close = function(win, _)
          if wins[win] then wins[win].valid = false end
        end,
        nvim_win_call = function(win, fn)
          local prev = current_win
          current_win = win
          local out = fn()
          current_win = prev
          return out
        end,
        nvim_create_autocmd = function(_, _)
          local id = next_autocmd
          next_autocmd = next_autocmd + 1
          return id
        end,
        nvim_del_autocmd = function() end,
        nvim_echo = function() end,
        nvim_replace_termcodes = function(keys)
          return keys
        end,
        nvim_feedkeys = function() end,
        nvim_list_bufs = function()
          local out = {}
          for id, buf in pairs(buffers) do
            if buf.valid ~= false then table.insert(out, id) end
          end
          table.sort(out)
          return out
        end,
        nvim_buf_delete = function(buf, _)
          if buffers[buf] then buffers[buf].valid = false end
        end,
      },
      fn = {
        systemlist = function(cmd)
          if type(cmd) == "table"
            and cmd[1] == "git"
            and cmd[2] == "rev-parse"
            and cmd[3] == "--abbrev-ref"
            and cmd[4] == "HEAD" then
            _G.vim.v.shell_error = 0
            return { "feature/local" }
          end
          _G.vim.v.shell_error = 0
          return {}
        end,
        line = function()
          return 1
        end,
        sha256 = function(value)
          return "sha-" .. tostring(#(value or ""))
        end,
        fnameescape = function(value)
          return value
        end,
        fnamemodify = function(value, mod)
          if mod == ":h" then return dirname(value) end
          if mod == ":t" then return basename(value) end
          if mod == ":t:r" then return stem(value) end
          if mod == ":e" then return ext(value) end
          if mod == ":." then return value end
          return value
        end,
        search = function()
          return 1
        end,
        filereadable = function()
          return 0
        end,
        setreg = function() end,
        tempname = function()
          return "/tmp/locoreview.patch"
        end,
        delete = function()
          return 0
        end,
        mkdir = function()
          return 1
        end,
        rename = function()
          return 0
        end,
        system = function()
          _G.vim.v.shell_error = 0
          return ""
        end,
      },
      keymap = {
        set = function() end,
        del = function() end,
      },
      ui = {
        select = function(_, _, cb) cb(nil) end,
        input = function(_, cb) cb(nil) end,
      },
      loop = {
        new_timer = function()
          return {
            start = function() end,
            stop = function() end,
            close = function() end,
          }
        end,
      },
      cmd = function(command)
        if command == "tabnew" then
          local buf = create_buffer("")
          create_tab_with_buffer(buf)
          return
        end
        if command == "tabclose" then
          if tabs[current_tab] then tabs[current_tab].valid = false end
          for tab, data in pairs(tabs) do
            if data.valid ~= false then
              current_tab = tab
              current_win = data.wins[1]
              return
            end
          end
          return
        end
      end,
      startswith = function(value, prefix)
        return value:sub(1, #prefix) == prefix
      end,
      tbl_extend = function(_, ...)
        local out = {}
        for _, t in ipairs({ ... }) do
          for k, v in pairs(t or {}) do
            out[k] = v
          end
        end
        return out
      end,
      schedule = function(fn)
        fn()
      end,
      schedule_wrap = function(fn)
        return fn
      end,
      defer_fn = function(fn, _)
        fn()
      end,
      o = {
        columns = 120,
        laststatus = 2,
        showtabline = 1,
      },
      v = {
        shell_error = 0,
      },
      g = {
        mapleader = "\\",
      },
      log = {
        levels = {
          ERROR = 1,
          WARN = 2,
          INFO = 3,
        },
      },
    }

    local function option_accessor(get_target)
      return setmetatable({}, {
        __index = function(_, id)
          return setmetatable({}, {
            __index = function(_, key)
              local target = get_target(id)
              return target and target.options[key] or nil
            end,
            __newindex = function(_, key, value)
              local target = get_target(id)
              if target then target.options[key] = value end
            end,
          })
        end,
      })
    end

    _G.vim.bo = option_accessor(function(id)
      local buf = id
      if buf == nil or buf == 0 then
        local win = wins[current_win]
        buf = win and win.buf or nil
      end
      return buffers[buf]
    end)

    _G.vim.wo = option_accessor(function(id)
      local win = id
      if win == nil or win == 0 then
        win = current_win
      end
      return wins[win]
    end)

    return {
      get_current_buffer = function()
        return wins[current_win] and wins[current_win].buf
      end,
      find_buffer_by_name = function(name)
        for id, buf in pairs(buffers) do
          if buf.valid ~= false and buf.name == name then
            return id
          end
        end
        return nil
      end,
    }
  end

  before_each(function()
    old_vim = _G.vim
    parse_queue = {}

    for _, mod in ipairs({
      "locoreview.pr_view",
      "locoreview.config",
      "locoreview.fs",
      "locoreview.git",
      "locoreview.git_diff",
      "locoreview.store",
      "locoreview.ui",
      "locoreview.viewed_state",
    }) do
      package.loaded[mod] = nil
    end

    local fx = setup_fake_vim()
    _G.__pr_view_test = fx

    package.loaded["locoreview.config"] = {
      get = function()
        return {
          pr_view = {
            micro_rewards = false,
            auto_advance_on_viewed = false,
            action_hints = false,
            generated_patterns = {},
            risky_threshold = 150,
          },
        }
      end,
    }

    package.loaded["locoreview.fs"] = {
      review_file_path = function()
        return "/repo/review.md"
      end,
    }

    package.loaded["locoreview.git"] = {
      repo_root = function()
        return "/repo"
      end,
      base_branch = function()
        return "origin/main"
      end,
    }

    package.loaded["locoreview.git_diff"] = {
      parse = function()
        local next_value = table.remove(parse_queue, 1)
        return next_value or {}
      end,
    }

    package.loaded["locoreview.store"] = {
      load = function()
        return {}
      end,
      save = function()
        return true
      end,
    }

    package.loaded["locoreview.ui"] = {
      notify = function() end,
      prompt_git_ref = function(_, cb)
        cb(nil)
      end,
    }

    package.loaded["locoreview.viewed_state"] = {
      sync = function()
        return {}
      end,
      load = function()
        return {}
      end,
      is_snoozed = function()
        return false
      end,
      is_generated = function()
        return false
      end,
      mark_in_progress = function() end,
      mark_reviewed = function() end,
      mark_unviewed = function() end,
      snooze = function() end,
      unsnooze = function() end,
    }
  end)

  after_each(function()
    _G.vim = old_vim
    _G.__pr_view_test = nil
    package.loaded["locoreview.pr_view"] = nil
  end)

  it("clears stale lines when refresh transitions to empty diff", function()
    local pr_view = require("locoreview.pr_view")

    parse_queue[1] = {
      {
        file = "lua/a.lua",
        old_file = "lua/a.lua",
        status = "modified",
        stats = { added = 1, removed = 0 },
        diff_hash = "abc123",
        hunks = {
          {
            header = "@@ -0,0 +1,1 @@",
            lines = {
              { type = "add", text = "+print('hi')", old_line = nil, new_line = 1 },
            },
          },
        },
      },
    }

    pr_view.open(false)

    local buf = _G.__pr_view_test.find_buffer_by_name("locoreview://pr-review")
    assert.is_truthy(buf)
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "stale line that should disappear" })
    vim.api.nvim_buf_set_option(buf, "modifiable", false)

    parse_queue[1] = {}
    pr_view.refresh()

    local refreshed = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.same({ "  no uncommitted changes" }, refreshed)
  end)
end)
