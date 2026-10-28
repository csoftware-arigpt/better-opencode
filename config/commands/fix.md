---
description: Find the bug root cause and fix it minimally
agent: build
---
Debugging time. Arguments (something is broken): $ARGUMENTS

1. First pin down the **root cause**: narrow it to the exact lines and conditions that trigger it. Verify hypotheses with terminal commands, do not guess.
2. Fix with a minimal diff: touch nothing unrelated.
3. Provide before/after proof: a test, a script, or output showing was/became.
4. Final line: "what changed -> how verified".
