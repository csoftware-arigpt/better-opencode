---
name: nixos-env
description: Facts and pitfalls of this NixOS 25.11 personal station - nix profile, nix-shell, fish/tmux, toolchain availability, PEP 668. Load when shell commands fail oddly, paths look wrong, or native builds and long-running jobs are planned.
---

# NixOS station facts (desktop, GNOME Wayland)

## Shell and terminal
- Shell: **fish** (configs in `~/.config/fish`). POSIX `&&` works in fish 3.4+; `command -v` works; `source`-style activation scripts do not - use `direnv`/`nix develop` or export manually.
- Editor: nano (`$EDITOR`). Long tasks: tmux (`~/.config/tmux`), launcher and heavy terminal: Ptyxis (Wayland).
- Desktop notifications: `notify-send`. XDG temp zone: `/tmp/opencode`.

## Package management
- User-level tools: `nix profile install nixpkgs#<name>` (e.g. `nixpkgs#uv`, `nixpkgs#go`). List: `nix profile list`; remove: `nix profile remove <idx>`.
- Native binaries from the Nix store need nothing special; but **gcc/gnumake/pkg-config are NOT on PATH** by default.
- System-level packages (NixOS rebuild, configuration.nix) - DO NOT touch without an explicit user request.

## Toolchains actually present (verify, never assume)
- Present user-level: `python3`, `node` (v26 LTS, native TS via strip-types), `cargo`/`rustc`, `uv`, `fish`, `git`, `tmux`, `curl`.
- ABSENT until installed: `go`, `gcc`, `gnumake`, `pkg-config`.

## Native builds (C extensions, crates with C deps, node-gyp)
- Python C extensions without wheels: run pip inside `nix-shell -p gcc python3` (global pip is PEP 668-blocked anyway - prefer `python3 -m venv .venv`).
- Rust crates failing on linking / `cc`: `nix-shell -p gcc` (verified: the memrag rust binary needs this); SSL sniffing: `nix-shell -p gcc pkg-config openssl`.
- node-gyp packages without prebuilt binaries: `nix-shell -p gcc gnumake python3`.

## Python specifics
- Global pip installs refused (PEP 668): the venv is the only way; nixpkgs packages via `nix profile install nixpkgs#python3Packages.<name>` when a venv refuses.

## Long-running / background
- Watchers, dev servers, builds with output you revisit: run in tmux sessions, not detached agent background.
- Home dir is the workspace root; new projects go to `~/projects/<name>/`.

## Paths and git
- No system git hooks pollution to worry about; per-repo git configs are fine.
- Secrets never in project files: keys/oauthtokens live in the user's own store; `~/.config/opencode/service.json` must never be logged.
