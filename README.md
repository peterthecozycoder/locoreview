# locoreview

`locoreview` is a local-first Neovim plugin for capturing, listing, and resolving structured code review comments in a repo-local markdown file.

## Installation (lazy.nvim)

```lua
{
  "peterthecozycoder/locoreview",
  opts = {
    review_file = "review.md",
    default_severity = "medium",
    signs = { enabled = true, priority = 20 },
    picker = { enabled = true, backend = "auto" },
    agent = {
      enabled = false,
      cmd = "agent",
      open_in_split = true,
    },
  },
}
```

## Minimal Setup

```lua
require("locoreview").setup({})
```

## Commands

### Review Management

| Command | Description |
| --- | --- |
| `:ReviewOpen` | Open review file, create if missing |
| `:ReviewAdd` | Add item for current line |
| `:ReviewAddRange` | Add item for visual range |
| `:ReviewAddDiff` | Add only on changed diff lines |
| `:ReviewList` | Quickfix list of open items |
| `:ReviewListAll` | Quickfix list with optional filters |
| `:ReviewPicker` | Open picker for items |
| `:ReviewNext` | Jump to next open item |
| `:ReviewPrev` | Jump to previous open item |

### Review Item Transitions

| Command | Description |
| --- | --- |
| `:ReviewEdit` | Edit issue/requested_change/severity |
| `:ReviewMarkFixed` | Transition open item to fixed |
| `:ReviewReopen` | Transition non-open item to open |
| `:ReviewMarkBlocked` | Transition open item to blocked |
| `:ReviewMarkWontfix` | Transition open item to wontfix |
| `:ReviewDelete` | Delete item at current location |

### Utilities

| Command | Description |
| --- | --- |
| `:ReviewPR [base_ref]` | Open PR review buffer against optional base ref |
| `:ReviewOpenDiff` | Open item-focused diff view at current location |
| `:ReviewFix` | Run external agent command |
| `:ReviewRefresh` | Reload signs and quickfix from disk |
| `:ReviewToggleSigns` | Toggle signs for session |

## Configuration

| Option | Type | Default |
| --- | --- | --- |
| `review_file` | `string` | `"review.md"` |
| `base_branch` | `string\|nil` | `nil` |
| `keymaps` | `boolean\|table` | `true` |
| `default_severity` | `"low"\|"medium"\|"high"` | `"medium"` |
| `default_author` | `string\|nil` | `nil` |
| `signs.enabled` | `boolean` | `true` |
| `signs.priority` | `number` | `20` |
| `picker.enabled` | `boolean` | `true` |
| `picker.backend` | `"auto"\|"telescope"\|"fzf_lua"\|"snacks"\|"none"` | `"auto"` |
| `diff_only` | `boolean` | `false` |
| `agent.enabled` | `boolean` | `false` |
| `agent.cmd` | `string\|function` | `"agent"` |
| `agent.open_in_split` | `boolean` | `true` |
| `pr_view.rhythm_advance_key` | `string\|nil` | `nil` (auto) |

## Sample Review File

```md
# Review Comments

## RV-0001
file: lua/locoreview/store.lua
line: 42
end_line:
severity: medium
status: open
author: peter
created_at: 2026-03-28T15:30:00Z
updated_at: 2026-03-28T15:30:00Z

issue:
This branch mixes parsing and persistence.

requested_change:
Split parsing into parser.lua and keep store.lua focused on mutation.

---
```

## PR View Keybindings

When you open a PR view with `:ReviewPR`, these keybindings are available:

### File Navigation & State

| Key | Action |
| --- | --- |
| `<CR>` | Toggle fold for current file (expand/collapse) |
| `]f` / `[f` | Next / previous file |
| `v` | Mark current file as viewed (collapses hunk context) |
| `V` | Mark current file as unviewed (expands hunk context) |
| `<leader>v` | Mark all files in the same directory as viewed |
| `<leader>R` | Remove all resolved comments (`fixed` + `wontfix`) with no confirmation |

### Hunk Navigation & Comments

| Key | Action |
| --- | --- |
| `]c` / `[c` | Next / previous hunk within file |
| `c` | Add a review comment at cursor line |
| `K` | Show full comment popup for comment at cursor |
| `go` | Open source file at cursor line in original editor |

### Quick File Actions

| Key | Action |
| --- | --- |
| `d` / `<leader>a` | Open file action menu at cursor |
| `Delete file` | Remove file immediately (no confirmation prompt) |
| `Rename file` | Rename file in-place |
| `Copy file path` | Copy relative file path to clipboard |
| `Open in editor` | Jump to the file in editor |
| `View file diff` | Open a scratch tab with `git diff` for that file |

### Context Collapse/Expand

| Key | Action |
| --- | --- |
| `zC` | Collapse hunk context (hide unchanged lines) at current hunk |
| `zO` | Expand hunk context (show unchanged lines) at current hunk |
| `zCA` | Collapse all hunks in current file (shows only changed lines) |
| `zOA` | Expand all hunks in current file (shows all context lines) |

### Focus & Review Modes

| Key | Action |
| --- | --- |
| `<leader>F` | Cycle rhythm mode: Overview → Focus → Sweep |
| `<Space>` / `<Tab>` | Advance to next file in rhythm queue (focus/sweep) |
| `<leader>T` | Start / cancel timed review session |

`rhythm_advance_key` defaults to `<Space>`, but auto-switches to `<Tab>` when `mapleader` is `<Space>` (for example LazyVim) so `<leader>f` remains reachable.

### File Jump & Other

| Key | Action |
| --- | --- |
| `<leader>f` | Open file jump picker (searchable file list) |
| `R` | Refresh diff view |
| `?` | Show this help text |
| `q` | Close PR view |

### How to Use Context Collapse

The `zC` / `zO` / `zCA` / `zOA` commands let you hide or show unchanged context lines in diffs:

- **`zC` at hunk**: Collapses the context lines around the current hunk (the cursor must be on a hunk header line)
- **`zO` at hunk**: Expands the context lines for the current hunk
- **`zCA` in file**: Collapses all hunk contexts in the current file at once (shows only changed/added/removed lines)
- **`zOA` in file**: Expands all hunk contexts in the current file (shows all lines including unchanged context)

These are particularly useful for reviewing large files with many hunks—use `zCA` to see just the changes, then `zOA` if you need to see context.

## Optional Integrations

- Picker backends: auto order is Telescope -> fzf-lua -> snacks -> `vim.ui.select`.
- Agent: `:ReviewFix` runs `agent.cmd` with an auto-generated prompt over open review items.
