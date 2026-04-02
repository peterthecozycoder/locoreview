# locoreview diff workspace skill

## When to use this skill

Use this skill when implementing or refactoring `locoreview` features related to:

- opening a dedicated diff/review workspace from `review.md`
- rendering PR comment context in a side-by-side view
- navigating comments/hunks
- syncing review actions back to markdown
- applying or rejecting suggested changes

Do **not** build a fake diff by manually drawing text inside the markdown buffer unless there is a very strong reason. Neovim already has the right primitives: buffers, windows, tabs, scratch buffers, and built-in diff mode.  [oai_citation:0‡Neovim](https://neovim.io/doc/user/api/?utm_source=chatgpt.com)

## Core mental model

Neovim UI is built from:

- **buffers**: hold text
- **windows**: display buffers
- **tabpages**: group windows into a workspace

A diff review UI should usually be modeled as a **dedicated tabpage or split layout** containing generated scratch buffers, not as inline rendering inside `review.md`. Diff mode operates per tabpage, which makes a separate review workspace the cleanest architecture.  [oai_citation:1‡Neovim](https://neovim.io/doc/user/api/?utm_source=chatgpt.com)

## Recommended architecture

Keep `review.md` as the durable source of truth.

Build a separate ephemeral review workspace:

- `review.md` buffer:
  - authoritative comment/task state
  - editable by the user
- diff workspace:
  - generated from parsed review entries
  - scratch buffers only
  - actions write back to `review.md`

Recommended modules:

- `parser.lua`
  - parse `review.md` into structured review items
- `model.lua`
  - normalize comment state, file targets, line ranges, status
- `workspace.lua`
  - create/reuse tabpage, windows, scratch buffers
- `diff_view.lua`
  - populate left/right buffers and enable diff mode
- `actions.lua`
  - resolve, block, delete, apply, open source
- `sync.lua`
  - persist state changes back into `review.md`

## Preferred UX

Expose commands such as:

- `:LocoReviewOpenDiff`
- `:LocoReviewNextComment`
- `:LocoReviewPrevComment`
- `:LocoReviewResolve`
- `:LocoReviewBlock`
- `:LocoReviewDelete`
- `:LocoReviewApply`
- `:LocoReviewOpenSource`

Preferred layout:

- new tabpage
- left window = source/original hunk
- right window = patched/commented/proposed hunk
- optional third narrow panel or float for metadata/actions

Use normal splits or a tabpage first. Floats are useful for lightweight widgets, but they are not the best default for the main diff workspace. Neovim supports both scratch buffers and floating windows through the API.  [oai_citation:2‡Neovim](https://neovim.io/doc/user/api/?utm_source=chatgpt.com)

## Implementation strategy

### 1. Parse markdown into structured items

Your parser should produce something like:

```lua
---@class ReviewComment
---@field id string
---@field file_path string
---@field start_line integer
---@field end_line integer
---@field side "LEFT"|"RIGHT"|"INLINE"
---@field body string
---@field status "open"|"resolved"|"blocked"|"done"
---@field suggestion string|nil
---@field hunk_header string|nil
```

Do not couple rendering logic to raw markdown parsing. Parse once into structured objects.

### 2. Generate buffers for a selected comment

For a selected review item, derive:
- original text slice
- proposed text slice or patched result
- enough surrounding context lines

Make this a pure function:

```lua
build_diff_payload(comment) -> {
  left_lines = {...},
  right_lines = {...},
  source_path = "...",
  line_map = {...},
}
```

The line map matters. You will need it later for:
- jumping to source
- applying changes
- preserving comment identity across refreshes

### 3. Create scratch buffers

Use scratch buffers for generated content. Neovim provides `nvim_create_buf()` for this, and windows can display those buffers normally.

Typical properties:
- `buftype = "nofile"`
- `bufhidden = "wipe"`
- `swapfile = false`
- `modifiable = true` while populating, then `false`
- filetype set to the source language when possible for syntax highlighting

### 4. Open a dedicated workspace

Open a new tabpage or a split layout, then place the scratch buffers into the windows.

Reason: diff mode works per tabpage. Treat the review view as a self-contained workspace.

### 5. Use built-in diff mode

Do not implement your own visual diff renderer for the first version.

Use built-in diff windows so you get:
- change highlighting
- fold behavior for unchanged regions
- diff navigation like `]c` and `[c`
- aligned scrolling
- standard diff UX

Neovim's diff mode is intended exactly for this use case and supports side-by-side comparison windows.

Practical setup pattern:
- create left/right windows
- place left/right buffers
- enable diff mode in both windows
- optionally call `:diffupdate` after buffer changes

### 6. Add metadata with extmarks, not inline text hacks

For comment IDs, statuses, badges, or action hints:
- prefer extmarks
- use virtual text or signs where helpful
- keep actual diff buffer text clean

Do not inject lots of fake lines into the diff buffers unless absolutely necessary. That breaks line mapping.

### 7. Sync actions back to markdown

Actions in the diff view should update the model first, then serialize back to `review.md`.

Examples:
- resolve comment → update status in model → patch markdown section
- delete comment → remove model item → rewrite markdown block
- apply suggestion → patch source file and mark comment addressed

Keep markdown rewriting isolated in `sync.lua`. Do not scatter markdown mutation across UI code.

## Minimal MVP

A good first implementation only needs:
- parse one comment from `review.md`
- open tabpage with 2 scratch buffers
- fill left/right with hunk context
- turn on diff mode
- add keymaps for next/prev/resolve/open source
- persist status back to markdown

That is enough to prove the architecture.

## Recommended API usage

Use these Neovim primitives:
- `vim.api.nvim_create_buf()` for scratch buffers
- `vim.api.nvim_open_win()` if you need floats
- normal window/tab commands for the main layout
- window-local diff mode
- `vim.keymap.set()` for buffer-local actions

Neovim explicitly documents scratch buffers and floating windows through `nvim_create_buf()` and `nvim_open_win()`.

## Key design rules

**Prefer generated views over editable pseudo-UIs**

The markdown file is the editable artifact.
The diff workspace is generated and mostly read-only.

**Do not let UI code parse markdown**

Always go through structured model objects.

**Keep line mapping explicit**

Every rendered line in the diff view should be traceable to:
- source file path
- original line number or nil
- proposed line number or nil
- comment id

Without this, apply/open-source/navigation gets messy fast.

**Treat workspace state as disposable**

You should be able to close and rebuild the diff workspace from `review.md` at any time.

**Be resilient to source drift**

Files will change after comments are written. Support best-effort re-anchoring using:
- file path
- line range
- hunk header
- nearby context lines

Do not assume stored line numbers remain exact forever.

## Suggested buffer-local keymaps

- `q` → close workspace
- `]r` → next review comment
- `[r` → previous review comment
- `go` → open source file
- `gr` → mark resolved
- `gb` → mark blocked
- `gd` → delete comment
- `ga` → apply suggestion
- `R` → refresh diff

Prefer buffer-local mappings so the workspace is self-contained.

## Pseudocode skeleton

```lua
local M = {}

function M.open_diff_for_current_comment()
  local review_buf = vim.api.nvim_get_current_buf()
  local comment = require("locoreview.parser").current_comment(review_buf)
  if not comment then
    return
  end

  local payload = require("locoreview.model").build_diff_payload(comment)

  local left_buf = vim.api.nvim_create_buf(false, true)
  local right_buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, payload.left_lines)
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, payload.right_lines)

  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, left_buf)
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, right_buf)

  vim.cmd("windo diffthis")
  vim.cmd("diffupdate")

  require("locoreview.workspace").attach_keymaps(left_buf, right_buf, comment)
  require("locoreview.workspace").decorate(comment, payload)
end

return M
```

This is intentionally simple. The main point is the architecture, not exact command sequencing.

## Common mistakes to avoid

**1. Rendering everything inside `review.md`**

This seems simpler at first and becomes painful later:
- cursor movement gets weird
- line mapping becomes fragile
- edits mix content and UI state
- refresh is hard

**2. Building a fake diff engine first**

Neovim already has diff mode. Use it first. Only custom-render later if you truly need behavior the built-in engine cannot provide.

**3. Mixing parsing, rendering, and persistence**

These need clean separation:
- parser reads markdown
- model normalizes state
- view renders workspace
- sync writes markdown

**4. Forgetting diff scope is tab-based**

If you try to jam unrelated diff views into one tabpage, behavior gets confusing. Diff mode is scoped to the tabpage workspace.

**5. No refresh path**

Always provide a rebuild/refresh command so the diff workspace can be regenerated after:
- source changes
- comment changes
- markdown edits

## Acceptance checklist

Implementation is acceptable when all of the following are true:
- selecting a comment in `review.md` can open a dedicated diff workspace
- the workspace uses scratch buffers, not temp files
- left/right views are shown in actual diff mode
- actions are buffer-local and discoverable
- resolving/blocking/deleting syncs back into `review.md`
- source line mapping is preserved
- the workspace can be rebuilt safely
- source drift does not catastrophically break the feature

## What to do first

Implement in this order:
1. parser returns one structured comment
2. build left/right diff payload
3. create scratch buffers
4. open tab + vsplit
5. enable diff mode
6. add `q`, `go`, `gr`
7. sync status back to markdown
8. then add next/prev/apply/refresh

## Final guidance

Aim for a generated, disposable diff workspace powered by Neovim's native primitives. Buffers and windows are the foundation, and diff mode should do the heavy lifting. Keep markdown as the canonical review artifact and treat the visual diff as a projection of that state, not the state itself.

**Tldr:** push toward a **tab-based scratch-buffer diff workspace**, not inline markdown rendering, with clean separation between parsing, model, view, and sync.
