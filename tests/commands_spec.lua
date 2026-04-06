package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

describe("review commands", function()
  local created = {}
  local state = {}

  local function reset_state()
    state.cursor = 5
    state.buf = "/repo/file.lua"
    state.items = {}
    state.insert_calls = {}
    state.transition_calls = {}
    state.saved = nil
    state.last_cmd = nil
    state.jump_line = nil
    state.mark_start = 2
    state.mark_end = 4
    state.issue = "Issue text"
    state.requested_change = "Change text"
    state.severity = "medium"
    state.diff_only = false
    state.changed_lines = {}
  end

  setup(function()
    _G.vim = {
      api = {
        nvim_create_user_command = function(name, cb, _)
          created[name] = cb
        end,
        nvim_win_get_cursor = function()
          return { state.cursor, 0 }
        end,
        nvim_buf_get_name = function()
          return state.buf
        end,
        nvim_win_set_cursor = function(_, pos)
          state.jump_line = pos[1]
        end,
        nvim_get_current_win = function()
          return 1
        end,
        nvim_win_is_valid = function()
          return true
        end,
        nvim_set_current_win = function()
        end,
        nvim_list_bufs = function()
          return {}
        end,
        nvim_buf_is_loaded = function()
          return false
        end,
      },
      fn = {
        getpos = function(mark)
          if mark == "'<" then
            return { 0, state.mark_start, 0, 0 }
          end
          return { 0, state.mark_end, 0, 0 }
        end,
        fnameescape = function(v)
          return v
        end,
        setqflist = function()
        end,
      },
      cmd = function(command)
        state.last_cmd = command
      end,
      startswith = function(value, prefix)
        return value:sub(1, #prefix) == prefix
      end,
      log = { levels = { ERROR = 1, INFO = 2 } },
      ui = {
        input = function(_, cb)
          cb(nil)
        end,
        select = function(_, _, cb)
          cb(nil)
        end,
      },
    }

    package.loaded["locoreview.config"] = {
      get = function()
        return {
          default_severity = "medium",
          default_author = nil,
          diff_only = state.diff_only,
          diffview = { enabled = true },
          picker = { enabled = true, backend = "auto" },
          agent = { enabled = false, cmd = "agent", open_in_split = true },
        }
      end,
    }
    package.loaded["locoreview.fs"] = {
      review_file_path = function()
        return "/repo/review.md"
      end,
      ensure_file = function()
        return true
      end,
    }
    package.loaded["locoreview.git"] = {
      repo_root = function()
        return "/repo"
      end,
      base_branch = function()
        return "origin/main"
      end,
      is_line_changed = function(_, line)
        if state.changed_lines[line] == nil then
          return true
        end
        return state.changed_lines[line]
      end,
    }
    package.loaded["locoreview.store"] = {
      load = function()
        return state.items
      end,
      save = function(_, items)
        state.saved = items
        state.items = items
        return true
      end,
      insert = function(items, fields)
        table.insert(state.insert_calls, fields)
        local next = {}
        for i, item in ipairs(items) do
          next[i] = item
        end
        local inserted = {
          id = "RV-0001",
          file = fields.file,
          line = fields.line,
          end_line = fields.end_line,
          severity = fields.severity,
          status = fields.status,
          issue = fields.issue,
          requested_change = fields.requested_change,
          author = fields.author,
          created_at = "2026-03-28T10:00:00Z",
          updated_at = "2026-03-28T10:00:00Z",
        }
        table.insert(next, inserted)
        return next, inserted
      end,
      transition = function(items, id, status)
        table.insert(state.transition_calls, status)
        local next = {}
        for i, item in ipairs(items) do
          next[i] = {}
          for k, v in pairs(item) do
            next[i][k] = v
          end
          if item.id == id then
            next[i].status = status
          end
        end
        return next, {}
      end,
      update = function(items)
        return items
      end,
      delete = function(items)
        return items
      end,
    }
    package.loaded["locoreview.ui"] = {
      prompt_issue = function(cb)
        cb(state.issue)
      end,
      prompt_requested_change = function(cb)
        cb(state.requested_change)
      end,
      prompt_severity = function(_, cb)
        cb(state.severity)
      end,
      prompt_confirm = function(_, cb)
        cb(true)
      end,
      notify = function()
      end,
    }
    package.loaded["locoreview.qf"] = {
      populate = function()
      end,
      refresh = function()
      end,
    }
    package.loaded["locoreview.diffview"] = {
      is_available = function()
        return false
      end,
    }
    package.loaded["locoreview.picker"] = {
      open = function()
      end,
    }
    package.loaded["locoreview.agent"] = {
      run = function()
        return true
      end,
    }
    package.loaded["locoreview.signs"] = {
      refresh = function()
      end,
      toggle = function()
        return true
      end,
    }

    require("locoreview.commands").register()
  end)

  before_each(function()
    reset_state()
  end)

  it("adds an item from current line", function()
    created.ReviewAdd({})
    assert.are.equal(1, #state.insert_calls)
    assert.are.equal("file.lua", state.insert_calls[1].file)
    assert.are.equal(5, state.insert_calls[1].line)
    assert.is_nil(state.insert_calls[1].end_line)
  end)

  it("adds an item from visual range", function()
    created.ReviewAddRange({})
    assert.are.equal(1, #state.insert_calls)
    assert.are.equal(2, state.insert_calls[1].line)
    assert.are.equal(4, state.insert_calls[1].end_line)
  end)

  it("enforces diff_only for visual range", function()
    state.diff_only = true
    state.changed_lines = {
      [2] = true,
      [3] = false,
      [4] = true,
    }

    created.ReviewAddRange({})
    assert.are.equal(0, #state.insert_calls)
  end)

  it("ReviewNext jumps to the first item after current position", function()
    state.cursor = 1
    state.items = {
      {
        id = "RV-0001",
        file = "file.lua",
        line = 10,
        severity = "medium",
        status = "open",
        issue = "x",
      },
      {
        id = "RV-0002",
        file = "file.lua",
        line = 20,
        severity = "medium",
        status = "open",
        issue = "y",
      },
    }

    created.ReviewNext({})
    assert.are.equal("edit /repo/file.lua", state.last_cmd)
    assert.are.equal(10, state.jump_line)
  end)

  it("marks fixed then reopens", function()
    state.items = {
      {
        id = "RV-0001",
        file = "file.lua",
        line = 5,
        end_line = nil,
        severity = "medium",
        status = "open",
        issue = "x",
        requested_change = "y",
      },
    }

    created.ReviewMarkFixed({})
    assert.are.equal("fixed", state.transition_calls[1])

    state.items = {
      {
        id = "RV-0001",
        file = "file.lua",
        line = 5,
        end_line = nil,
        severity = "medium",
        status = "fixed",
        issue = "x",
        requested_change = "y",
      },
    }
    created.ReviewReopen({})
    assert.are.equal("open", state.transition_calls[2])
  end)

  it("cleans fixed items from the review file", function()
    state.items = {
      {
        id = "RV-0001",
        file = "file.lua",
        line = 1,
        severity = "medium",
        status = "fixed",
        issue = "x",
      },
      {
        id = "RV-0002",
        file = "file.lua",
        line = 2,
        severity = "medium",
        status = "open",
        issue = "y",
      },
      {
        id = "RV-0003",
        file = "file.lua",
        line = 3,
        severity = "medium",
        status = "blocked",
        issue = "z",
      },
    }

    created.ReviewClean({})

    assert.are.equal(2, #state.saved)
    for _, item in ipairs(state.saved) do
      assert.are_not.equal("fixed", item.status)
    end
  end)
end)
