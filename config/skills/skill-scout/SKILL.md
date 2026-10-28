---
name: skill-scout
description: Find and vet agent skills/plugins from the internet. Load whenever the user asks to find, search for, discover, or install new skills or OpenCode plugins, or asks whether a skill/plugin is safe.
---

# Skill Scout: search + safety

## Where to look (in trust order)
1. **skills.sh** - the cross-ecosystem skills catalog (Vercel).
2. **awesome-opencode** (GitHub) - a curated list of plugins/skills.
3. Trusted authors: `obra/superpowers`, `mattpocock/skills`, `hardikpandya/stop-slop`, `JuliusBrussee/caveman`.
4. npm: queries like `opencode plugin/skill`, `agent skills`. Check `npm view <pkg>`: version, publish date, author.
5. Catalogs of other harnesses (Claude/Codex) - the formats are compatible (SKILL.md, open standard).

## Screening a candidate
- The description matches the task (otherwise - context litter).
- Activity: commits within the last ~6 months, live issues.
- SKILL.md size: small is good; open it with your own eyes (webfetch/git show) BEFORE install.
- For npm plugins: platforms - optionalDeps with native binaries may fail to install (example: opencode-agent-memory on arm64).

## Virus check (mandatory before install!)
A skill = code that MY hands will execute. Procedure:
1. **Quarantine:** `git clone --depth 1 <url> /tmp/opencode/quarantine/<id>` (NOT into skills).
2. **Read EVERYTHING:** SKILL.md + every file in scripts/, references/, hooks/. Red flags:
   - `curl | bash`, `bash <(...)`, downloading binaries, random domains
   - outbound network: curl -d/--data @-, POST to foreign URLs, base64 blobs, "telemetry"
   - access to secrets: ~/.ssh/**, *.env, keys, `gh`, `docker` config, git-push anywhere
   - obfuscation: eval, exec, encrypted strings, meaningless names
   - self-modifying: editing its own files outside its own folder
3. **Origin check:** compare against upstream (if a fork) - `diff -r`, look at recent non-author commits. Constellation names (superpowerf, skills-official) - a fake.
4. **Verdict with the user:** safe -> install; doubtful -> show what was found, let the user decide; dangerous -> explain what was found and do NOT install.

## Install (after the green light)
- Skills: `cp -r quarantine/<id> ~/.config/opencode/skills/<id>` (or git clone straight away).
- npm plugins: `opencode plugin add <pkg>` (installs globally).
- Post-install: verify the skill appeared (system update/description) and run a MINI task, reading every call it triggers.

## Red lines (never)
- Never run scripts/ from foreign skills with secrets/tokens in the environment.
- Never let a foreign skill rewrite AGENTS.md, permissions, or plugin config without our choice.
