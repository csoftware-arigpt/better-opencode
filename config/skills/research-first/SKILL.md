---
name: research-first
description: Search-first research protocol - every technical fact verified online before use. Load for research tasks, questions about versions/API/libraries/errors, install commands, or anything memory might have stale.
---

# Research: the internet is the primary source

## Order (strict)
1. Memory = a hypothesis tagged "verify". First move - websearch on the essence of the question. If the built-in websearch returns empty - use the station backend: `websearch "query"` + `page-extract <url>` (see skill `more-accurate-search-skill`).
2. From the results take official sources: project docs, GitHub, release notes. Full GitHub texts - via `curl raw.githubusercontent.com` to a file or `page-extract`.
3. A non-obvious fact - at least 2 sources; they disagree - tell the user.
4. Cite the source (URL) in the answer whenever the information is non-trivial.
5. Install commands and CLI flags - only after checking the docs; unfamiliar tool -> `--help`/`tldr`/man locally before running it on the user.

## What to ALWAYS search (never remember):
- Versions and compatibility - especially on Android/Termux aarch64.
- Error text - verbatim search, in quotes.
- Libraries/approaches - "how it is done now", not "how I remember 2024".

## Termux specifics
- Is there a package: `pkg search <name>`, not memory.
- npm: install scripts are restricted, native modules may not build - search "termux <package>" before pip/npm install with native code.
