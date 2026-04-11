# Refactor TODO (resume from Phase 2B+C)

## Status: Phases 2-4 complete

### IMMEDIATE: Finish Phase 2B+C
- [x] Verify pr_view.lua compiles cleanly (no orphan refs to removed functions)
- [x] Check `current_branch_name` is still defined (used in render but may have been in removed block)
- [x] Check `SEP`, `HEADER_QUIET_PHRASES`, `HEADER_PHASES` constants — were they in the removed block? If so, ensure they are in render.lua and aliased in pr_view.lua
- [x] Run smoke test: `:ReviewPR` opens, header renders, diffs show, highlights apply

### Phase 2D: Extract lua/locoreview/pr/actions.lua (~500 lines)
- [x] Extracted and wired with ctx + refresh callback
Functions to move from pr_view.lua:
- mark_reviewed_at_cursor, mark_unviewed_at_cursor, snooze_file_at_cursor, jump_next_unreviewed, batch_mark_directory
- add_comment_at_cursor, add_quick_comment_at_cursor, show_comment_popup, remove_resolved_comments
- open_source_at_cursor, delete_file_at_cursor, rename_file_at_cursor, copy_file_path_at_cursor
- view_file_diff_at_cursor, add_to_gitignore_at_cursor, remove_from_tracking_at_cursor
- reset_file_at_cursor, reset_hunk_at_cursor, stage_file_at_cursor, stage_hunk_at_cursor
- open_related_test_file, open_in_split_at_cursor, open_file_actions_menu, start_or_manage_timer
- Pass ctx table: {meta_at_cursor, queue_cursor_restore, header_lnum_for_file, diff_hash_for, build_hunk_patch, resolve_comment_line} + refresh callback

### Phase 2E: Extract lua/locoreview/pr/chrome.lua (~150 lines)
- [x] Extracted and wired from pr_view.lua
Functions to move:
- update_sticky_header, create_sticky_header
- hint_text_for, update_hint_bar, create_hint_bar, HINT_CONTEXTS
- setup_folds, toggle_fold_at
- get_context_lnums_for_hunk, collapse_hunk_context, expand_hunk_context

### Phase 2F: Extract lua/locoreview/pr/rhythm.lua (~180 lines)
- [x] Extracted and wired from pr_view.lua
Functions to move:
- build_rhythm_queue, rhythm_advance, cycle_rhythm
- resolve_rhythm_advance_lhs, rhythm_advance_lhs, clear_rhythm_advance_map, set_rhythm_advance_map

### Phase 3: Cross-module cleanup
- [x] Unify refresh_views (commands.lua:21-30) + refresh_global_views (workspace.lua:101-112) into lua/locoreview/views.lua
- [x] Replace EXT_MAP in workspace.lua:38-52 with vim.filetype.match()

### Phase 4: API cleanup
- [x] Replace 43x nvim_buf_set_option / nvim_win_set_option with vim.bo[buf] / vim.wo[win]
  (do after Phase 2 so changes are in smaller files)

## Key files
- Plan: /Users/peterj/.claude/plans/serialized-conjuring-trinket.md
- State: /Users/peterj/Documents/dev/locoreview/lua/locoreview/pr/state.lua (done)
- Render: /Users/peterj/Documents/dev/locoreview/lua/locoreview/pr/render.lua (done)
- Decorations: /Users/peterj/Documents/dev/locoreview/lua/locoreview/pr/decorations.lua (done)
- Main: /Users/peterj/Documents/dev/locoreview/lua/locoreview/pr_view.lua (~874 lines, was 2877)
