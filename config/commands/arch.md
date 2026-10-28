---
description: Multi-agent design: architect builds the plan, critic breaks it, final plan after the battle
agent: build
---
Topic: $ARGUMENTS

Run a three-role battle:

1. **architect** - send the architect subagent the task: build a plan on this topic. Pass all known context in the prompt (the subagent starts with a clean context!): goal, constraints, what was already tried.
2. **critic** - forward the architect's plan to the critic subagent unsanitized: weak points, edge cases, false assumptions.
3. **synthesis** - you, yourself: what from the architect was kept, what was dropped after criticism; disagreements with the critic - argue explicitly. Final plan: steps -> files -> per-step verification.

Output: only a compact result per role and the final plan.
External facts: architect and critic must supply URLs from the web; re-verify yourself - no fact goes into the answer without a URL.
