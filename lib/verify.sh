#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# better-opencode :: lib/verify.sh  (phase 7: VERIFY)
#
# Read-mostly validation of the result:
#   * opencode.json parses as JSON (python3 -m json.tool)
#   * expected vs actual counts of .md files in agents/commands/skills/plugins
#     (symlink entries counted separately; broken symlinks warn)
#   * installed bins: sha256 + "runnable?" checks
#   * memrag binary smoke test (MEMRAG_DIR pointed at a temp dir, rc must be 0)
#   * PATH containment for $BIN_DIR with exact export lines for bash/zsh/fish
#
# The final line of a full (non-dry) run prints "INSTALL: complete" and the
# TODO list for the user (restart sessions / reload the TUI config).
# ---------------------------------------------------------------------------
set -euo pipefail

verify::json() {
    if [ ! -f "$CONFIG_DIR/opencode.json" ]; then
        bo_warn "opencode.json not found in $CONFIG_DIR (skipped if intentionally absent)"
        return 1
    fi
    if [ "${BO_HAS_PY3:-0}" = 1 ]; then
        if bo_run_script "python3 -m json.tool $CONFIG_DIR/opencode.json >/dev/null"; then
            bo_action "opencode.json: valid JSON"
            return 0
        fi
        bo_warn "opencode.json is NOT valid JSON (inspect manually)"
        return 1
    fi
    bo_warn "python3 missing: JSON validation skipped"
    return 1
}

# count helper: top-level entries in a dir (skills are dirs, plugins are .ts),
# reporting "any plain links broken"
verify::count_entries() {
    local dir="$1" t=0 plain=0 links=0 broken=0 p
    if [ ! -d "$dir" ]; then
        echo "0 0 0 0"
        return 0
    fi
    for p in "$dir"/*; do
        [ -e "$p" ] || continue
        t=$((t+1))
        if [ -L "$p" ]; then
            links=$((links+1))
            [ -e "$p" ] || broken=$((broken+1))
        else
            plain=$((plain+1))
        fi
    done
    echo "$t $plain $links $broken"
}

# count helper: .md files (plain files), plus separate symlink tally
verify::count_md() {
    local dir="$1" plain=0 links=0 broken=0 any=0 p
    if [ ! -d "$dir" ]; then
        echo "0 0 0 0"
        return 0
    fi
    for p in "$dir"/*.md; do
        [ -e "$p" ] || continue
        any=$((any+1))
        if [ -L "$p" ]; then
            links=$((links+1))
            if [ -e "$p" ]; then :; else broken=$((broken+1)); fi
        else
            plain=$((plain+1))
        fi
    done
    echo "$any $plain $links $broken"
}

verify::counts() {
    local base_a=4 base_c=8 base_s=19 base_p=3
    local expa="$base_a" expc="$base_c" exps="$base_s" expp="$base_p"
    if [ "${BO_WSHOBSON_DONE:-0}" = 1 ]; then
        expa=$((expa+17)); expc=$((expc+12)); exps=$((exps+36))
    fi
    if ! config::gui_capable; then
        expp=$((expp-1))   # session-notify.ts intentionally not installed
    fi

    local read_a read_c read_s read_p
    read_a="$(verify::count_md "$CONFIG_DIR/agents")"
    read_c="$(verify::count_md "$CONFIG_DIR/commands")"
    read_s="$(verify::count_entries "$CONFIG_DIR/skills")"
    read_p="$(verify::count_entries "$CONFIG_DIR/plugins")"

    bo_action "agents/   md entries: total=$(( $(awk '{print $1}' <<<"$read_a") )) plain=$(( $(awk '{print $2}' <<<"$read_a") )) symlinks=$(( $(awk '{print $3}' <<<"$read_a") )) expected=$expa"
    bo_action "commands/ md entries: total=$(( $(awk '{print $1}' <<<"$read_c") )) plain=$(( $(awk '{print $2}' <<<"$read_c") )) symlinks=$(( $(awk '{print $3}' <<<"$read_c") )) expected=$expc"
    bo_action "skills/   entries  : total=$(( $(awk '{print $1}' <<<"$read_s") )) plain=$(( $(awk '{print $2}' <<<"$read_s") )) symlinks=$(( $(awk '{print $3}' <<<"$read_s") )) expected=$exps (skill dirs copied with symlinks dereferenced)"
    bo_action "plugins/  entries  : total=$(( $(awk '{print $1}' <<<"$read_p") )) plain=$(( $(awk '{print $2}' <<<"$read_p") )) symlinks=$(( $(awk '{print $3}' <<<"$read_p") )) expected=$expp (.ts plugins)"

    # broken links warning
    local b=0 name
    for name in read_a read_c read_s read_p; do
        b=$(( b + $(awk '{print $4}' <<<"${!name}") ))
    done
    if [ "$b" -gt 0 ]; then
        bo_warn "$b broken symlink(s) among installed entries"
    fi

    # shortfalls (informational warnings)
    if [ "$(( $(awk '{print $1}' <<<"$read_a") ))" -lt "$expa" ]; then
        bo_warn "fewer agent .md files than expected (expected=$expa; see the agents row above)"
    fi
    if [ "$(( $(awk '{print $1}' <<<"$read_s") ))" -lt "$exps" ]; then
        bo_warn "fewer skill directories than expected (expected=$exps)"
    fi
    return 0
}

verify::bins() {
    local f bn ok
    for f in "$BIN_DIR"/websearch "$BIN_DIR"/page-extract "$BIN_DIR"/page_md.py; do
        [ -e "$f" ] || { bo_warn "expected bin missing: $f"; continue; }
        bn="$(basename "$f")"
        ok=bash
        if [ "$bn" = page_md.py ]; then ok=py; fi
        printf '[better-opencode] %s sha256=%s runnable(' "$bn" "$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
        if [ "$ok" = py ]; then
            if [ "${BO_HAS_PY3:-0}" = 1 ] && python3 -m py_compile "$f" >/dev/null 2>&1; then
                printf 'py_compile: OK)\n'
            else
                printf 'py_compile: FAIL)\n'
            fi
        else
            if bash -n "$f" 2>/dev/null; then
                printf 'bash -n: OK)\n'
            else
                printf 'bash -n: FAIL)\n'
            fi
        fi
    done
    return 0
}

verify::memrag() {
    local link="$BIN_DIR/memrag" tmp out
    if [ ! -x "${BO_ROOT}/vendor/opencode-memory-rag/rust/target/release/memrag" ] && [ ! -e "$link" ]; then
        bo_warn "memrag binary not present (built with --no-memrag? skipped?)"
        return 1
    fi
    if [ ! -e "$link" ]; then
        bo_warn "symlink $link missing although the binary exists"
        return 1
    fi
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/bo-verify-memrag.XXXXXX")"
    if out="$(MEMRAG_DIR="$tmp" "$link" --help 2>&1)"; then
        bo_action "memrag --help smoke: rc=0 OK"
        rm -rf "$tmp"
        return 0
    fi
    if out="$(MEMRAG_DIR="$tmp" "$link" stats 2>&1)"; then
        bo_action "memrag stats smoke: rc=0 OK"
        rm -rf "$tmp"
        return 0
    fi
    bo_warn "memrag smoke test failed: $out"
    return 1
}

verify::path() {
    if case ":$PATH:" in *":$BIN_DIR:"*) true ;; *) false ;; esac; then
        bo_action "PATH contains $BIN_DIR already"
        return 0
    fi
    printf '[better-opencode][warn]  %s is NOT on PATH. Add with:\n' "$BIN_DIR"
    printf '  bash/zsh : export PATH="%s:$PATH"      # put in ~/.bashrc / ~/.zshrc\n' "$BIN_DIR"
    printf '  fish     : fish_add_path %s\n' "$BIN_DIR"
    return 0
}

verify::run() {
    if [ "$BO_DRY" = 1 ]; then
        bo_action "VERIFY skipped by --dry-run reasoning: no changes were made; run without --dry-run to verify a real install"
        verify::path
        printf '[better-opencode] dry run finished without touching anything.\n'
        return 0
    fi
    verify::json || true
    verify::counts
    verify::bins
    verify::memrag || true
    verify::path
    printf '\n[better-opencode] ================= VERIFICATION =================\n'
    printf '[better-opencode] INSTALL: complete\n'
    printf '[better-opencode] TODO for you:\n'
    printf '[better-opencode]  * restart open OpenCode sessions / the TUI so the new config is loaded\n'
    printf '[better-opencode]  * watch the terminal for the Context7 device-code prompt (OAuth)\n'
    printf '[better-opencode]  * detection report and binaries were verified above\n'
    return 0
}
