# better-opencode — Installation guide

What `install.sh` does on your machine, what it adapts to your hardware, and how to troubleshoot. See the [README](../README.md) intro for the component overview.

## Requirements

The installer provisions these itself in the PREREQUISITES phase:

- Mandatory: Node.js >= 20, Python 3, curl, git, Rust toolchain (rust + cargo + cc)
- Optional: uv, tmux, notify-send (`libnotify`)

Provisioning runs through a supported package manager: distro package manager (apt/dnf/pacman/zypper), `nix profile`, brew, or pkg (Termux). Elevation is automatic where possible (`pkexec` on GUI stations, `sudo` otherwise, nothing at all on NixOS Termux paths where irrelevant). On headless CI without polkit and sudo, the installer falls back to user-level installs (`nix profile` / brew / cargo) and prints a warning.

## File layout

Everything the installer touches, as shipped in this repo:

```
install.sh                          entry point (flags above)
uninstall.sh
lib/detect.sh                       phase 1: system study + OS-nuance and utilities report
lib/prereq.sh                       phase 2: auto-adaptation + dependencies
lib/build.sh                        phase 3: mandatory memrag build (+ wshobson pack generation when --with-wshobson)
lib/config.sh                       phase 4: opencode setup
lib/integrate.sh                    phase 5: integrations (Context7, optional REA)
lib/verify.sh                       phase 6: verification
config/agents/                      web-researcher.md, architect.md, critic.md, verifier.md
config/commands/                    arch, commit, fix, intro, note, recall, research, review (.md)
config/skills/                      19 skill directories
config/plugins/                     session-notify.ts, garble-guard.ts, memory-rag.ts
config/opencode.json.template       no secrets; mcp.servers empty by default (filled by integrations)
config/AGENTS.md                    optional global rules file (Context7-first rule inside)
bin/websearch                       curl search pipeline (Brave + DDG)
bin/page-extract, bin/page_md.py    page extraction helpers (stdlib-only python)
vendor/opencode-memory-rag/         vendored Rust memory engine source (compiled in phase 3)
```

## Quick start

```bash
bash install.sh --os-report-only    # study the machine, print the report, change nothing
bash install.sh --dry-run           # preview every planned action
bash install.sh --yes               # install
bash install.sh --yes --no-memrag   # install without the Rust memory engine
```

`--os-report-only` studies the system and prints the full hardware/OS report without changing anything — start here on ANY machine.

### Install directly from inside OpenCode

Already running OpenCode anywhere (a workstation, a laptop, a VPS)? Launch it in the repo folder:

```bash
cd ~/projects/better-opencode && opencode
```

and paste the ONE full-install prompt from the top of the [README](../README.md) — it points the agent at the system study first, then at `bash install.sh --yes --with-rea`, and makes it ASK YOUR PERMISSION before running `bash install.sh --with-wshobson` (the third-party 8-plugin pack is the only opt-in step). It finishes with the VERIFY output.

The agent runs the same phases, follows GUI semantics (pkexec dialog on graphical stations, sudo prompts in the terminal), and handles the Context7 one-time-code step interactively. Machine study, dependency provisioning, and the mandatory build are not your problem — the installer adapts by itself.

## Flags

| Flag | Effect |
|---|---|
| `--os-report-only` | study the system and print the full hardware/OS report without changing anything — start here on ANY machine |
| `--dry-run` | show planned actions without changing anything |
| `--yes` | non-interactive install, assume yes |
| `--force` | overwrite already-installed files; without it, existing files are skipped during merge-copy |
| `--no-memrag` | skip the vendored Rust memory engine build and install |
| `--with-rea` | also install the optional REA MCP stack (arm64 warning applies) |
| `--with-wshobson` | also install the optional wshobson pack (8 plugins, git-generated) |
| `--skip-context7` | skip the Context7 MCP integration |
| `--bin-dir=~/.local/bin` | target bin directory for helper binaries (default `~/.local/bin`) |
| `--config-dir=~/.config/opencode` | target OpenCode config directory (default `~/.config/opencode`) |
| `--help` | print usage |

## Install phases

Dependencies first, OpenCode setup later. Phases run in this order:

1. **SYSTEM STUDY (auto-adaptation)** — always printed. Two-part report:
   - **OS nuances** — distro id/version; desktop environment and display manager (best effort); Wayland/X11/headless; polkit agent presence; the privilege decision itself (`pkexec` on GUI → `sudo` → user-level only on NixOS/Termux/headless); init/systemd presence; container/WSL markers (`.dockerenv`, WSL kernel, cgroup hints); PEP 668 `EXTERNALLY-MANAGED` pip marker; NixOS profile detection; Termux `$PREFIX`.
   - **Utilities study** — a per-tool table: installed?, version, best-effort source channel: `node`, `npx`, `npm`, `python3`, `curl`, `git`, `cargo`, `rustc`, `cc`/`gcc`/`clang`, `uv`, `make`, `jq`, `tmux`, `notify-send`, `fish`/`bash`/`zsh`, and whether `~/.local/bin` is already on PATH.
2. **DEPENDENCIES** — provisions exactly what the study found missing: node >= 20, python3, curl, git, rust + cargo + cc, and optionally uv, tmux, notify-send. Present tools are left alone.
3. **memrag build (MANDATORY)** — compiles the vendored engine `vendor/opencode-memory-rag` with `cargo build --release`. Parallelism is RAM-aware: `-j = min(cores, 8)`, `-j 2` when RAM < 2 GB; the rule is printed. On NixOS, when no C compiler is on PATH, the build is automatically wrapped in `nix-shell -p gcc cargo`. A build failure aborts the install unless `--no-memrag`.
4. **OPENCODE SETUP** — only after dependencies and the build succeed:
   - backs up any pre-existing config as a tar into `~/.local/state/better-opencode/backup-<timestamp>.tgz`
   - writes `opencode.json` from `config/opencode.json.template` only if the file is absent
   - merge-copies `agents/`, `commands/`, `skills/`, `plugins/` into the config dir, skipping existing files unless `--force`
   - installs binary helpers into `--bin-dir` (default `~/.local/bin`) with `chmod 755`
   - installs `session-notify.ts` only on GUI sessions; skipped on headless
   - with `--with-wshobson`: clones/generates the 8-plugin wshobson pack and links it here as well
5. **INTEGRATIONS** —
   - Context7 MCP: runs `npx ctx7 setup --opencode --mcp`; a one-time OAuth device code appears in your terminal — open the printed URL and approve it. Afterwards a normalizer runs: if the config ends up in the v1 shape (`mcp.context7`), it is moved to `mcp.servers.context7`.
   - REA stack: only with `--with-rea`.
6. **VERIFY** — JSON parse check of the config, markdown file counts (agents/commands/skills), sha256 and runnability of installed binaries, a memrag smoke run against a temp `MEMRAG_DIR`, and a PATH check that prints a copy-paste line for your detected shell:

```bash
# POSIX shells (bash/zsh):
export PATH="$HOME/.local/bin:$PATH"
# fish:
fish_add_path ~/.local/bin
```

## What gets adapted to your hardware

- **Arch (x86_64 / aarch64)** — detected in SYSTEM STUDY; on aarch64, `--with-rea` prints an arm64 (rea-arm64) warning before install.
- **Cores + RAM** — the memrag cargo build uses `-j = min(cores, 8)`; when RAM < 2 GB it is forced to `-j 2`. The exact rule is printed before the build starts.
- **Disk free** — free space is checked before provisioning and before the cargo build.
- **GUI vs headless** — `session-notify.ts` is installed only on GUI sessions and skipped on headless; `pkexec` is used only on GUI (elsewhere: sudo or user-level tooling).
- **Wayland vs X11** — no behavioral change other than the pkexec path above.
- **Headless CI without polkit/sudo** — falls back to user-level installs (`nix profile` / brew / cargo) and warns that system packages could not be provisioned.
- **Termux special** — no root; `pkg` as the package manager; `$PREFIX` paths are respected; node comes from pkg. The Rust build is a honeypot on Android and may fail — the memory engine is documented as optional (`--no-memrag`).
- **NixOS special** — user-level `nix profile install nixpkgs#...` only; NO root commands are ever run; gcc is typically absent, so the cargo build is automatically wrapped in `nix-shell -p gcc cargo`.

## OS matrix

You can copy-paste the commands below to provision prerequisites yourself; otherwise the installer runs the equivalents automatically when tools are missing.

| OS | Provision command | Installer behavior |
|---|---|---|
| Ubuntu/Debian | `sudo apt update && sudo apt install nodejs npm python3 curl git build-essential cargo rustc libnotify-bin` | Installs everything missing via apt automatically; this route always needs elevation (pkexec/sudo). |
| Fedora | `sudo dnf install nodejs npm python3 curl git make gcc cargo rust libnotify` | Same via dnf (apt equivalents); needs elevation. |
| Arch | `sudo pacman -S --needed base-devel python nodejs npm cargo rust` | Same via pacman; `base-devel` provides cc; needs elevation. |
| openSUSE | `sudo zypper in nodejs python3 curl git make gcc cargo rust libnotify-tools` | Same via zypper; package names may vary slightly by release; needs elevation. |
| NixOS | `nix profile install nixpkgs#{nodejs,cargo,rustc,gcc}` | User-level only; NO pkexec/sudo needed or used; gcc is pulled for the memrag build (nix-shell wrap when missing). |
| macOS | `brew install node python git rust` | GUI assumption; pkexec N/A; sudo applies where elevation is needed; installer provisions node/python/git/rust via brew automatically. |
| Termux | `pkg install nodejs python rust binutils` | Best-effort: no root; `pkg` manager; `$PREFIX` respected; node from pkg; the Rust memory build may fail on Android, so the engine is optional (`--no-memrag`). |

## Troubleshooting

### `cargo build` fails on NixOS with no `cc`
The installer handles this automatically by wrapping the build in `nix-shell -p gcc cargo`. Verified on a real NixOS station: plain `cargo build --release` without `cc` fails with exit 101 (`could not compile zerocopy (build script)` — the linker is the missing piece), while the `nix-shell` wrap finishes cleanly in about 2 minutes on an 8-core CPU. To build manually:

```bash
cd vendor/opencode-memory-rag/rust
nix-shell -p gcc cargo --run "cargo build --release"
```

### PEP 668 (`externally-managed-environment`)
`pip` is refused globally on such systems. `bin/page_md.py` needs **no pip** — it is stdlib-only, and the installer does not touch pip. If you want pip tools later, use a venv:

```bash
python3 -m venv .venv
```

### Context7 shows a one-time code
Expected. `npx ctx7 setup --opencode --mcp` performs device-code OAuth: open the printed URL and approve the code. No API key ships with this package.

### node < 20
The Context7 integration is skipped. Upgrade Node (see the OS matrix above) and run the installer again.

### Re-run safety
Re-running `bash install.sh` skips already-installed files. Use `--force` to overwrite them; when `opencode.json` already exists, it is kept (only a fresh install writes the template).

### Where are my backups and manifest?
In `~/.local/state/better-opencode/`: `backup-<timestamp>.tgz` snapshots of any pre-existing config, plus the install manifest. The backup is a plain tar; inspect it before restoring:

```bash
tar -tf ~/.local/state/better-opencode/backup-*.tgz
```

### Uninstall

```bash
bash uninstall.sh [--yes]
```

`--yes` makes it non-interactive. Backups in `~/.local/state/better-opencode/` are left in place.
