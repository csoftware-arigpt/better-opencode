#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# better-opencode :: lib/config.sh  (phase 5: CONFIG INSTALL)
#
# Lays down the OpenCode config: template -> opencode.json, global AGENTS.md,
# agents/commands/skills/plugins trees, and the curl search helpers in bin/.
#
# Rules:
#   * opencode.json: only written when absent (or with --force); the user's
#     existing file is never silently replaced.
#   * AGENTS.md: same policy.
#   * agents/commands/skills/plugins: absent -> install; existing + --force ->
#     overwrite; existing without --force -> SKIP (idempotent re-runs).
#   * skills are directories installed with symlinks dereferenced.
#   * every created/overwritten path is recorded (absolute) in the manifest.
#   * one pre-install backup tar of the config dir (kept across re-runs).
#   * hardware hook: session-notify plugin only on GUI sessions
#     (headless / x11-without-polkit => "no graphical desktop notifications target").
# ---------------------------------------------------------------------------
set -euo pipefail

config::existing_backup() {
    compgen -G "$STATE_DIR/backup-*.tgz" >/dev/null 2>&1
}

# One-time backup of a pre-existing config dir (leaves node_modules out).
config::backup() {
    if [ ! -d "$CONFIG_DIR" ]; then
        bo_action "config dir does not exist yet: no backup needed"
        return 0
    fi
    if config::existing_backup; then
        bo_action "a backup already exists in $STATE_DIR: skipping (kept across re-runs)"
        return 0
    fi
    local stamp ts
    ts="$(date +%Y%m%dT%H%M%S)"
    stamp="$STATE_DIR/backup-${ts}.tgz"
    if [ "$BO_DRY" = 1 ]; then
        bo_action "would tar -czf $stamp (config dir backup, excluding node_modules)"
        return 0
    fi
    mkdir -p "$STATE_DIR"
    # --exclude before -C: GNU and BSD tar both accept this argument order
    if tar --exclude node_modules -czf "$stamp" -C "$(dirname "$CONFIG_DIR")" "$(basename "$CONFIG_DIR")"; then
        bo_action "backup created: $stamp"
    else
        bo_warn "backup tar failed (continuing without a backup snapshot)"
    fi
    return 0
}

# Copy $1 -> $2 with idempotent behavior and manifest bookkeeping.
config::_put_file() {
    local src="$1" dst="$2"
    if [ ! -e "$src" ]; then
        bo_warn "vendored source missing: $src (skipping)"
        return 1
    fi
    if [ -e "$dst" ]; then
        if [ "${FLAG_FORCE:-0}" = 1 ]; then
            bo_action "overwriting (force): $dst"
        else
            bo_action "exists, skipping (--force to overwrite): $dst"
            return 0
        fi
    fi
    if bo_run cp -f "$src" "$dst"; then
        bo_record "$dst"
        return 0
    fi
    bo_warn "copy failed: $src -> $dst"
    return 1
}

# Copy a directory tree with symlink dereferencing (used for skills).
config::_put_dir() {
    local src="$1" dst="$2"
    if [ ! -d "$src" ]; then
        bo_warn "vendored source dir missing: $src (skipping)"
        return 1
    fi
    if [ -d "$dst" ]; then
        if [ "${FLAG_FORCE:-0}" = 1 ]; then
            bo_action "overwriting (force): $dst"
            if [ "$BO_DRY" != 1 ]; then rm -rf "$dst"; fi
        else
            bo_action "exists, skipping (--force to overwrite): $dst"
            return 0
        fi
    fi
    local destdir
    destdir="$(dirname "$dst")"
    if bo_run cp -R -L "$src" "$destdir/"; then
        if [ "$BO_DRY" != 1 ]; then
            chmod 755 "$dst" 2>/dev/null || true
            find "$dst" -type f -exec chmod 644 {} + 2>/dev/null || true
        fi
        bo_record "$dst"
        return 0
    fi
    bo_warn "copy failed: $src -> $dst"
    return 1
}

config::install() {
    bo_action "config dir: $CONFIG_DIR"
    bo_action "bin dir: $BIN_DIR"

    config::backup

    # ---- directories -------------------------------------------------------
    bo_mkdir "$CONFIG_DIR" "$CONFIG_DIR/agents" "$CONFIG_DIR/commands" "$CONFIG_DIR/skills" "$CONFIG_DIR/plugins"
    bo_mkdir "$BIN_DIR"

    # ---- opencode.json from template (never silently replace a live file) --
    if [ -e "$CONFIG_DIR/opencode.json" ]; then
        if [ "${FLAG_FORCE:-0}" = 1 ]; then
            bo_action "overwriting (force): $CONFIG_DIR/opencode.json from template"
            config::_put_file "$BO_ROOT/config/opencode.json.template" "$CONFIG_DIR/opencode.json"
        else
            bo_action "exists, NOT copying template over $CONFIG_DIR/opencode.json (--force to overwrite; a backup was ensured)"
        fi
    else
        config::_put_file "$BO_ROOT/config/opencode.json.template" "$CONFIG_DIR/opencode.json" \
            || bo_warn "opencode.json could not be installed"
    fi

    # ---- global AGENTS.md (optional rules with the Context7 rule) ----------
    config::_put_file "$BO_ROOT/config/AGENTS.md" "$CONFIG_DIR/AGENTS.md" || true

    # ---- agents (4 files) --------------------------------------------------
    local f
    for f in "$BO_ROOT/config/agents/"*.md; do
        [ -e "$f" ] || continue
        config::_put_file "$f" "$CONFIG_DIR/agents/$(basename "$f")" || true
    done

    # ---- commands (8 files) ------------------------------------------------
    for f in "$BO_ROOT/config/commands/"*.md; do
        [ -e "$f" ] || continue
        config::_put_file "$f" "$CONFIG_DIR/commands/$(basename "$f")" || true
    done

    # ---- skills (19 directories; copystree dereferencing symlinks) ---------
    local d
    for d in "$BO_ROOT/config/skills/"*/; do
        [ -d "$d" ] || continue
        config::_put_dir "$d" "$CONFIG_DIR/skills/$(basename "$d")" || true
    done

    # ---- plugins (hardware hook for session-notify) ------------------------
    config::_put_file "$BO_ROOT/config/plugins/garble-guard.ts" "$CONFIG_DIR/plugins/garble-guard.ts" || true
    config::_put_file "$BO_ROOT/config/plugins/memory-rag.ts"    "$CONFIG_DIR/plugins/memory-rag.ts"    || true
    if config::gui_capable; then
        config::_put_file "$BO_ROOT/config/plugins/session-notify.ts" "$CONFIG_DIR/plugins/session-notify.ts" || true
    else
        bo_action "skipping config/plugins/session-notify.ts: no graphical desktop notifications target (session=${BO_SESSION_TYPE:-unknown})"
    fi

    # ---- bin helpers (websearch, page-extract, page_md.py) -----------------
    for f in "$BO_ROOT/bin/"*; do
        [ -e "$f" ] || continue
        local bn
        bn="$(basename "$f")"
        if bo_run cp -f "$f" "$BIN_DIR/$bn"; then
            if [ "$BO_DRY" != 1 ]; then chmod 755 "$BIN_DIR/$bn"; fi
            bo_record "$BIN_DIR/$bn"
        else
            bo_warn "failed to install bin helper: $bn"
        fi
    done

    bo_action "CONFIG INSTALL finished"
    return 0
}

# GUI capability per contract:
#   wayland -> yes; x11 -> yes only when polkit (pkexec) is present; else no.
config::gui_capable() {
    case "${BO_SESSION_TYPE:-}" in
        wayland) return 0 ;;
        x11)     command -v pkexec >/dev/null 2>&1 && return 0 ;;
        gui)     return 0 ;;   # darwin
    esac
    return 1
}
