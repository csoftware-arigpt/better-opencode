---
name: karpathy-craft
description: Andrej Karpathy principles for AI-coding discipline. Verbatim source in references/ (multica-ai/andrej-karpathy-skills). Load when planning agent work, reviewing approach, or thinking about coding process discipline.
---

# Karpathy discipline (verbatim source + station notes)

Verbatim sources live in `references/` next to this file (repo: multica-ai/andrej-karpathy-skills):
- `references/CLAUDE.md` - the full behavioral guidelines (read it when planning/reviewing)
- `references/SKILL.md` - the repo's own skill version
- `references/README.md` - repo context

## The four core behaviors (from CLAUDE.md)
1. **Think Before Coding** - state assumptions explicitly; multiple readings -> show them, never silently pick one; push back when a simpler approach exists; unclear -> stop and ask.
2. **Simplicity First** - minimum code that solves the task; no features, abstractions, or "flexibility" beyond the request; no error handling for impossible scenarios; 200 lines where 50 suffice -> rewrite.
3. **Surgical Changes** - touch only what the task obligates; never "improve" neighboring code, comments, or formatting; match the surrounding style; mention foreign dead code, never delete it; clean up only orphans your own edits created; every changed line traces to the request.
4. **Goal-Driven Execution** - tasks become verifiable goals ("fix bug" -> a reproducing test passes); multi-step: numbered plan where every step has "-> verify: [check]".

Trade-off note from the source: these bias toward caution over speed - for trivial tasks use judgment.

## Karpathy meta-principles (from the talk "From Vibe Coding to Agentic Engineering")
- LLMs automate what can be VERIFIED, not what cannot be specified: not measured -> not claimed.
- Jagged intelligence: genius in one pocket, nonsensical in the next; confident tone does not correlate with correctness - verify by default.
- Value moves up to judgment, taste, oversight: the agent returns precise diffs + proof; the human keeps review.
- The prompt is program text (Software 3.0): AGENTS.md, rules, skills = source code; editing them is programming.

## Station integration
- Points 2-3 enforced by `precise-work` (exact reading, minimal diff, terminal proof).
- Ambiguity -> asking the user beats silent 200-line improvisation.
- Prototypes may vibe; anything that survives the evening -> diff + check + proof.
