---
name: more-accurate-search-skill
description: Deep-verification web research pipeline - search via curl backends, then OPEN the top pages and mine their full Markdown text. Load when the built-in websearch returns nothing, when a claim needs multi-source verification, or when snippets alone are too shallow.
---

# Deep search: search + open pages (more accurate search)

Snippets lie by omission; the full page is the evidence. This skill pairs two
curl-based station tools and never answers on the first hop alone.

## The pipeline (never skip step 3)
1. **Search**: `websearch "query" 10` (backend: Brave, falls back to DDG Lite). If it prints `(no results)`, rephrase the query or switch backend explicitly: `websearch "query" 10 ddg`.
2. **Select sources**: prefer official docs/README/release notes/changelog; blogs are corroboration only. Pick 3-5 candidates for a non-trivial question.
3. **Open the pages**: `page-extract <url> [maxchars] [start-marker]` - converts each page to Markdown. On heavy sites jump straight to content with a marker (`README`, `About`, or the article title).
4. **Mine**: grep the Markdown output for the claim (versions, flags, error text, dates). Cross-check: at least 2 independent sources for any non-obvious fact; do not pick silently when they disagree.
5. **Answer with proof**: every non-trivial thesis carries its URL; end with a source list and a confidence line.

## When to use instead of one-shot search
- The built-in `websearch` tool returned empty (its backend breaks silently) or `webfetch` refused a URL (bot-wall) - the curl pair bypasses both.
- Claim needs verification across versions/dates/snippet ambiguity.
- The topic is install commands, CLI flags, error text, or "is X still true in 2026".

## Iron rules
- A snippet is a pointer, not evidence: quote only what you saw in a fetched page's Markdown.
- One hop is never enough for a non-trivial claim.
- Date every source; a 2024 page may describe a dead world.
- Do not run both tools blindly in a loop: fetch the 3-5 selected pages, not all 10.
- Rate-limit friendly: if Brave returns empty twice in a row, wait and try `ddg`; never hammer the backend.

## Error strings
When searching for an error, search the exact quoted string, then open the first 2 issue/forum results and read them with `page-extract`.

## Quick examples
```sh
websearch "opencode subagent permissions docs" 8
page-extract "https://opencode.ai/v2/docs/agents" 15000
page-extract "https://github.com/foo/bar" 6000 README
```
