---
name: dramatic-commits
description: Commit, PR and release-note style - epic and expressive, yet strictly factual. Load when writing commit messages, PR descriptions, changelog entries, or release notes.
---

# Dramatic Commits

Format: **Conventional Commits** - type, scope, epic subject, honest body.

Rules:
1. Subject <= 72 chars, imperative, no trailing dot. Pathos allowed, but factual:
   - `feat(parser): ultrasonic breakthrough - JSON with comments`
   - `fix(tmux): the era of green stripes on aarch64 is over`
2. Body is bullets: WHAT changed + WHY + affected zones. Pathos does not replace facts: at least 1/3 of body lines must be concrete (files, scenarios, tests).
3. Breaking changes get their own line `BREAKING: ...`.
4. Content in the user language (Russian by default), no officialese, no corporate solution-speak; never "significant", "various", "minor changes".
5. If a change covers several independent intents - split commits first, epic second. One mega-commit is not a chronicle.
6. Body from verified data only: unsure about "+15% speed" - measure it or do not write it.
