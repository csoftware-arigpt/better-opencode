---
name: memrag
description: Project long-term memory protocol - a graph-RAG (BM25 + node-edge graph) via the memory_* tools or the memrag CLI. Load ALWAYS when working on an existing project, making decisions, debugging, or refactoring: this protocol dictates when the agent must read memory (memory_query) and when it must write (memory_save). Skipping the protocol = losing context between sessions.
metadata:
  version: "1"
---

# Project memory protocol (memrag)

Project memory is persistent: node:sqlite + FTS5/BM25 + a graph of nodes (note/file/symbol/tag) with typed edges. It survives sessions. Tools: plugin tools `memory_query`, `memory_save`, `memory_index`, `memory_brain`, or the CLI `memrag` (index|query|note|brain|graph|link).

## Continuous access rule (almost every turn)

- **BEFORE a claim** about code/architecture/project status -> `memory_query` (term-based). The illusion of knowledge is the source of errors: ask memory first, then speak.
- **AFTER a meaningful step** (a decision, a found bug root, an experiment success/failure, a new environment/dependency fact, an adopted convention) -> `memory_save` (short: title + essence + files via full path + tags).
- **Starting work** on an unfamiliar/updated project -> `memory_index` (incremental, seconds) -> `memory_brain` (what is in the brains now).
- **Refactoring/renaming**: afterwards -> a `memory_save` note "architectural shift" so the graph does not go stale.

## What to save (yes)
- solved problems and their roots ("fix: ... because ..."),
- decisions and arguments (what was chosen and why),
- environment cheatsheets (how to build/run/run tests on this machine),
- traps ("rust build needs nix-shell -p gcc on this NixOS", "DB from proot..."),
- links to key files and project rules.

## What NOT to save (no)
- secrets/tokens/paths outside the project (never),
- reproducible code in full (chunks are already in the index) - store a link `file: path`,
- trivial rephrasing "did a small thing" (a grep + memory_query already covers that).
