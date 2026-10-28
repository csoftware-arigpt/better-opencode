---
name: prompt-vault
description: Archive of REAL system prompts (Claude Code 2.0, Cursor Agent CLI) with distilled techniques. Load when writing or reviewing system prompts, AGENTS.md, agent rules, or comparing agent behaviors/skills.
---

# Prompt vault (real ones, not from memory)

Source: `github.com/x1xhlol/system-prompts-and-models-of-ai-tools` (GPL-3.0).
Full texts live in `references/` next to this SKILL.md - read them, do not invent techniques.

- `references/claude-code-2.0.txt` - the system prompt of Claude Code 2.0 (2025-09-29)
- `references/cursor-agent-cli-2025-08-07.txt` - the prompt of Cursor Agent CLI (GPT-5)

## Core techniques (distilled from the proofs above)

- **Nothing extra**: "Do what has been asked; nothing more, nothing less". Bans on file creation right in the prompt: no *.md/README without an explicit request, edit existing files instead of creating new ones.
- **Structure**: role -> environment -> communication -> tools -> example. Cursor CLI has sections `<communication>`, `<status_update_spec>`, `<flow>`, `<tool_calling>`, `<code_style>`: resolve conflicting rules per section.
- **Tone**: brief, facts and decisions; markdown only where it genuinely helps (Cursor CLI: "Avoid wrapping the entire message in a single code block").
- **Confidence over hedging**: no long apologies; result -> short explanation -> stop.
- **Skeleton aesthetics**: file paths/function names always in backticks - machines read formatted text.

## How to use
1. Writing your AGENTS.md/prompt -> open the relevant reference, copy the skeleton and formulations for your task.
2. A new agent feature (skill, TO-DO, subagents) -> look at how Claude Code 2.0 handles it - they have it battle-tested.
