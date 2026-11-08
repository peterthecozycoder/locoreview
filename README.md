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

1. Press `<leader>ra` (`:ReviewAdd`) on a source line or a visual selection.
2. Write your comment in the floating editor. A requested change is optional.
   **Ctrl-S** saves, **Ctrl-G** cycles priority, and **Ctrl-C** cancels.
   Escape returns to normal mode; `q` in normal mode also cancels.
3. Press `<leader>rv` (`:ReviewShow`) to manage comments at the current line,
   or `<leader>rl` (`:ReviewList`) to browse open comments across the repository.
4. In either view, move to a comment and press `e` to edit or `f` to resolve it.
   Press `a` to include resolved comments; `f` reopens a selected resolved comment.

The editor supports multiline text. When editing an existing comment, **Ctrl-T**
cycles its status (`open`, `fixed`, `blocked`, `wontfix`) before saving.
Priority is stored as the existing `severity` field (`low`, `medium`, `high`).
Failed saves keep the draft open. Comments are stored in `review.md`; you decide
whether to commit it or add it to your repository's ignore rules.

## Comment view

Actions apply to the comment under the cursor, including when several comments
share the same source line. The same view opens from `K` in a diff.
The title shows the scope, open/all filter, and comment count.

| Key | Action |
| --- | --- |
| `e` | Edit text, priority, and status in one editor |
| `f` | Resolve an open comment, or reopen a non-open comment |
| `Ctrl-G` | Cycle and save priority immediately |
| `d` | Delete the selected comment after confirmation |
| `Enter` | Go to the source (current-revision comments only) |
| `]c` / `[c` | Next / previous comment, wrapping at the ends |
| `/` | Search with Neovim's normal buffer search |
| `a` | Toggle open/all comments within the current scope |
| `R` | Reload comments and refresh signs and the diff |
| `O` | Open the Markdown review file |
| `Q` | Send the visible comments to quickfix |
| `p` | Pick from the visible comments with an optional picker |
| `S` | Toggle source signs |
| `?` | Show shortcuts |
| `q` / `Esc` | Close |

## Review a diff

`:ReviewPR` opens staged and unstaged changes against HEAD. Pass a base explicitly,
for example `:ReviewPR origin/main`, to review committed branch changes against
the merge base. Untracked files are not included in Git's diff.

| Key | Action |
| --- | --- |
| `c` | Add a comment on the diff line |
| `K` | Read and manage comments on the diff line |
| `L` | Browse repository comments |
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

Only four global commands and four normal-mode shortcuts are installed:

| Command | Default key | Purpose |
| --- | --- | --- |
| `[range]ReviewAdd` | `<leader>ra` (normal or visual) | Add a comment |
| `ReviewShow` | `<leader>rv` | Manage comments at the source line |
| `ReviewList` | `<leader>rl` | Browse and manage repository comments |
| `ReviewPR [base_ref]` | `<leader>rP` | Browse a diff |

For example, `:10,15ReviewAdd` comments on lines 10–15. Management actions and
navigation live inside the views rather than in global commands or mappings.

## Configuration

```lua
require("locoreview").setup({
  review_file = "review.md",
  default_severity = "medium", -- low, medium, high
  default_author = nil,
  base_branch = nil,           -- auto-detect for diff_only
  diff_only = false,
  signs = { enabled = true, priority = 20 },
  picker = { enabled = true, backend = "auto" },
  keymaps = true,              -- false, or overrides such as { add = "<leader>ca" }
})
```

The picker tries Telescope, fzf-lua, Snacks, then Neovim's built-in selection UI.
Use `backend = "none"` for the built-in UI. All integrations are optional.

## Changes from the earlier interface

Adding and editing use one editor instead of three prompts. `ReviewShow` replaces
`ReviewOpenDiff` and now opens an interactive comment view. `ReviewList` opens the
same view for the repository instead of opening quickfix directly.

`ReviewAddRange` is folded into `ReviewAdd`. The visual shortcut is now
`<leader>ra`; override `add_range` to keep a different visual shortcut.
`ReviewEdit`, status commands, `ReviewDelete`, navigation, picker, quickfix,
Markdown-file, refresh, and sign commands are replaced by view-local shortcuts.
`ReviewAddDiff` is replaced by the `diff_only` setting or commenting in the diff.
`ReviewClean` is removed; resolved comments remain available through the all
filter and can be deleted individually. The four commands above have no legacy
aliases. Keymap override names are now `add`, `add_range`, `show`, `list`, and `pr`.

Timers, rhythm modes, file moods, rewards, viewed-state tracking, source-file
rename/delete actions, and the external-agent `ReviewFix` command are removed.
Remove `agent`, `pr_view`, and old action keymap overrides from older configurations.
Existing review files remain readable. Requested changes are review text and are
never applied automatically as source code.

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
