#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# better-opencode :: uninstall.sh
#
# Removes everything recorded in the better-opencode manifest
# (~/.local/state/better-opencode/manifest.txt). Backups and the manifest
# itself are left untouched (evidence trail).
#
# Usage:
#   ./uninstall.sh [--yes] [--dry-run] [--manifest FILE]
#
# Behavior:
#   * reads the manifest, deletes each listed path (deepest first):
#     files, directories, symlinks - each with a [y/N] prompt unless --yes
#   * never deletes outside $HOME, and never deletes $HOME itself
#   * afterwards tries to remove now-empty well-known parents
#     ($CONFIG_DIR/agents etc.) without touching non-empty ones
#   * prints what was NOT removed because it is not in the manifest
#     (manually installed npm -g deps, nix profile updates, rustup, etc.)
# ---------------------------------------------------------------------------
set -euo pipefail

STATE_DIR="${HOME}/.local/state/better-opencode"
MANIFEST_DEFAULT="${STATE_DIR}/manifest.txt"
MANIFEST="${MANIFEST_DEFAULT}"
FLAG_YES=0
FLAG_DRY=0

# --- shared minimal logging (intentionally local copies; standalone script) -
u_log()  { printf '[better-opencode] %s\n' "$*"; }
u_warn() { printf '[better-opencode][warn]  %s\n' "$*"; }
u_die()  { printf '[better-opencode][error] %s\n' "$*" >&2; exit 1; }
u_act()  { [ "$FLAG_DRY" = 1 ] && printf '[dry-run] %s\n' "$*" || printf '[better-opencode] %s\n' "$*"; return 0; }

u_usage() {
    cat <<'USG'
better-opencode uninstaller

Usage: ./uninstall.sh [flags]
  --yes             delete every manifest path without prompting
  --dry-run         print what would be deleted; remove nothing
  --manifest FILE   read this manifest instead of the default
USG
}

_args=("$@")
_i=0
while [ "$_i" -lt "${#_args[@]}" ]; do
    case "${_args[$_i]}" in
        --help|-h)        u_usage; exit 0 ;;
        --yes|-y)         FLAG_YES=1 ;;
        --dry-run)        FLAG_DRY=1 ;;
        --manifest)       _i=$((_i+1)); [ "$_i" -lt "${#_args[@]}" ] || u_die "--manifest requires a value"; MANIFEST="${_args[$_i]}" ;;
        --manifest=*)     MANIFEST="${_args[$_i]#--manifest=}" ;;
        *)                u_warn "unknown flag: ${_args[$_i]}"; u_usage; exit 1 ;;
    esac
    _i=$((_i+1))
done

# Expand ~ for manual values.
MANIFEST="${MANIFEST/#\~/$HOME}"

# same safety check, but returns a status (skip) instead of dying the process
u_die_if_unsafe_noret() {
    local p="$1"
    case "$p" in
        "$HOME"|/|/root|"") u_warn "refusing unsafe path (skipped): $p"; return 1 ;;
    esac
    case "$p" in
        "$HOME"/*) return 0 ;;
        *) u_warn "path outside \$HOME not touched by the installer (skipped): $p"; return 1 ;;
    esac
}

u_prompt_delete() {
    if [ "$FLAG_YES" = 1 ]; then return 0; fi
    local ans=""
    printf 'delete %s ? [y/N] ' "$1" >&2
    if [ ! -t 0 ]; then
        printf '\n  (not a tty: skipped; re-run with --yes to delete non-interactively)\n'
        return 1
    fi
    read -r ans || return 1
    case "$ans" in [Yy]|[Yy][Ee][Ss]) return 0 ;; *) return 1 ;; esac
}

u_remove_path() {
    local p="$1"
    [ -e "$p" ] || [ -L "$p" ] || { u_act "not present (already gone): $p"; return 0; }
    if [ "$FLAG_DRY" = 1 ]; then
        u_act "would remove: $p"
        return 0
    fi
    if u_prompt_delete "$p"; then
        u_act "removing: $p"
        if [ -L "$p" ]; then
            rm -f -- "$p"
        else
            rm -rf -- "$p"
        fi
        return 0
    fi
    u_act "kept: $p"
    return 1
}

main() {
    u_log "uninstaller for better-opencode"
    if [ "$FLAG_DRY" = 1 ]; then
        u_log "dry-run: nothing will be deleted"
    fi
    if [ ! -f "$MANIFEST" ]; then
        u_die "manifest not found: $MANIFEST (nothing removed; install.sh may never have run, or the manifest was moved)"
    fi
    u_log "manifest: $MANIFEST"

    # Show which runs recorded entries.
    grep '^# ' "$MANIFEST" 2>/dev/null | head -n 20 || true

    # Collect paths: non-header lines, absolute, deduped, deepest-first.
    local all_paths list_file tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/bo-uninstall.XXXXXX")"
    list_file="$tmp/paths"
    grep -v '^#' "$MANIFEST" 2>/dev/null | grep -v '^[[:space:]]*$' \
        | sort -u > "$list_file" || true
    # deepest first, so children are removed before their parents
    awk '{print length($0)"\t"$0}' "$list_file" | sort -rn | cut -f2- > "$list_file.rev"

    local removed=0 kept=0 total=0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in /*) ;; *) u_warn "skipping non-absolute manifest entry: $p"; continue ;; esac
        total=$((total+1))
        if u_die_if_unsafe_noret "$p"; then
            if u_remove_path "$p"; then removed=$((removed+1)); else kept=$((kept+1)); fi
        fi
    done < "$list_file.rev"

    # well-known now-empty parents: remove without prompt (only if empty)
    local dir
    for dir in \
        "${HOME}/.config/opencode/agents" \
        "${HOME}/.config/opencode/commands" \
        "${HOME}/.config/opencode/skills" \
        "${HOME}/.config/opencode/plugins" \
        "${HOME}/.config/opencode" \
        "${HOME}/.local/bin"
    do
        [ -d "$dir" ] || continue
        if u_rmdir_if_empty_forest "$dir"; then
            u_act "removed empty dir: $dir"
        fi
    done

    u_log "manifest paths: $total (removed: $removed, kept: $kept)"
    u_leftover_report
    u_log "backups remain untouched in $STATE_DIR (delete manually when fully satisfied)"
    rm -rf "$tmp"
    return 0
}

# same safety check as u_die_if_unsafe, but returns a status instead of dying
u_die_if_unsafe_noret() {
    u_die_if_unsafe "$1" 2>/dev/null || return 1
    return 0
}

# rm dir only when empty, shallow first
u_rmdir_if_empty_forest() {
    local d="$1"
    [ "$FLAG_DRY" = 1 ] && { u_act "would rmdir (if empty): $d"; return 0; }
    rmdir "$d" 2>/dev/null || return 1
    return 0
}

u_leftover_report() {
    u_log "NOT removed (not tracked by the manifest; check manually if wanted):"
    if command -v npm >/dev/null 2>&1; then
        u_act "npm -g global packages possibly installed by --with-rea: npm ls -g rea-agents"
    else
        u_act "npm -g global packages possibly installed by --with-rea (rea-agents)"
    fi
    u_act "nix profile packages added during PREREQUISITES (nix profile list)"
    u_act "rustup toolchains in ~/.cargo and ~/.rustup (when the rustup fallback ran)"
    u_act "context7 OAuth device-code session remnants (nothing is stored locally by install.sh)"
    u_act "your opencode.json edits and AGENTS.md local changes (deleted from manifest only if reinstall removed them)"
}

main
