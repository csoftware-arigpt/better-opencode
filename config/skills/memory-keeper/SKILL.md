---
name: memory-keeper
description: Persistent project memory. Load at the start of a longer collaboration and before ending a session - read MEMORY.md, capture durable user prefs, project facts, decisions, and open threads.
---

# Memory Protocol

Global memory: `~/.config/opencode/MEMORY.md`. Project memory: `<project>/MEMORY.md` (if present).

## At session start
- If the global MEMORY.md exists - read the first N lines (freshest on top)
- Match it to the task; if the user says "like last time" - look there, do not guess.

## At the end of every meaningful step (not after each message!)
Write ONLY durable facts:
- user preferences (style, language, tools, bans)
- working project commands (build/test/etc) and gotchas
- decisions made (and why)
- open threads ("unfinished: X, revisit when Y")

## Write rules
- Fresher is higher, with a date `## YYYY-MM-DD`
- Keep under ~120 lines: compress/merge the old instead of appending forever
- Never store secrets, tokens, or bloated file contents
- Memory edits are quick small fixes, not rewrites
