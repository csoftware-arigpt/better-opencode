---
description: Stage and commit with taste
agent: build
---
Commit the current changes.

1. Say what changed: !`git status --short`
2. Style of recent commits (do not repeat verbatim): !`git log --oneline -8`
3. `git add` - stage what is relevant. If the user passed $ARGUMENTS, stage only what they asked for.
4. Commit message: fact-dense, first word imperative; the body says "what" and "why", no filler.
5. Finish: show `git log -1 --stat`.

Touch nothing unrelated; do not push anywhere.
