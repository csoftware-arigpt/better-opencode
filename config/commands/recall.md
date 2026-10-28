---
description: Search project memory (graph RAG) - injects results into context
agent: plan
---
Search results from the project long-term memory (memrag: BM25 + graph). Query: $ARGUMENTS

!`memrag query "$ARGUMENTS" -k 8 2>/dev/null || echo "memrag unavailable or memory is empty - run /mem-index"`

Use the records above as the project primary memory: notes (decisions/facts/cheatsheets) and code chunks. No records does not mean no knowledge - then verify with fresh file reads.
