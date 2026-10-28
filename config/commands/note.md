---
description: Save a fact/decision to the project long-term memory
agent: plan
---
A note for the project long-term memory (memrag). Content to save: $ARGUMENTS

!`memrag note "$ARGUMENTS" 2>/dev/null || echo "could not save via CLI"`

The note is saved and linked into the graph (mentioned file paths/symbols/tags get linked). If the arguments carried tags like "--tags tag1,tag2" and the CLI skipped them, add the tags via `memrag link` or re-save the note with the tags inside the body.
