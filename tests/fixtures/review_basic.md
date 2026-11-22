# Review Comments

## RV-0001
file: lua/review/store.lua
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

## RV-0002
file: lua/review/ui.lua
line: 18
end_line: 24
severity: low
status: fixed
author:
created_at: 2026-03-28T15:40:00Z
updated_at: 2026-03-28T16:10:00Z

issue:
The prompt text is too vague.

requested_change:
Ask for severity explicitly.

---
