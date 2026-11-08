# locoreview

Local code review comments for Neovim. Add a comment where you're reading code,
come back to it later, and keep the conversation in a repository-local Markdown file.
No service, account, or runtime plugin dependency is required.

Requires **Neovim 0.10+** and Git for diff review. Run Neovim from your repository.

## Install

With lazy.nvim:

```lua
{
  "peterthecozycoder/locoreview",
  opts = {},
}
```

Or call `require("locoreview").setup({})` from your configuration.

## Everyday workflow

1. Place your cursor on a line and press `<leader>ra` (`:ReviewAdd`).
   For a range, select lines visually and press `<leader>rA`.
2. Write your comment in the floating editor. A requested change is optional.
   Press **Ctrl-S** to save, **Ctrl-G** to cycle severity, or **Ctrl-C** to cancel.
   Escape returns to normal mode; `q` in normal mode also cancels.
3. Press `<leader>rv` (`:ReviewShow`) to read comments on the current line,
   or `<leader>rl` (`:ReviewList`) to browse open comments in quickfix.
4. Use `<leader>re` to edit a comment and `<leader>rf` to mark it fixed.

The editor starts with your configured severity and supports multiline text.
Failed saves keep the draft open. Comments are stored in `review.md`; you decide
whether to commit it or add it to your repository's ignore rules.

## Review a diff

`:ReviewPR` opens staged and unstaged changes against HEAD. Pass a base explicitly,
for example `:ReviewPR origin/main`, to review committed branch changes against
the merge base. Untracked files are not included in Git's diff.

| Key | Action |
| --- | --- |
| `c` | Add a comment on the diff line |
| `K` | Read all comments on the diff line |
| `]f` / `[f` | Next / previous file |
| `]c` / `[c` | Next / previous hunk |
| `go` | Open the source in a new tab (current-revision lines only) |
| `R` | Refresh |
| `?` | Help |
| `q` | Close |

Removed-line comments retain their old path and revision marker. They are shown
on the removed side of the diff, not on an unrelated line in the current file.
Comments use fixed line numbers; they do not automatically follow later edits.

## Commands

| Command | Default key | Purpose |
| --- | --- | --- |
| `ReviewAdd` | `<leader>ra` | Comment on the current line |
| `ReviewAddRange` | `<leader>rA` (visual) | Comment on selected lines |
| `ReviewShow` | `<leader>rv` | Read comments at the current line |
| `ReviewList` | `<leader>rl` | List open comments in quickfix |
| `ReviewPicker` | `<leader>rk` | Select a comment and jump to its location |
| `ReviewNext` / `ReviewPrev` | `<leader>rn` / `<leader>rp` | Navigate open comments |
| `ReviewEdit` | `<leader>re` | Edit the first comment at the current line |
| `ReviewMarkFixed` | `<leader>rf` | Resolve the first open comment at the current line |
| `ReviewReopen` | `<leader>rr` | Reopen a resolved comment |
| `ReviewDelete` | `<leader>rD` | Delete a comment after confirmation |
| `ReviewOpen` | `<leader>ro` | Open the Markdown file |
| `ReviewPR [base_ref]` | `<leader>rP` | Browse a diff |
| `ReviewRefresh` | `<leader>rR` | Refresh signs, quickfix, and the open diff |
| `ReviewToggleSigns` | `<leader>rs` | Toggle comment signs |

Additional commands: `ReviewListAll [status=open] [severity=high] [file=path]`,
`ReviewAddDiff` (only allow changed lines against the configured base),
`ReviewMarkBlocked`, `ReviewMarkWontfix`, and `ReviewClean` (permanently remove fixed comments).
The existing `open`, `fixed`, `blocked`, and `wontfix` statuses remain supported.

## Configuration

```lua
require("locoreview").setup({
  review_file = "review.md",
  default_severity = "medium", -- low, medium, high
  default_author = nil,
  base_branch = nil,           -- auto-detect for ReviewAddDiff / diff_only
  diff_only = false,
  signs = { enabled = true, priority = 20 },
  picker = { enabled = true, backend = "auto" },
  keymaps = true,              -- false, or overrides such as { add = "<leader>ca" }
})
```

The picker tries Telescope, fzf-lua, Snacks, then Neovim's built-in selection UI.
Use `backend = "none"` for the built-in UI. All integrations are optional.

## Changes from the earlier interface

Adding and editing now use one editor instead of three prompts. `ReviewShow`
replaces `ReviewOpenDiff`; the separate suggestion workspace is removed.
`ReviewPR` opens uncommitted changes immediately instead of asking for a mode.

Timers, rhythm modes, file moods, rewards, viewed-state tracking, source-file
rename/delete actions, and the external-agent `ReviewFix` command have been removed.
Remove `agent`, `pr_view`, `fix`, and `open_diff` overrides from older configurations;
use the `show` keymap override for `ReviewShow`. Existing review files remain readable.
Requested changes are review text and are never applied automatically as source code.

## Development

Production code lives in `lua/locoreview`: parsing and formatting, persistence,
commands, comment UI, and diff rendering are separate modules. Tests run in isolated
Neovim processes, with real editor tests for the composer, diff view, and file saves.

```sh
git clone --depth 1 https://github.com/nvim-lua/plenary.nvim .deps/plenary.nvim
make test
```

Plenary is a test-only dependency. Set `PLENARY_PATH` to use an existing checkout.
CI runs the same test command. See `:help locoreview` for the command reference.
