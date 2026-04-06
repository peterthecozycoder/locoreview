# locoreview

`locoreview` is a local-first Neovim plugin for capturing, listing, and resolving structured code review comments in a repo-local markdown file.

## Installation (lazy.nvim)

```lua
{
  "peterthecozycoder/locoreview",
  dependencies = {
    "nvim-lua/plenary.nvim",
    { "sindrets/diffview.nvim", optional = true },
  },
  opts = {
    review_file = "review.md",
    default_severity = "medium",
    diffview = { enabled = true },
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

| Command | Description |
| --- | --- |
| `:ReviewOpen` | Open review file, create if missing |
| `:ReviewAdd` | Add item for current line |
| `:ReviewAddRange` | Add item for visual range |
| `:ReviewList` | Quickfix list of open items |
| `:ReviewNext` | Jump to next open item |
| `:ReviewPrev` | Jump to previous open item |
| `:ReviewMarkFixed` | Transition open item to fixed |
| `:ReviewClean` | Remove all fixed items from the review file |
| `:ReviewReopen` | Transition non-open item to open |
| `:ReviewDiff` | Open diffview against base branch |
| `:ReviewFileHistory` | Open diffview file history |
| `:ReviewFix` | Run external agent command |
| `:ReviewEdit` | Edit issue/requested_change/severity |
| `:ReviewDelete` | Delete item at current location |
| `:ReviewMarkBlocked` | Transition open item to blocked |
| `:ReviewMarkWontfix` | Transition open item to wontfix |
| `:ReviewListAll` | Quickfix list with optional filters |
| `:ReviewRefresh` | Reload signs and quickfix from disk |
| `:ReviewPicker` | Open picker for items |
| `:ReviewToggleSigns` | Toggle signs for session |
| `:ReviewAddDiff` | Add only on changed diff lines |

## Configuration

| Option | Type | Default |
| --- | --- | --- |
| `review_file` | `string` | `"review.md"` |
| `base_branch` | `string\|nil` | `nil` |
| `keymaps` | `boolean\|table` | `true` |
| `default_severity` | `"low"\|"medium"\|"high"` | `"medium"` |
| `default_author` | `string\|nil` | `nil` |
| `diffview.enabled` | `boolean` | `true` |
| `signs.enabled` | `boolean` | `true` |
| `signs.priority` | `number` | `20` |
| `picker.enabled` | `boolean` | `true` |
| `picker.backend` | `"auto"\|"telescope"\|"fzf_lua"\|"snacks"\|"none"` | `"auto"` |
| `diff_only` | `boolean` | `false` |
| `agent.enabled` | `boolean` | `false` |
| `agent.cmd` | `string\|function` | `"agent"` |
| `agent.open_in_split` | `boolean` | `true` |

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

## Optional Integrations

- Diffview: `:ReviewDiff` and `:ReviewFileHistory` when `diffview.enabled = true` and plugin is installed.
- Picker backends: auto order is Telescope -> fzf-lua -> snacks -> `vim.ui.select`.
- Agent: `:ReviewFix` runs `agent.cmd` with an auto-generated prompt over open review items.
