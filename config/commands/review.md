---
description: Review recent changes (no code edits)
agent: plan
---
Give a compact review of the project current changes. State:
!`git status --short`
Volume by file:
!`git diff --stat HEAD`

Walk through the full `git diff HEAD` and find:
- bugs and edge cases,
- security issues (injections, secrets, dangerous paths),
- readability and style.

Do NOT touch the code. Finish: table "issue -> file:line -> priority (1-3)", at most 10 rows.
