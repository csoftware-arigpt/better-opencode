# better-opencode

A portable snapshot of a personal, production-open OpenCode v2 configuration: a subagent fleet, curated commands, 19 curated skills, guard plugins, a curl-based web search pipeline, and a **vendored Rust memory engine** that the installer mandatorily compiles with cargo and links to `~/.local/bin`. The install script auto-detects the OS/station hardware and adapts everything: pkexec vs sudo vs none, the distro package manager, Rust toolchain provisioning, build parallelism by cores+RAM, the CLI plugin only on GUI sessions, arm64 caveats, and PATH setup via the detected shell.

What is inside:

- **Subagent fleet** — 4 specialized subagents: `web-researcher`, `architect`, `critic`, `verifier`.
- **Curated commands** — `/research`, `/arch`, `/review`, `/commit`, `/fix`, `/intro`, `/note`, `/recall`.
- **19 curated skills** — writing, Python/Go/Rust/TS craft, Karpathy principles, nixos-env, memrag protocol, precise-work discipline, research-first web protocol, and more.
- **Guard plugins** — `session-notify` (GNOME notify-send), `garble-guard` (LLM-degeneration detector), `memory-rag` (glue to the Rust binary).
- **Web search pipeline** — curl-based `bin/websearch` -> Brave + DuckDuckGo, plus `page-extract` and `page_md.py`.
- **Memory engine** — `vendor/opencode-memory-rag` (Rust), compiled by the installer with `cargo build --release`.

## Bootstrap with OpenCode (one prompt installs everything)

Clone the repo somewhere safe, launch OpenCode in it, and paste this ONE prompt — the agent runs the same installer a human would, and this repo documents the discipline it needs:

```bash
git clone https://github.com/csoftware-arigpt/better-opencode.git
cd better-opencode && opencode
```

Then paste:

```text
Read docs/INSTALL.md in this repo. Then run:
1) bash install.sh --os-report-only   — print the FULL system study report (OS nuances + the utilities table) and show it to me.
2) bash install.sh --yes --with-rea   — auto-provision all dependencies, MANDATORILY compile the vendored Rust memory engine with cargo (on NixOS it auto-wraps in nix-shell -p gcc cargo; on other distros it uses the detected package manager with pkexec/sudo), install agents/commands/skills/plugins, and integrate Context7.
3) BEFORE the wshobson pack (third-party 8-plugin bundle, needs uv provisioning and a git clone) — STOP and ask me for permission; run `bash install.sh --with-wshobson` only after I explicitly approve.
Whenever pkexec/sudo password or the Context7 one-time device code appears — explain it and wait for me; do not work around prompts. Do not edit anything outside this repo and ~/.config/opencode. Finish with the VERIFY phase output and a short before->after summary.
```

Interactive moments (package-manager password, Context7 OAuth device code) surface in your terminal; everything else adapts to your hardware automatically. The wshobson pack is the single opt-in step you will be asked about.

## Layout

```
install.sh                          entry point (flags below)
uninstall.sh
lib/detect.sh                       phase 1: system study + OS-nuance and utilities report
lib/prereq.sh                       phase 2: dependencies (auto-provisioning)
lib/build.sh                        phase 3: mandatory memrag build (+ wshobson pack is generated here when --with-wshobson)
lib/config.sh                       phase 4: opencode setup (config, agents, skills, plugins, bin helpers)
lib/integrate.sh                    phase 5: integrations (Context7, optional REA)
lib/verify.sh                       phase 6: verification
config/agents/                      web-researcher.md, architect.md, critic.md, verifier.md
config/commands/                    arch, commit, fix, intro, note, recall, research, review (.md)
config/skills/                      19 skill directories
config/plugins/                     session-notify.ts, garble-guard.ts, memory-rag.ts
config/opencode.json.template       no secrets; mcp.servers empty by default (filled by integrations)
config/AGENTS.md                    optional global rules file (Context7-first rule inside)
bin/websearch                       curl search pipeline (Brave + DDG)
bin/page-extract, bin/page_md.py    page extraction helpers
vendor/opencode-memory-rag/         vendored Rust memory engine (compiled by the installer)
docs/INSTALL.md                     detailed installation guide
```

## Quick start

```bash
bash install.sh --os-report-only    # study the machine, change nothing
bash install.sh --dry-run           # preview every planned action
bash install.sh --yes               # install
```

### Install directly from inside OpenCode

Everything needed — the clone line, the launch line, and the ONE full-install prompt — is at the top of this README under **Bootstrap with OpenCode**. The prompt is agent-facing on purpose: it instructs the agent to show the system study first and the verification last, so every mutation stays visible.

## Flags

| Flag | Effect |
|---|---|
| `--os-report-only` | study the system and print the full hardware/OS report without changing anything — start here on ANY machine |
| `--dry-run` | show planned actions without changing anything |
| `--yes` | non-interactive install, assume yes |
| `--force` | overwrite already-installed files (default: existing files are skipped) |
| `--no-memrag` | skip the vendored Rust memory engine (no cargo build, no install abort on build failure) |
| `--with-rea` | also install the optional REA MCP stack |
| `--with-wshobson` | also install the optional wshobson pack (8 plugins, git-generated) |
| `--skip-context7` | skip the Context7 MCP integration |
| `--bin-dir=~/.local/bin` | target bin directory for helper binaries |
| `--config-dir=~/.config/opencode` | target OpenCode config directory |
| `--help` | print usage |

## What gets adapted to your hardware

The SYSTEM STUDY phase always runs first and drives every decision below.

- **OS nuances, studied and reported** — the report prints: distro id/version, desktop environment and display manager (when detected), display server (Wayland/X11/headless), polkit agent presence (pkexec usable or not), privileged escalation choice (pkexec on GUI, sudo otherwise, none on NixOS/Termux/headless), init/systemd presence, container/WSL markers (`.dockerenv`, WSL kernel, cgroups), PEP 668 `EXTERNALLY-MANAGED` pip marker, NixOS profile vs distro PATH, Termux `$PREFIX`.
- **Utilities: what is installed and what is missing** — a per-tool table with presence, version, and best-effort source channel: node, npx, npm, python3, curl, git, cargo, rustc, cc/gcc/clang, uv, make, jq, tmux, notify-send, shell (fish/bash/zsh), plus whether `~/.local/bin` is already on PATH. Everything missing is provisioned in the next phase; everything present is left alone.
- **Arch** — x86_64 vs aarch64; on aarch64 the `--with-rea` path prints an arm64 (rea-arm64) warning.
- **Cores + RAM** — cargo build parallelism `-j = min(cores, 8)`; `-j 2` forced when RAM < 2 GB. The rule is printed before the build.
- **Disk** — free-space checks before provisioning and building.
- **GUI vs headless** — `session-notify.ts` is installed only on GUI sessions (skipped on headless); `pkexec` is used only on GUI.
- **Wayland vs X11** — no behavioral difference except the pkexec path above.
- **Headless CI without polkit/sudo** — falls back to user-level installs (`nix profile` / brew / cargo) and warns.
- **Termux** — no root; `pkg` manager, `$PREFIX` respected, Node from pkg. The Rust build is a honeypot on Android and may fail; the memory engine is documented as optional (`--no-memrag`).
- **NixOS** — user-level `nix profile install nixpkgs#...` only, NO root commands; if gcc is absent, the memrag build is automatically wrapped in `nix-shell -p gcc cargo`.

## Security and privacy

- The package ships **zero secrets**: no API tokens, no keys. `config/opencode.json.template` has `mcp.servers` empty by default; entries are added only by the integrations you opt into.
- The Context7 key is obtained by **your own OAuth** during `ctx7 setup` (one-time device code entered in your terminal).
- Nothing phones home on its own: network is used only by the user-invoked `websearch` command and by the Context7/REA integrations you opt into.

## Uninstall

```bash
bash uninstall.sh [--yes]
```

Backups of a pre-existing config and the install manifest live in `~/.local/state/better-opencode/`. See `docs/INSTALL.md` for phases, the OS matrix, and troubleshooting.

## License

GPL-3.0 — see [LICENSE](LICENSE). Everything in this repo (installer scripts, vendored memory engine source, plugins) is distributed under the same single license.
