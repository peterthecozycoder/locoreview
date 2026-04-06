# PR View Enhancement Tickets

> **Consolidations applied:**
> - T-01 absorbs batch directory marking (same flow, same keymap area)
> - T-02 absorbs the timer (renders inline in the progress line; no new `:` command)
> - T-11 consolidates Focus File + Review Queue + Zen Layout + Hunk-by-Hunk + Micro-rewards into one `<leader>F` cycle
> - No new `:` commands are introduced by any ticket

---

## How to read these tickets

Each ticket tells you **which functions to touch**, **what exact fields/values to use**, and **what to watch out for**. It does not write the code for you. Read every file referenced in "Read first" before touching anything. The codebase has invariants that will silently break if you skip the reading step.

---

## Codebase facts you must know before starting any ticket

These facts apply across all tickets. Internalise them now.

**The shared namespace `n` is wiped on every refresh.**
`apply_highlights()` (pr_view.lua:179) calls `vim.api.nvim_buf_clear_namespace(buf, n, 0, -1)` before doing anything. This destroys every extmark in `n`. Any feature that places extmarks **must use its own dedicated namespace** stored in `state`, or its marks will vanish on every refresh. The only exception is `apply_comment_badges()` which is called *after* the clear, so it survives.

**`render()` returns four values in a fixed order.**
`line_map, fold_ranges, file_header_lnums, hunk_header_lnums` (pr_view.lua:172). `do_render()` (pr_view.lua:407) assigns all four into `state`. If you modify `render()` to return extra values, update `do_render()` too.

**`line_map` is 1-indexed, matching Neovim buffer line numbers.**
`line_map[lnum]` is a table with at minimum `{ type = "..." }`. Every line in the buffer has an entry. Navigation keymaps use `meta_at_cursor()` (pr_view.lua:265) which reads `state.line_map[lnum]`. If a line has no entry, keymaps will silently do nothing.

**`file_header_lnums` and `hunk_header_lnums` must be sorted ascending.**
`navigate_files()` (pr_view.lua:284) and `navigate_hunks()` (pr_view.lua:304) iterate these arrays sequentially to find the next/previous line number. If they are not sorted, navigation breaks.

**`do_open_or_refresh()` is the single entry point for all rendering.**
`M.refresh()` calls it (pr_view.lua:545). Never render the buffer from anywhere else. New features hook in by modifying `do_render()` or by being called from `do_open_or_refresh()` after `do_render()` completes.

**The buffer is read-only except during render.**
`render()` sets `modifiable = true`, writes lines, then sets `modifiable = false` (pr_view.lua:168-170). Never write to the buffer outside of `render()`.

**`M.show_help()` (pr_view.lua:567) must be updated for every new keymap.**
It is the only user-visible documentation of keymaps. If you add a keymap and don't add it here, users will never know it exists.

**`config.lua` new keys go in `M.defaults` (config.lua:5).**
`M.normalize()` deep-merges user config over defaults. You do not need to add validation for simple boolean/string keys — the merge handles it. Just add the key with its default value to `M.defaults`.

---

## T-01 · Viewed Files Float to Top + Batch Marking
**Priority:** P0 · **Complexity:** Medium · **File:** `lua/locoreview/pr_view.lua`

### Read first
- `render()` (pr_view.lua:87–173) — understand the full loop before touching it
- `do_open_or_refresh()` (pr_view.lua:427–499) — this is where sorting must be inserted
- `viewed_state.sync()` (viewed_state.lua:44) — returns `vst`, a table of `{ file → { viewed = bool, diff_hash = str } }`
- `mark_viewed_at_cursor()` (pr_view.lua:340) — existing `v` keymap handler

### Goal
Sort `file_diffs` so viewed files render first (collapsed), unviewed render after (expanded). Insert two static section-header lines as visual dividers. Add `<leader>v` to batch-mark a directory.

### Step 1 — Sort file_diffs before rendering

In `do_open_or_refresh()`, after `vst` is assigned (pr_view.lua:447) and before `do_render()` is called (pr_view.lua:474), sort `state.file_diffs` in place:
- Viewed files (where `vst[fd.file] and vst[fd.file].viewed == true`) sort first.
- Within each group, preserve original order (stable sort). Lua's `table.sort` is not stable; preserve original index as a tiebreaker.

### Step 2 — Add section headers inside render()

In `render()`, before the `for fi, fd in ipairs(file_diffs)` loop, determine the index of the first unviewed file in the sorted array. You now know exactly where the boundary is.

Insert lines and `line_map` entries for two section headers:
1. Before the loop starts (if any file is viewed): a "VIEWED (N)" header line.
2. At the boundary index (when `fi` crosses from viewed to unviewed): a "UNVIEWED (N)" header line.

Give both lines `line_map` entries with `type = "section_header"` so all navigation keymaps skip them. Do NOT assign them a `file` field. Do NOT include them in `file_header_lnums`. Do NOT create fold ranges for them.

Apply highlight `LocoSectionHeader` (add to `setup_hl()`, link to `Type`) to both lines via `apply_highlights()` — add a branch for `meta.type == "section_header"`.

Add a second divider highlight `LocoSectionDivider` (link to `VertSplit`) for a separator line between the two sections (one extra `─` line between them, same as `SEP`).

### Step 3 — Update navigate_files() to skip section headers

In `navigate_files()` (pr_view.lua:284), the loop over `state.file_header_lnums` already skips non-file lines because section headers are not in that array. No change needed here — but verify by tracing the logic manually after your change.

### Step 4 — Add <leader>v for batch directory marking

In `attach_keymaps()` (pr_view.lua:382), add a new `bmap` for `"<leader>v"`.

Handler logic:
1. Call `meta_at_cursor()`. If `meta.file` is nil, `ui.notify` a warning and return.
2. Extract the directory: `vim.fn.fnamemodify(meta.file, ":h")`. This returns `"."` for root-level files — handle that case gracefully (match files with no `/` in path).
3. Collect all entries from `state.file_diffs` whose `fd.file` starts with that directory prefix followed by `/` (use `vim.startswith(fd.file, dir .. "/")` or handle the `"."` root case).
4. Confirm with `vim.ui.select({"Yes", "No"}, { prompt = "Mark N files in dir/ as viewed?" })`.
5. On "Yes": call `viewed_state.mark_viewed(fd.file, fd.diff_hash)` for each collected file. Then call `M.refresh()`.
6. Show `ui.notify("Marked N files viewed")` after refresh.

Add `"  <leader>v    mark all files in same directory as viewed"` to `M.show_help()`.

### Gotchas
- Do not sort `state.file_diffs` after `do_render()` — `do_render()` reads it to build `state.fold_ranges`. The sort must happen before `do_render()`.
- Section header lines increase all subsequent line numbers. After inserting section headers, every `line_map` index, `fold_ranges.start/stop`, `file_header_lnums`, and `hunk_header_lnums` entry is offset by however many section headers precede it. The easiest fix: build these offsets naturally by letting `#lines` grow as you insert section header lines inside `render()` — do not try to offset after the fact.
- If all files are viewed, there is no "UNVIEWED" section. If no files are viewed, there is no "VIEWED" section. Handle both edge cases by only emitting a section header when that section is non-empty.

### Verify
Open a PR diff. Mark one file viewed. It should instantly appear at the top in a "VIEWED (1)" section, collapsed. Remaining files should be under "UNVIEWED (N)". `]f`/`[f` should skip the section header lines. `<leader>v` on any file header should prompt and bulk-mark.

---

## T-02 · Progress Header & Inline Timer
**Priority:** P1 · **Complexity:** Low · **File:** `lua/locoreview/pr_view.lua`

### Read first
- `do_render()` (pr_view.lua:407–416) — where you will add the progress line call
- `render()` (pr_view.lua:87) — understand how lines are prepended
- `M.close()` (pr_view.lua:552) — you must add timer teardown here
- `config.lua:5` — add new config key here

### Goal
Prepend a single progress line to the buffer as its first line. When `<leader>T` is pressed, a countdown is appended to that same line on every tick. No separate floating window for the timer.

### Step 1 — Add config key

In `config.lua` `M.defaults` (config.lua:5), add:
```
pr_view = {
  auto_advance_on_viewed = true,
  micro_rewards = true,
}
```
Access via `config.get().pr_view.auto_advance_on_viewed` etc. throughout all tickets.

### Step 2 — Add state fields

In the `state` table (pr_view.lua:24), add:
```
timer        = nil,   -- vim.loop timer handle, or nil
timer_end    = nil,   -- os.time() when timer expires, or nil
```

### Step 3 — Render the progress line

Create a new function `render_progress_line(file_diffs, review_items, vst)` that returns a single string. It must:
- Count viewed: iterate `file_diffs`, check `vst[fd.file] and vst[fd.file].viewed`.
- Count total: `#file_diffs`.
- Count comments: `#review_items`.
- Get branch name: call `git.base_branch(config.get())` or read `state.base_ref` (use state.base_ref if set, else "HEAD").
- Build a 12-char progress bar: `viewed_count / total * 12` chars of `▓`, remainder `░`.
- Build the string: `"  {branch}  │  {viewed}/{total} reviewed  {bar}  {pct}%  │  {n} comments"`.
- If `state.timer_end ~= nil`: compute remaining seconds (`state.timer_end - os.time()`). If > 0, append `"  │  ⏱ MM:SS"`. If <= 0, append `"  │  ✦ Time's up"`.

Call this function from inside `render()` as the very first thing before the file loop. Insert the returned string as `lines[1]`, add `line_map[1] = { type = "progress" }`. All subsequent lines are now offset by 1 — this is fine because `#lines` grows naturally.

### Step 4 — Highlight the progress line

In `apply_highlights()`, add a branch: if `meta.type == "progress"`, apply `LocoProgressBar` (add to `setup_hl()`, link to `Statement`) to the whole line. When the timer is active and under 120 seconds remaining, apply `LocoTimerWarn` (link to `DiagnosticSignError`) instead.

Because `apply_highlights()` clears the whole namespace first, the highlight will be reapplied correctly on every refresh. No extra tracking needed.

### Step 5 — <leader>T keymap

In `attach_keymaps()`, add `bmap("<leader>T", ...)`.

Handler:
- If `state.timer ~= nil` (timer already running): call `vim.ui.select({"Cancel timer", "Keep going"}, ...)`. On "Cancel timer": stop and close the handle, set `state.timer = nil`, `state.timer_end = nil`, call `M.refresh()`. On "Keep going": do nothing.
- If `state.timer == nil`: call `vim.ui.input({ prompt = "Minutes: " }, ...)`. Validate input is a positive number. Set `state.timer_end = os.time() + (minutes * 60)`. Create timer: `state.timer = vim.loop.new_timer()`. Call `state.timer:start(0, 10000, vim.schedule_wrap(function() M.refresh() end))`. The `M.refresh()` inside the tick re-renders the progress line, which reads `state.timer_end` to show the countdown.

### Step 6 — Teardown

In `M.close()` (pr_view.lua:552), before the `pcall(tabclose)` block, add: if `state.timer ~= nil`, call `state.timer:stop()`, `state.timer:close()`, set `state.timer = nil`, `state.timer_end = nil`.

Add the same teardown at the end of the `BufDelete` autocmd callback (pr_view.lua:459).

Add `"  <leader>T    start / cancel timed review session"` to `M.show_help()`.

### Gotchas
- `vim.loop.new_timer():start(delay_ms, repeat_ms, callback)`. The callback runs on the event loop thread — wrap it in `vim.schedule_wrap()` so it can call Neovim API functions safely.
- Do not call `timer:close()` without calling `timer:stop()` first. The order must always be: `stop()` then `close()`.
- The progress line is line 1 of the buffer. After T-01, section header lines are lines 2+ (or possibly line 1 if you insert the progress line first). Make sure the progress line is always first — insert it before the section headers inside `render()`.
- `state.timer_end` must be an absolute `os.time()` timestamp, not a duration. This way the countdown is always accurate regardless of refresh timing.

### Verify
Open PR view. Check progress line shows correct branch/count/bar. Press `<leader>T`, enter "5". Watch the countdown appear. Press `<leader>T` again, cancel. Countdown disappears. Close PR view; re-open — no lingering timer.

---

## T-03 · Auto-Advance After Marking Viewed
**Priority:** P1 · **Complexity:** Low · **File:** `lua/locoreview/pr_view.lua`

### Read first
- `mark_viewed_at_cursor()` (pr_view.lua:340) — the function you will extend
- `state.file_header_lnums` — sorted array of 1-indexed line numbers for file headers
- `state.line_map` — check `meta.is_viewed` field on file header entries
- Config key added in T-02: `config.get().pr_view.auto_advance_on_viewed`

### Goal
After `v` marks a file viewed and `M.refresh()` completes, jump the cursor to the first hunk of the next unviewed file.

### Implementation

Extend `mark_viewed_at_cursor()` (pr_view.lua:340). After `M.refresh()` returns:
1. Check `config.get().pr_view.auto_advance_on_viewed`. If false, return.
2. Iterate `state.file_header_lnums` in order. For each lnum, check `state.line_map[lnum].is_viewed`. Find the first one where `is_viewed == false`.
3. If found: call `vim.api.nvim_win_set_cursor(0, { lnum, 0 })`.
4. If not found (all files reviewed): call `ui.notify("All files reviewed!", vim.log.levels.INFO)`.

### Gotchas
- Read `state.file_header_lnums` **after** `M.refresh()` returns, not before. The refresh re-renders the buffer and rebuilds `state`, so the lnums from before the refresh are stale.
- `state.file_header_lnums` after T-01 will skip section header lines — those are not in the array. So iterating it directly gives you only real file headers. No extra filtering needed.
- After T-01, viewed files appear first in the buffer. "First unviewed" in `state.file_header_lnums` iteration order correctly finds the first unviewed file header (it will be after all viewed ones).

### Verify
Open PR view with multiple files. Press `v` on one. Cursor should jump to the first hunk of the next unviewed file. Set `auto_advance_on_viewed = false` in config; press `v` — cursor should stay. Mark all files viewed; press `v` on the last — should show "All files reviewed!" notification.

---

## T-04 · Comment Popup with Actions
**Priority:** P1 · **Complexity:** Medium · **File:** `lua/locoreview/pr_view.lua`

### Read first
- `apply_comment_badges()` (pr_view.lua:201) — how comment map is built and consumed
- `build_comment_map()` (pr_view.lua:76) — returns `{ file → { new_line → [items] } }`
- `store.lua` — find `store.transition(path, id, new_status)` and `store.delete(path, id)` signatures
- `fs.review_file_path()` — how to get the review.md path
- `meta_at_cursor()` (pr_view.lua:265)

### Goal
`K` on a diff line with a comment badge opens a floating window showing the full comment. Actions inside the float: `e` (edit in review.md), `s` (cycle status), `d` (delete), `q`/`<Esc>` (close).

### Step 1 — Build the lookup

In the `K` keymap handler:
1. Call `meta_at_cursor()`. Get `meta.file` and `meta.new_line`.
2. If either is nil, `ui.notify("No comment here")` and return.
3. Load review items via `load_review_items()` (pr_view.lua:418). Build a comment map via `build_comment_map(items)`.
4. Look up `comment_map[meta.file]` and then `[meta.new_line]`. If nil or empty, `ui.notify("No comment here")` and return.
5. If multiple items on that line, start with `items[1]` (you can add cycling later; for now show the first).

### Step 2 — Open the float

Create a scratch buffer for the float. Set `buftype = "nofile"`, `bufhidden = "wipe"`, `modifiable = false`.

Build the content lines from the item fields: id, severity, status, issue (possibly multi-line), requested_change (possibly multi-line), and a footer line `"[e] edit  [s] status  [d] delete  [q] close"`.

Calculate `width` as the max line length + 4 (padding), capped at `math.min(width, vim.o.columns - 4)`. Calculate `height` as `#lines`.

Call `vim.api.nvim_open_win(float_buf, true, { relative = "cursor", row = 1, col = 0, width = width, height = height, style = "minimal", border = "rounded" })`. `true` means the float is focused immediately.

Store the float window handle in a local variable inside the handler (not in `state` — it's ephemeral).

### Step 3 — Float keymaps

Set buffer-local keymaps on the float buffer:
- `q` and `<Esc>`: `vim.api.nvim_win_close(float_win, true)`.
- `e`: close float, then `vim.cmd("edit +" .. vim.fn.fnameescape("/RV-" .. item.id) .. " " .. vim.fn.fnameescape(fs.review_file_path()))`. This opens review.md with cursor on the item. Actually use `vim.cmd("edit " .. path)` then `vim.fn.search("^## " .. item.id)` — the `+/pattern` approach with special chars is fragile.
- `s`: look up the next valid status via `types.VALID_TRANSITIONS[item.status]` (types.lua:19). Pick the first valid transition. Call `store.transition(fs.review_file_path(), item.id, next_status)`. Close float. Call `M.refresh()`.
- `d`: confirm with `vim.ui.select({"Delete", "Cancel"}, ...)`. On "Delete": close float, call `store.delete(fs.review_file_path(), item.id)`, call `M.refresh()`.

### Step 4 — Auto-close on cursor move

Register a `CursorMoved` autocmd with `buffer = state.buf` (the PR view buffer, not the float). In the callback: if the float window is still valid (`vim.api.nvim_win_is_valid(float_win)`), close it. Use `autocmd_id` returned by `nvim_create_autocmd` and delete it with `nvim_del_autocmd` inside the close paths so it doesn't fire after the float is already gone.

Add `"  K          show full comment popup"` to `M.show_help()`.

### Gotchas
- `store.transition` and `store.delete` signatures: read store.lua before calling them. Do not guess parameters.
- `types.VALID_TRANSITIONS[status]` is a table of `{ next_status = true }`. To get the first valid transition: iterate pairs and pick the first key. There may be multiple — just pick the first for the `s` action (it's a cycle approximation).
- The float buffer must have `modifiable = false` after you write content, or the user can accidentally edit it.
- Do not store the float window handle in `state`. It is created and destroyed within the scope of one user action. Use a closure (upvalue).

### Verify
Press `K` on a line with a badge — float appears with full comment. Press `s` — status cycles and float closes. Press `d` — confirm prompt appears; on confirm, item removed from review.md. Press `K` on a line with no badge — notification shows. Move cursor — float closes automatically.

---

## T-05 · Comment on Deleted Lines
**Priority:** P2 · **Complexity:** Medium · **Files:** `lua/locoreview/types.lua`, `lua/locoreview/formatter.lua`, `lua/locoreview/parser.lua`, `lua/locoreview/pr_view.lua`

### Read first
- `types.new_item()` (types.lua:43) — current item schema, no `line_ref` field
- `formatter.format()` (formatter.lua:18) — writes every item field as `key: value`
- `parser.parse_item()` (parser.lua:37) — reads scalar fields via `parse_scalar_line()` (parser.lua:29) which matches `^([%a_]+):%s*(.-)%s*$`
- `add_comment_at_cursor()` (pr_view.lua:357) — current guard that rejects remove lines
- `apply_comment_badges()` (pr_view.lua:201) — only handles `new_line` lookups today
- `build_comment_map()` (pr_view.lua:76) — current map structure

### Goal
Allow `c` on a `-` (remove) line. Store which line reference (`"old"` or `"new"`) the comment is anchored to. Display badges on remove lines using a distinct colour.

### Step 1 — Extend the item schema (types.lua)

In `new_item()` (types.lua:43), add `line_ref` to the returned table:
- Value comes from `fields.line_ref`.
- Valid values: `"old"` or `"new"`. Any other value (including nil) defaults to `"new"`.
- Do not make it a required field. Do not add it to the validation error paths. Just default it.

### Step 2 — Extend the formatter (formatter.lua)

In `format()` (formatter.lua:18), after the existing `line:` write, conditionally write `line_ref:` — **only if** `item.line_ref == "old"`. Do not write the field for `"new"` items. This keeps existing review.md files clean and avoids a pointless field on 99% of items.

The line format follows the existing pattern: `"line_ref: old"`.

### Step 3 — Extend the parser (parser.lua)

`parse_item()` already reads all `key: value` scalar lines via `parse_scalar_line()` and assigns them to `item[key]` (parser.lua:62). This means `line_ref` will be read automatically if present. No loop change needed.

After scalar parsing, add a normalisation step: if `item.line_ref ~= "old"` (i.e., it is nil, missing, or any other value), set `item.line_ref = "new"`. This ensures backwards compatibility: old items without the field get `"new"`.

### Step 4 — Extend build_comment_map() (pr_view.lua:76)

Change the map structure to separate old-line and new-line comments:
```
{ file → { new = { new_line → [items] }, old = { old_line → [items] } } }
```
When inserting an item: check `item.line_ref`. If `"old"`, insert into `map[file].old[item.line]`. If `"new"`, insert into `map[file].new[item.line]`.

### Step 5 — Extend apply_comment_badges() (pr_view.lua:201)

Update the lookup to use the new map structure:
- For lines where `meta.type == "add"` or `meta.type == "context"`: look up `comment_map[meta.file].new[meta.new_line]`. Same as before.
- For lines where `meta.type == "remove"`: look up `comment_map[meta.file].old[meta.old_line]`. Use highlight group `LocoCommentOld` (add to `setup_hl()`, link to `DiagnosticVirtualTextWarn`) instead of `LocoComment`.

### Step 6 — Extend add_comment_at_cursor() (pr_view.lua:357)

Remove the guard that rejects `"remove"` lines. Replace it with:
- If `meta.type == "remove"` and `meta.old_line ~= nil`: proceed, using `meta.old_line` as the line number and passing `line_ref = "old"` to `commands.add_at()`.
- If `meta.type == "add"` or `meta.type == "context"` and `meta.new_line ~= nil`: proceed as today, implicitly `line_ref = "new"`.
- Otherwise: warn and return.

Check whether `commands.add_at()` accepts a `line_ref` parameter. If not, you will need to add it — read commands.lua first.

### Gotchas
- `meta.old_line` is nil for "add" lines and `meta.new_line` is nil for "remove" lines. Never use the wrong one.
- `build_comment_map` is called from two places: `do_render()` (pr_view.lua:408) and the `K` keymap handler (T-04). Both must use the new map structure after this change.
- The formatter only writes `line_ref: old`. The parser reads whatever is there. After normalisation, every item in memory has `line_ref = "old"` or `line_ref = "new"`. The formatter must not write `line_ref: new` — that would pollute existing files.

### Verify
Open a diff. Press `c` on a `+` line — works as before. Press `c` on a `-` line — comment created. Check review.md: item has `line_ref: old`. Refresh PR view — badge appears on the `-` line in a different colour. Open PR view fresh (reload review.md) — badge still there.

---

## T-06 · Quick Comment
**Priority:** P2 · **Complexity:** Low · **File:** `lua/locoreview/pr_view.lua`

### Read first
- `add_comment_at_cursor()` (pr_view.lua:357) — the existing full flow you are complementing
- `commands.add_at()` — read its signature in commands.lua

### Goal
`C` creates a comment with a single `vim.ui.input` prompt (issue text only). Severity defaults to `"low"`, status to `"open"`, `requested_change` to `""`.

### Implementation

In `attach_keymaps()` (pr_view.lua:382), add `bmap("C", add_quick_comment_at_cursor)`.

Write `add_quick_comment_at_cursor()` as a new local function near `add_comment_at_cursor()`:
1. Call `meta_at_cursor()`. Apply the same line-validity check as `add_comment_at_cursor()` — valid for "add", "context", and (after T-05) "remove" lines.
2. Call `vim.ui.input({ prompt = "Quick note: " }, function(text) ... end)`.
3. If `text` is nil or `text:match("^%s*$")`: return (user cancelled or empty).
4. Call `store.insert()` directly (read store.lua for the exact signature) with `severity = "low"`, `status = "open"`, `requested_change = ""`, `issue = text`, `file = meta.file`, `line = meta.new_line or meta.old_line`, `line_ref = (meta.type == "remove" and "old" or "new")`.
5. Call `M.refresh()`.

Add `"  C          quick comment (one prompt, low severity)"` to `M.show_help()`.

### Gotchas
- Do not call `commands.add_at()` here — that function runs the full multi-prompt flow. You are bypassing it intentionally. Call `store.insert()` directly.
- Read `store.insert()` in store.lua before calling it. Do not guess its parameter names.
- After T-05, the quick comment must also work on remove lines. Pass `line_ref` correctly.

### Verify
Press `C` on a `+` line. Single prompt appears. Enter text. Badge appears immediately. Check review.md — item has `severity: low`. Press `C` and hit `<Esc>` — nothing happens.

---

## T-07 · Sticky File Header
**Priority:** P2 · **Complexity:** Medium · **File:** `lua/locoreview/pr_view.lua`

### Read first
- `do_open_or_refresh()` (pr_view.lua:427) — where the PR view window is created; float must be created here
- `get_win()` (pr_view.lua:253) — how to find the PR view window handle
- `M.close()` (pr_view.lua:552) — float must be destroyed here
- `state.file_header_lnums` — sorted array you will binary-search

### Goal
A 1-line floating window pinned to row 0 of the PR view window always shows the current file's header text. It updates on scroll and disappears when the real header is visible.

### Step 1 — Add state fields

In `state` (pr_view.lua:24), add:
```
sticky_win   = nil,   -- window handle for the sticky header float
sticky_buf   = nil,   -- buffer for the sticky header float
sticky_autocmd = nil, -- autocmd id for WinScrolled
```

### Step 2 — Create the float on open

Create a function `create_sticky_header(win)`. Call it from `do_open_or_refresh()` after the PR view window is set up and `setup_folds()` has run.

Inside `create_sticky_header(win)`:
1. If `state.sticky_win` is already valid (`vim.api.nvim_win_is_valid`), return early (already exists).
2. Create a scratch buffer: `vim.api.nvim_create_buf(false, true)`. Set `buftype = "nofile"`, `bufhidden = "wipe"`.
3. Get the win width: `vim.api.nvim_win_get_width(win)`.
4. Open float: `vim.api.nvim_open_win(buf, false, { relative = "win", win = win, row = 0, col = 0, width = win_width, height = 1, focusable = false, style = "minimal", zindex = 50 })`. `false` = do not focus.
5. Store handles in `state.sticky_win` and `state.sticky_buf`.
6. Register `WinScrolled` autocmd for the PR view window. In the callback, call `update_sticky_header()`. Store the autocmd id in `state.sticky_autocmd`.

### Step 3 — Update function

Write `update_sticky_header()`:
1. If `state.sticky_win` is not valid, return.
2. Get the PR view window via `get_win()`. If nil, return.
3. Get the top visible line: `vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)`.
4. Walk `state.file_header_lnums` backwards (from end) to find the largest lnum that is `<= top_visible_line`. That is the enclosing file header.
5. If no such lnum (cursor is above all file headers), hide the float: set its buffer to a blank line.
6. If the enclosing header lnum equals `top_visible_line` (real header is visible): set the float buffer to a blank line (hide by showing nothing).
7. Otherwise: read the actual header text from the buffer: `vim.api.nvim_buf_get_lines(state.buf, lnum-1, lnum, false)[1]`. Write it to `state.sticky_buf`. Apply the same highlight group as the real header (`LocoFileViewed` or `LocoFileHeader` based on `state.line_map[lnum].is_viewed`).

Call `update_sticky_header()` once at the end of `do_open_or_refresh()` to initialise it on open.
Call `update_sticky_header()` at the end of `do_render()` (after highlights are applied) so it updates on refresh too.

### Step 4 — Destroy on close

In `M.close()` (pr_view.lua:552), before the tabclose:
- If `state.sticky_autocmd ~= nil`: `vim.api.nvim_del_autocmd(state.sticky_autocmd)`. Set to nil.
- If `state.sticky_win` is valid: `vim.api.nvim_win_close(state.sticky_win, true)`. Set to nil.
- If `state.sticky_buf` is valid: it will be wiped automatically (`bufhidden = "wipe"`). Set to nil.

Add the same teardown to the `BufDelete` autocmd callback (pr_view.lua:459).

### Gotchas
- `WinScrolled` fires for any window scroll in any window. Check that the window that scrolled is the PR view window before updating. Use the `win` argument in the autocmd callback (it provides the scrolled window id as `vim.fn.expand("<afile>")` — but better to just call `get_win()` and compare).
- Writing to `state.sticky_buf` requires it to be modifiable. Set `modifiable = true`, write, set `modifiable = false` each time.
- The sticky float covers row 0 of the PR view window. If the PR view already shows a file header at row 0, both the real header and the float are visible. The Step 3 check (hide when real header is visible at `w0`) prevents this duplication.
- `relative = "win"` floats are positioned relative to the window grid, not the buffer content. `row = 0, col = 0` always means the top-left corner of the window, regardless of scroll position. This is the correct behaviour.

### Verify
Open a large diff. Scroll down into a file's diff body — the sticky header shows the file name at top. Scroll back up to see the real file header — sticky header disappears. Refresh (`R`) — sticky header updates. Close (`q`) — sticky float is gone.

---

## T-08 · Hunk Context Collapse
**Priority:** P3 · **Complexity:** High · **File:** `lua/locoreview/pr_view.lua`

### Read first
- `state.hunk_header_lnums` — the array you will use to find hunk boundaries
- `state.line_map` — every line has `type` and `hunk_idx`. Context lines have `type = "context"`.
- `apply_comment_badges()` (pr_view.lua:201) — uses `ns` namespace. Your collapse marks need a separate namespace.
- `setup_folds()` (pr_view.lua:227) — fold method is `manual`. Do not touch this.

### Goal
`zC` collapses context lines in the hunk under the cursor using extmarks (not folds). Context lines appear replaced by `[· N context lines ·]` virtual text. `zO` expands them. `zCA`/`zOA` apply to all hunks in the current file.

### Step 1 — Add namespace and state

In `state` (pr_view.lua:24), add:
```
hunk_ctx_ns  = nil,   -- namespace for context-collapse extmarks
hunk_ctx_marks = {},  -- { hunk_header_lnum → { extmark_ids... } }
```

Create the namespace lazily, similarly to `ensure_ns()`. Name it `"locoreview_pr_ctx"`. Store the handle in `state.hunk_ctx_ns` on first use.

### Step 2 — Find context lines for a hunk

Write a helper `get_context_lnums_for_hunk(hunk_header_lnum)`:
1. Get `meta = state.line_map[hunk_header_lnum]`. Extract `meta.hunk_idx` and `meta.file_idx`.
2. Iterate `state.line_map` entries where `meta.hunk_idx == target_hunk_idx` and `meta.file_idx == target_file_idx` and `meta.type == "context"`. Collect their lnums.
3. Return the sorted list of lnums.

Note: iterating all of `state.line_map` is O(n) over total lines. For large diffs this is acceptable; do not over-optimise.

### Step 3 — Collapse a hunk

Write `collapse_hunk_context(hunk_header_lnum)`:
1. If `state.hunk_ctx_marks[hunk_header_lnum]` is already populated, return (already collapsed).
2. Get context lnums via `get_context_lnums_for_hunk()`. If empty, return.
3. For each context lnum: place an extmark on that line (0-indexed: `lnum - 1`) using `state.hunk_ctx_ns` with `conceal = " "` to hide the line text, and `virt_text = {}` (no replacement text on individual lines). Store the returned extmark id.
4. After hiding all context lines, place one more extmark on the line *after* the last context line (or on the last context line itself with `virt_lines`) showing `{ "  [· " .. count .. " context lines ·]", "Comment" }` as virtual text using `virt_lines = { ... }` (adds a virtual line, not eol text).
5. Store all extmark ids in `state.hunk_ctx_marks[hunk_header_lnum]`.

**Important:** `conceal` only works when `conceallevel >= 1`. Set `conceallevel = 2` on the PR view window when the first hunk is collapsed. Reset to `0` when all hunks are expanded.

### Step 4 — Expand a hunk

Write `expand_hunk_context(hunk_header_lnum)`:
1. Get the stored ids from `state.hunk_ctx_marks[hunk_header_lnum]`. If nil, return.
2. For each id: `vim.api.nvim_buf_del_extmark(state.buf, state.hunk_ctx_ns, id)`.
3. Set `state.hunk_ctx_marks[hunk_header_lnum] = nil`.
4. If `state.hunk_ctx_marks` is now empty: reset `conceallevel = 0` on the PR view window.

### Step 5 — Find hunk under cursor

Write `hunk_header_lnum_at_cursor()`:
- Get current lnum from cursor.
- `meta = state.line_map[lnum]`. Read `meta.hunk_idx` and `meta.file_idx`.
- Walk `state.hunk_header_lnums` backwards to find the largest lnum where `state.line_map[lnum].hunk_idx == meta.hunk_idx` and same `file_idx`. Return it.

### Step 6 — Keymaps

In `attach_keymaps()`:
- `zC`: call `hunk_header_lnum_at_cursor()`, then `collapse_hunk_context(result)`.
- `zO`: call `hunk_header_lnum_at_cursor()`, then `expand_hunk_context(result)`.
- `zCA`: get current file via `meta_at_cursor().file_idx`. Find all hunk header lnums for that file, call `collapse_hunk_context()` for each.
- `zOA`: same but expand.

### Step 7 — Clear on refresh

At the start of `do_render()` (pr_view.lua:407), before calling `render()`: clear the entire `state.hunk_ctx_ns` namespace with `vim.api.nvim_buf_clear_namespace(state.buf, state.hunk_ctx_ns, 0, -1)` and reset `state.hunk_ctx_marks = {}`. This is safe because `do_render()` rebuilds everything.

Add entries to `M.show_help()` for `zC`, `zO`, `zCA`, `zOA`.

### Gotchas
- `conceal` on an extmark hides the line's text in the rendered view but the line still exists in the buffer. Navigation (`]c`, `[c`) still works because it reads `state.hunk_header_lnums`, not screen positions.
- File-level folds (the `manual` folds set by `setup_folds()`) are completely independent. Collapsing a fold hides all lines in the range from the screen. Conceal hides individual lines. They coexist without conflict.
- `state.hunk_ctx_ns` must be created with `vim.api.nvim_create_namespace()` only once. Use a nil-check guard like `ensure_ns()` does for the main namespace.
- Do not clear `state.hunk_ctx_ns` from within `apply_highlights()` — that function clears only `n` (the main namespace). Hunk context is a separate namespace and is intentionally not cleared by highlights refresh.

### Verify
Open a diff. Press `zC` on a hunk — context lines vanish, virtual line shows count. Press `zO` — context returns. Press `zCA` — all hunks in file collapse. Press `R` to refresh — context marks cleared (reset to uncollapsed). Verify file folds still work independently.

---

## T-09 · File-Jump Picker
**Priority:** P3 · **Complexity:** Medium · **File:** `lua/locoreview/pr_view.lua`

### Read first
- `lua/locoreview/picker.lua` — the existing picker abstraction. Use it if it provides a suitable API. Read it fully.
- `state.file_diffs`, `state.file_header_lnums`, `state.line_map`
- `build_comment_map()` (pr_view.lua:76)

### Goal
`<leader>f` opens a picker listing all diff files. Unviewed first, then viewed. Selecting jumps to the file's section and opens its fold.

### Implementation

In `attach_keymaps()`, add `bmap("<leader>f", open_file_picker)`.

Write `open_file_picker()`:

1. Build entries: iterate `state.file_diffs`. For each `fd`:
   - `is_viewed` = check `state.line_map` for the file's header lnum and read `.is_viewed`, OR check `viewed_state.is_viewed(fd.file)`.
   - `comment_count` = look up in `build_comment_map(load_review_items())`.
   - `header_lnum` = find in `state.file_header_lnums` where `state.line_map[lnum].file == fd.file`.
   - Build display string: `(is_viewed and "✓" or "●") .. " " .. fd.file .. "  +" .. fd.stats.added .. " -" .. fd.stats.removed .. "  [" .. fd.status .. "]" .. (comment_count > 0 and ("  " .. comment_count .. " comment(s)") or "")`.

2. Sort entries: unviewed first, then viewed; within each group keep original order.

3. Detect picker backend by trying `pcall(require, "telescope")` then `pcall(require, "fzf-lua")`. Check if `picker.lua` already handles this detection — prefer reusing it.

4. On selection: get `entry.header_lnum`. Call `vim.api.nvim_win_set_cursor(win, { header_lnum, 0 })`. Open the fold: call `toggle_fold_at(header_lnum)` if the file is collapsed (check `state.line_map[header_lnum].is_viewed` — viewed files start collapsed).

5. Fall back to `vim.ui.select` if no picker is available.

Add `"  <leader>f    open file jump picker"` to `M.show_help()`.

### Gotchas
- Read picker.lua fully before writing any picker integration. It may already wrap Telescope/fzf-lua. Do not duplicate that logic.
- `toggle_fold_at()` (pr_view.lua:324) opens the fold if it is closed, and closes it if open. For unviewed files the fold starts open, so calling it would close the fold — wrong. Only call it if you know the fold is currently closed (viewed files). Check `state.line_map[header_lnum].is_viewed` before deciding whether to toggle.

### Verify
Open PR view. Press `<leader>f`. Picker shows all files, unviewed first. Select one — cursor jumps to its section, fold is open. Works with Telescope if installed, fzf-lua if installed, falls back to `vim.ui.select`.

---

## T-10 · Diff Annotation Heat Map
**Priority:** P3 · **Complexity:** Low · **File:** `lua/locoreview/pr_view.lua`

### Read first
- `apply_comment_badges()` (pr_view.lua:201) — runs after highlights; add heat map signs here or in a new function called from `do_render()`
- `state.file_header_lnums`
- `build_comment_map()` (pr_view.lua:76)

### Goal
Place a coloured `▌` sign on each file header line based on comment count: yellow for 1–2, red for 3+.

### Step 1 — Add namespace and state

In `state`, add:
```
heat_ns = nil,   -- namespace for heat map sign extmarks
```

Create lazily, name `"locoreview_pr_heat"`.

### Step 2 — Add highlight groups

In `setup_hl()` (pr_view.lua:47), add:
```
LocoHeatLow  = { link = "DiagnosticSignWarn" },   -- yellow
LocoHeatHigh = { link = "DiagnosticSignError" },  -- red
```

### Step 3 — Apply heat signs

Write `apply_heat_map(comment_map)`. Call it from `do_render()` (pr_view.lua:407) after `apply_comment_badges()`.

Inside `apply_heat_map()`:
1. Clear the namespace first: `vim.api.nvim_buf_clear_namespace(state.buf, state.heat_ns, 0, -1)`.
2. For each lnum in `state.file_header_lnums`:
   - Get `file = state.line_map[lnum].file`.
   - Count total items for this file: sum all items across all lines in `comment_map[file]` (or 0 if no entry).
   - If count == 0: no sign.
   - If count 1–2: place extmark with `sign_text = "▌"`, `sign_hl_group = "LocoHeatLow"`.
   - If count >= 3: place extmark with `sign_text = "▌"`, `sign_hl_group = "LocoHeatHigh"`.
3. Extmark call: `vim.api.nvim_buf_set_extmark(state.buf, state.heat_ns, lnum-1, 0, { sign_text = "▌", sign_hl_group = hl })`.

### Gotchas
- `sign_text` in extmarks requires Neovim 0.9+. If you need to support older versions, check `vim.fn.has("nvim-0.9")`. For now assume 0.9+ (the plugin already uses features that require it).
- The heat map uses its own namespace so `apply_highlights()` clearing `n` does not wipe the signs. The heat map clears its own namespace at the start of each `apply_heat_map()` call.
- Pass the same `comment_map` that `apply_comment_badges()` uses — build it once in `do_render()` and pass it to both functions, rather than building it twice.

### Verify
Open a PR with files that have varying comment counts. File with 0 comments: no sign. 1–2 comments: yellow `▌`. 3+: red `▌`. Add a comment via `c`, refresh — signs update.

---

## T-11 · Focus Mode
**Priority:** P2 · **Complexity:** High · **File:** `lua/locoreview/pr_view.lua`

### Read first
- The entire `pr_view.lua` — you are adding a layer that modifies the behaviour of many existing functions.
- `config.lua:5` — `pr_view.micro_rewards` key (added in T-02).
- T-08 ticket — Focus Level 2 activates hunk context collapse. Implement T-08 first.
- `state.hunk_header_lnums` and `state.file_header_lnums`.

### Goal
`<leader>F` cycles: **Off → File Focus → Hunk Focus → Off**. A brief echo confirms the level. No new `:` commands.

Focus File (Level 1): dims all files except current. Locks `]f`/`[f` to a priority queue order. Hides UI chrome. Enables micro-reward animation on `v`.

Focus Hunk (Level 2): all of Level 1, plus `<Space>` advances one hunk at a time with per-hunk dimming and context collapse.

### Step 1 — Add state fields

In `state` (pr_view.lua:24), add:
```
focus_level    = 0,    -- 0 = off, 1 = file, 2 = hunk
dim_ns         = nil,  -- namespace for file-level dimming
hunk_dim_ns    = nil,  -- namespace for hunk-level dimming
focus_queue    = {},   -- ordered list of file paths (priority queue)
focus_file_idx = 1,    -- current position in focus_queue
focus_hunk_idx = 1,    -- current hunk index within focus_queue[focus_file_idx]
saved_ui       = {},   -- saved vim options: { laststatus, showtabline }
```

Create `dim_ns` and `hunk_dim_ns` lazily, named `"locoreview_pr_dim"` and `"locoreview_pr_hdim"`.

### Step 2 — <leader>F keymap

In `attach_keymaps()`, add `bmap("<leader>F", cycle_focus)`.

`cycle_focus()`:
- `state.focus_level = (state.focus_level + 1) % 3`.
- If new level == 0: call `exit_focus()`.
- If new level == 1: call `enter_focus(1)`.
- If new level == 2: call `enter_focus(2)`.
- Echo level name: `vim.api.nvim_echo({{ "-- Focus: " .. label .. " --", "ModeMsg" }}, false, {})`.

### Step 3 — Build the priority queue

Write `build_focus_queue()`. Returns a list of file paths sorted by:
1. Unviewed files first (check `viewed_state.is_viewed(fd.file)`).
2. Within unviewed: sort by `fd.stats.added + fd.stats.removed` descending (most changed first) — this is the `"size"` queue order from config (`config.get().pr_view.focus_queue_order`).
3. Within unviewed same size: files with comments first (check comment count).
4. Viewed files last, alphabetical.

Call `build_focus_queue()` inside `enter_focus()`. Store result in `state.focus_queue`.

### Step 4 — enter_focus(level)

`enter_focus(level)`:
1. Save UI options into `state.saved_ui`: `{ laststatus = vim.o.laststatus, showtabline = vim.o.showtabline }`. Save only these two — not `signcolumn` (that is window-local and already set to `"no"` by the PR view window setup).
2. Apply UI changes: `vim.o.laststatus = 0`, `vim.o.showtabline = 0`.
3. Call `build_focus_queue()`. Set `state.focus_file_idx = 1`, `state.focus_hunk_idx = 1`.
4. Call `apply_dim_layer()` to dim all files except the current one (the first in the queue).
5. If level == 2: also call `apply_hunk_dim_layer()` for the current hunk.
6. Register a `CursorMoved` autocmd on `state.buf` that calls `update_focus_dim()`. Store the autocmd id in a local or in state for cleanup.

### Step 5 — apply_dim_layer(except_file)

`apply_dim_layer(except_file)`:
1. Clear `state.dim_ns`: `vim.api.nvim_buf_clear_namespace(state.buf, state.dim_ns, 0, -1)`.
2. Iterate all lines in `state.line_map`. For lines where `meta.file ~= except_file` (and `meta.file ~= nil`): place an extmark with `hl_group = "Comment"` on that line. This makes the text look dimmed (same colour as comments).
3. Do NOT dim section header lines (`type = "section_header"`) or the progress line (`type = "progress"`).

**Do not use `hl_mode = "combine"`** — that blends with existing highlights. Use `hl_group = "Comment"` with a high `priority` (e.g., 200) so it overrides `DiffAdd`/`DiffDelete` highlights on dimmed lines.

### Step 6 — update_focus_dim()

Called on `CursorMoved` (when in focus mode). Determines which file the cursor is currently on:
- Read `meta_at_cursor().file`. If nil (on section header / progress line), do nothing.
- If the file changed since last call: update `state.focus_file_idx` to the position of that file in `state.focus_queue`. Call `apply_dim_layer(new_file)`.
- If level == 2: also update hunk dim.

### Step 7 — Focus Level 2: <Space> advances hunks

In `attach_keymaps()`, add `bmap("<Space>", focus_advance_hunk)`.

`focus_advance_hunk()`:
- If `state.focus_level ~= 2`: pass `<Space>` through (do not intercept). Use `vim.api.nvim_feedkeys(" ", "n", false)` to forward it.
- If `state.focus_level == 2`:
  - Find the next hunk header lnum after current cursor position in `state.hunk_header_lnums` (same logic as `navigate_hunks(1)`).
  - If the next hunk is in a different file (check `state.line_map[next_hunk_lnum].file_idx`), advance `state.focus_file_idx` in the queue.
  - Move cursor to the hunk header lnum.
  - Center: `vim.cmd("normal! zz")`.
  - Call `apply_hunk_dim_layer(hunk_lnum)`.
  - Call T-08's `collapse_hunk_context()` for all other hunks in the current file (only show clean `+`/`-` for the active hunk).

### Step 8 — apply_hunk_dim_layer(active_hunk_lnum)

Similar to `apply_dim_layer` but at hunk granularity:
1. Clear `state.hunk_dim_ns`.
2. Get the active hunk's `file_idx` and `hunk_idx` from `state.line_map[active_hunk_lnum]`.
3. Dim all lines in the current file that belong to a different hunk (same file_idx, different hunk_idx). Same `hl_group = "Comment"` with high priority.

### Step 9 — Micro-rewards (Level 1 + Level 2)

In `mark_viewed_at_cursor()` (pr_view.lua:340), after `viewed_state.mark_viewed()` and before `M.refresh()`:
- Check `state.focus_level > 0` and `config.get().pr_view.micro_rewards`.
- If both true: get the file's header lnum. Place extmarks with `virt_text = { { " ✓ ✓ ✓ done ✓ ✓ ✓", "DiagnosticSignOk" } }` at `virt_text_pos = "eol"` on the header line. Use the main namespace `n` — it will be cleared by the upcoming `M.refresh()` anyway. Use `vim.defer_fn(function() M.refresh() end, 300)` instead of calling `M.refresh()` directly — the 300ms delay lets the reward animation be visible before the buffer is re-rendered.

**Important:** when using `vim.defer_fn`, do NOT call `M.refresh()` both immediately and in the deferred fn. Replace the direct `M.refresh()` call with only `vim.defer_fn`.

### Step 10 — exit_focus()

`exit_focus()`:
1. Clear `state.dim_ns` and `state.hunk_dim_ns`.
2. Restore `vim.o.laststatus = state.saved_ui.laststatus`, `vim.o.showtabline = state.saved_ui.showtabline`.
3. Reset `state.focus_level = 0`, `state.focus_queue = {}`, `state.saved_ui = {}`.
4. Delete the `CursorMoved` autocmd if registered.
5. Remove the `<Space>` keymap override: `vim.keymap.del("n", "<Space>", { buffer = state.buf })`.
6. Call `M.refresh()` to restore normal highlighting.

### Step 11 — Cleanup on close

In `M.close()` (pr_view.lua:552): if `state.focus_level > 0`, call `exit_focus()` before closing the tab. This restores UI options even when the user presses `q` without cycling out of focus mode.

Add to `M.show_help()`:
```
"  <leader>F    cycle focus mode (Off → File → Hunk)"
"  <Space>      advance to next hunk (Focus Hunk mode only)"
```

### Gotchas
- The dim layer uses `hl_group = "Comment"` at high priority. This means even `DiffAdd` (green) and `DiffDelete` (red) lines in dimmed files appear as `Comment` colour. This is intentional — it maximises contrast between the active file and everything else.
- **Do not** save and restore `signcolumn` — the PR view window already sets it to `"no"` on open (pr_view.lua:489). Restoring it to a different value would break the window.
- `vim.o.laststatus` and `vim.o.showtabline` are global options. Setting them to `0` affects the entire Neovim session. Restore them precisely on `exit_focus()`. If the user has non-default values, `saved_ui` captures them correctly.
- The `<Space>` keymap is only active in focus level 2. In `focus_advance_hunk()`, check `state.focus_level == 2` first and forward `<Space>` via `nvim_feedkeys` if not in level 2. Alternatively, set the keymap only in `enter_focus(2)` and delete it in `enter_focus(1)` or `exit_focus()`.
- `vim.defer_fn` for micro-rewards: the 300ms fires after the current event loop tick. If the user presses `v` again within 300ms (unlikely but possible), a second `M.refresh()` could fire. This is harmless — the buffer just re-renders twice. Do not add locking.

### Verify
Enter Focus File (`<leader>F` once): all files except the first in queue are dimmed. `]f` moves through queue order. Press `v` — micro-reward ripple flashes, cursor advances to next unviewed file. Enter Focus Hunk (`<leader>F` twice): `<Space>` advances one hunk at a time, each centered, context collapsed, rest dimmed. Exit (`<leader>F` three times): all normal, statusline restored.
