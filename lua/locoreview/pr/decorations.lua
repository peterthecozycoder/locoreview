-- pr/decorations.lua
-- All visual decoration for the PR view buffer: highlight groups, extmarks,
-- comment badges, heat map, hunk spotlight, active-file tint, sweep/focus dims.
--
-- Every function reads state.line_map and state.buf and writes extmarks.
-- Logical state (moods, rhythm_mode) is never mutated here.

local M = {}

local config       = require("locoreview.config")
local viewed_state = require("locoreview.viewed_state")
local state_mod    = require("locoreview.pr.state")
local state        = state_mod.state
local ensure_ns    = state_mod.ensure_ns
local render_mod   = require("locoreview.pr.render")

-- ── Highlight group definitions ───────────────────────────────────────────────

function M.setup_hl()
  local defs = {
    -- Cozy header card
    LocoHeaderBorder      = { link = "NonText" },
    LocoHeaderTitle       = { link = "Title" },
    LocoHeaderMood        = { link = "String" },
    LocoHeaderMascot      = { link = "Special" },
    LocoHeaderProgress    = { link = "Normal" },
    LocoHeaderProgressBar = { link = "Statement" },
    LocoHeaderChecklist   = { link = "Comment" },
    LocoHeaderQuiet       = { link = "Comment" },

    -- File headers
    LocoFileHeader    = { link = "Normal" },
    LocoFileViewed    = { link = "Comment" },
    LocoFileDir       = { link = "NonText" },
    LocoFileName      = { link = "Identifier" },
    LocoFileActive    = { link = "CursorLine" },

    -- Hunk headers and spotlight
    LocoHunkHeader    = { link = "Special" },
    LocoHunkActive    = { link = "CursorLine" },
    LocoHunkDim       = { link = "Comment" },
    LocoHunkGutter    = { link = "DiagnosticSignHint" },

    -- File mood dots
    LocoMoodUntouched  = { link = "Comment" },
    LocoMoodInProgress = { link = "DiagnosticSignInfo" },
    LocoMoodReviewed   = { link = "DiagnosticSignOk" },
    LocoMoodSnoozed    = { link = "DiagnosticSignWarn" },
    LocoMoodBlocked    = { link = "DiagnosticSignError" },
    LocoMoodGenerated  = { link = "Comment" },
    LocoMoodRisky      = { link = "DiagnosticSignWarn" },

    -- Diff
    LocoComment       = { link = "DiagnosticVirtualTextInfo" },
    LocoCommentOld    = { link = "DiagnosticVirtualTextWarn" },
    LocoCommentChip   = { link = "DiagnosticVirtualTextInfo" },
    LocoDiffSep       = { link = "NonText" },
    LocoBinaryNote    = { link = "Comment" },
    LocoStatsDim      = { link = "NonText" },

    -- Sections and progress
    LocoSectionHeader  = { link = "NonText" },
    LocoProgressBar    = { link = "Statement" },
    LocoTimerWarn      = { link = "DiagnosticSignError" },
    LocoSuccess        = { link = "DiagnosticSignOk" },

    -- Heat map
    LocoHeatLow       = { link = "DiagnosticSignWarn" },
    LocoHeatHigh      = { link = "DiagnosticSignError" },

    -- Sweep dim
    LocoSweepDim      = { link = "Comment" },
  }
  for name, attrs in pairs(defs) do
    vim.api.nvim_set_hl(0, name, attrs)
  end
end

-- ── Per-line highlights ────────────────────────────────────────────────────────

function M.apply_highlights(line_map)
  local buf = state.buf
  local n   = ensure_ns()
  vim.api.nvim_buf_clear_namespace(buf, n, 0, -1)

  for lnum, meta in pairs(line_map) do
    local l0 = lnum - 1
    local t  = meta.type

    if t == "header_border" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoHeaderBorder", l0, 0, -1)

    elseif t == "header_title" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoHeaderTitle", l0, 0, -1)

    elseif t == "header_mood" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoHeaderMood", l0, 0, -1)
      if meta.mascot_col and meta.mascot_len and meta.mascot_len > 0 then
        vim.api.nvim_buf_set_extmark(buf, n, l0, meta.mascot_col, {
          end_col  = meta.mascot_col + meta.mascot_len,
          hl_group = "LocoHeaderMascot",
          priority = 190,
        })
      end

    elseif t == "header_progress" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoHeaderProgress", l0, 0, -1)
      if meta.bar_col and meta.bar_len and meta.bar_len > 0 then
        vim.api.nvim_buf_set_extmark(buf, n, l0, meta.bar_col, {
          end_col  = meta.bar_col + meta.bar_len,
          hl_group = "LocoHeaderProgressBar",
          priority = 190,
        })
      end

    elseif t == "header_checklist" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoHeaderChecklist", l0, 0, -1)

    elseif t == "header_quiet" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoHeaderQuiet", l0, 0, -1)

    elseif t == "progress" then
      local hl = "LocoProgressBar"
      if state.timer_end then
        local rem = state.timer_end - os.time()
        if rem > 0 and rem <= 120 then hl = "LocoTimerWarn" end
      end
      vim.api.nvim_buf_add_highlight(buf, n, hl, l0, 0, -1)

    elseif t == "section_header" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoSectionHeader", l0, 0, -1)

    elseif t == "file_header" then
      local base_hl = (meta.mood == "reviewed") and "LocoFileViewed" or "LocoFileHeader"
      vim.api.nvim_buf_add_highlight(buf, n, base_hl, l0, 0, -1)

      vim.api.nvim_buf_set_extmark(buf, n, l0, meta.dot_col or 2, {
        end_col  = (meta.dot_col or 2) + (meta.dot_len or 3),
        hl_group = render_mod.MOOD_HL[meta.mood] or "LocoMoodUntouched",
        priority = 170,
      })

      if meta.dir_len and meta.dir_len > 0 and meta.path_col then
        vim.api.nvim_buf_set_extmark(buf, n, l0, meta.path_col, {
          end_col  = meta.path_col + meta.dir_len,
          hl_group = "LocoFileDir",
          priority = 160,
        })
      end

      if meta.name_col and meta.name_len and meta.name_len > 0 then
        vim.api.nvim_buf_set_extmark(buf, n, l0, meta.name_col, {
          end_col  = meta.name_col + meta.name_len,
          hl_group = "LocoFileName",
          priority = 170,
        })
      end

      if meta.status_col and meta.status_len and meta.status_len > 0 then
        vim.api.nvim_buf_set_extmark(buf, n, l0, meta.status_col, {
          end_col  = meta.status_col + meta.status_len,
          hl_group = "LocoStatsDim",
          priority = 160,
        })
      end

      if meta.fd then
        local stats = string.format("+%d  -%d", meta.fd.stats.added, meta.fd.stats.removed)
        vim.api.nvim_buf_set_extmark(buf, n, l0, 0, {
          virt_text     = { { stats, "LocoStatsDim" } },
          virt_text_pos = "right_align",
          priority      = 100,
        })
      end

    elseif t == "separator" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoDiffSep", l0, 0, -1)

    elseif t == "hunk_header" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoHunkHeader", l0, 0, -1)

    elseif t == "add" then
      vim.api.nvim_buf_add_highlight(buf, n, "DiffAdd", l0, 0, -1)

    elseif t == "remove" then
      vim.api.nvim_buf_add_highlight(buf, n, "DiffDelete", l0, 0, -1)

    elseif t == "binary_note" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoBinaryNote", l0, 0, -1)

    elseif t == "done_summary" then
      vim.api.nvim_buf_add_highlight(buf, n, "LocoSuccess", l0, 0, -1)
    end
  end
end

-- ── Comment badges ────────────────────────────────────────────────────────────

function M.apply_comment_badges(line_map, comment_map)
  local buf = state.buf
  local n   = ensure_ns()

  for lnum, meta in pairs(line_map) do
    local items = nil
    if meta.file and (meta.type == "add" or meta.type == "context") and meta.new_line then
      local fc = comment_map[meta.file]
      items = fc and fc.new and fc.new[meta.new_line]
    elseif meta.file and meta.type == "remove" and meta.old_line then
      local fc = comment_map[meta.file]
      items = fc and fc.old and fc.old[meta.old_line]
    end

    if items and #items > 0 then
      local is_old = meta.type == "remove"
      local badges = {}
      for _, item in ipairs(items) do
        local preview = item.issue:sub(1, 45)
        if #item.issue > 45 then preview = preview .. "…" end
        table.insert(badges, item.id .. ": " .. preview)
      end
      vim.api.nvim_buf_set_extmark(buf, n, lnum - 1, 0, {
        virt_text     = { { "  💬 " .. table.concat(badges, " | "),
                           is_old and "LocoCommentOld" or "LocoComment" } },
        virt_text_pos = "eol",
      })
    end
  end

  for _, header_lnum in ipairs(state.file_header_lnums) do
    local header_meta = state.line_map[header_lnum]
    if header_meta and header_meta.file then
      local count = render_mod.comment_count_for(header_meta.file, comment_map)
      if count > 0 then
        vim.api.nvim_buf_set_extmark(buf, n, header_lnum - 1, 0, {
          virt_text     = { { "  💬 " .. count, "LocoCommentChip" } },
          virt_text_pos = "eol",
          priority      = 90,
        })
      end
    end
  end
end

-- ── Heat map ──────────────────────────────────────────────────────────────────

function M.apply_heat_map(comment_map)
  local heat_ns = state.heat_ns or vim.api.nvim_create_namespace("locoreview_pr_heat")
  state.heat_ns = heat_ns
  vim.api.nvim_buf_clear_namespace(state.buf, heat_ns, 0, -1)

  for _, lnum in ipairs(state.file_header_lnums) do
    local file = state.line_map[lnum] and state.line_map[lnum].file
    if file then
      local count = render_mod.comment_count_for(file, comment_map)
      if count > 0 then
        local hl = count >= 3 and "LocoHeatHigh" or "LocoHeatLow"
        vim.api.nvim_buf_set_extmark(state.buf, heat_ns, lnum - 1, 0, {
          sign_text     = "▌",
          sign_hl_group = hl,
        })
      end
    end
  end
end

-- ── Hunk spotlight ────────────────────────────────────────────────────────────

function M.apply_hunk_spotlight(active_hunk_lnum)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end

  local spot_ns = state.hunk_spot_ns or vim.api.nvim_create_namespace("locoreview_pr_spot")
  state.hunk_spot_ns = spot_ns

  local hdim_ns = vim.api.nvim_create_namespace("locoreview_pr_hdim2")

  vim.api.nvim_buf_clear_namespace(state.buf, spot_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(state.buf, hdim_ns, 0, -1)

  if not active_hunk_lnum then return end

  local active_meta = state.line_map[active_hunk_lnum]
  if not active_meta then return end

  local a_hunk = active_meta.hunk_idx
  local a_file = active_meta.file_idx

  vim.api.nvim_buf_set_extmark(state.buf, spot_ns, active_hunk_lnum - 1, 0, {
    sign_text     = "▌",
    sign_hl_group = "LocoHunkGutter",
  })

  for lnum, meta in pairs(state.line_map) do
    if meta.file_idx == a_file and meta.hunk_idx then
      if meta.hunk_idx == a_hunk then
        vim.api.nvim_buf_set_extmark(state.buf, spot_ns, lnum - 1, 0, {
          line_hl_group = "LocoHunkActive",
          priority      = 50,
        })
      else
        vim.api.nvim_buf_set_extmark(state.buf, hdim_ns, lnum - 1, 0, {
          hl_group = "LocoHunkDim",
          priority = 55,
        })
      end
    end
  end
end

-- ── Active file tint ──────────────────────────────────────────────────────────

function M.apply_active_file_tint(active_file)
  local tint_ns = state.tint_ns or vim.api.nvim_create_namespace("locoreview_pr_tint")
  state.tint_ns = tint_ns
  vim.api.nvim_buf_clear_namespace(state.buf, tint_ns, 0, -1)
  if not active_file then return end

  for lnum, meta in pairs(state.line_map) do
    if meta.type == "file_header" and meta.file == active_file then
      local end_col = 0
      if meta.status_col and meta.status_len then
        end_col = meta.status_col + meta.status_len
      elseif meta.name_col and meta.name_len then
        end_col = meta.name_col + meta.name_len
      end
      vim.api.nvim_buf_set_extmark(state.buf, tint_ns, lnum - 1, 0, {
        end_col  = end_col > 0 and end_col or nil,
        hl_group = "LocoFileActive",
        priority = 40,
      })
    end
  end
end

-- ── Rhythm dims ───────────────────────────────────────────────────────────────

function M.apply_dim_layer(except_file)
  local dim_ns = state.dim_ns or vim.api.nvim_create_namespace("locoreview_pr_dim")
  state.dim_ns = dim_ns
  vim.api.nvim_buf_clear_namespace(state.buf, dim_ns, 0, -1)

  for lnum, meta in pairs(state.line_map) do
    if meta.file and meta.file ~= except_file
        and meta.type ~= "section_header"
        and meta.type ~= "progress" then
      vim.api.nvim_buf_set_extmark(state.buf, dim_ns, lnum - 1, 0, {
        hl_group = "Comment",
        priority = 200,
      })
    end
  end
end

function M.apply_sweep_dim()
  local dim_ns = state.dim_ns or vim.api.nvim_create_namespace("locoreview_pr_dim")
  state.dim_ns = dim_ns
  vim.api.nvim_buf_clear_namespace(state.buf, dim_ns, 0, -1)

  local vst = viewed_state.load()
  for lnum, meta in pairs(state.line_map) do
    if meta.file then
      local mood = render_mod.get_entry_mood(vst[meta.file])
      if mood == "reviewed" and not viewed_state.is_snoozed(meta.file) then
        vim.api.nvim_buf_set_extmark(state.buf, dim_ns, lnum - 1, 0, {
          hl_group = "LocoSweepDim",
          priority = 200,
        })
      end
    end
  end
end

function M.apply_rhythm_dims()
  if state.rhythm_mode == "focus" then
    local file = state.rhythm_queue[state.rhythm_file_idx]
    if file then M.apply_dim_layer(file) end
  elseif state.rhythm_mode == "sweep" then
    M.apply_sweep_dim()
  end
end

return M
