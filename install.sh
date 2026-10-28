#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# better-opencode :: install.sh (master orchestrator)
#
# Installs a ready-to-use OpenCode station: vendored agents/commands/skills/
# plugins, curl search helpers, the Rust "memrag" CLI, Context7 MCP and
# optional REA / wshobson integration units.
#
# Usage:
#   ./install.sh [flags]
#
# Flags:
#   --help              show this help and exit
#   --yes               non-interactive: answer "yes" to every prompt
#   --dry-run           full trace of every action, ZERO writes to disk
#   --os-report-only    print the SYSTEM STUDY detection report and exit 0
#                       (read-only: guaranteed not to write anything)
#   --force             overwrite existing files instead of skipping them
#   --no-memrag         skip compiling the vendored Rust memrag binary
#                       (escape hatch for machines without a working Rust toolchain)
#   --with-rea          also install the REA reverse-engineering stack
#                       (npm -g rea-agents + `rea setup --client opencode`)
#   --with-wshobson     also build/install the wshobson community agents pack
#   --skip-context7     skip the Context7 MCP integration
#   --bin-dir DIR       bin install dir   (default: ~/.local/bin)
#   --config-dir DIR    config install dir (default: ~/.config/opencode)
#
# Phase map (progress lines print these numbers):
#   0  banner + flag parsing
#   1  SYSTEM STUDY            lib/detect.sh   (mandatory, always printed)
#   2  DEPENDENCIES           lib/prereq.sh
#   3  MANDATORY BUILD         lib/build.sh    (Rust memrag; aborts unless --no-memrag)
#   4  OPENCODE SETUP          lib/config.sh   (+ optional wshobson pack after config;
#                                 permission asked interactively, or --with-wshobson)
#   5  INTEGRATIONS            lib/integrate.sh
#   7  VERIFY                  lib/verify.sh
#
# All library files are sourced into this same shell process, so exported
# variables (BO_*) are shared freely between phases.
# ---------------------------------------------------------------------------
set -euo pipefail

# Resolve the absolute path of this script's directory ONCE (symlink-safe).
BO_SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$BO_SCRIPT_SOURCE" ]; do
    _bo_dir="$(cd -P "$(dirname -- "$BO_SCRIPT_SOURCE")" && pwd -P)"
    BO_SCRIPT_SOURCE="$(readlink -- "$BO_SCRIPT_SOURCE")"
    [ "${BO_SCRIPT_SOURCE#/*}" != "$BO_SCRIPT_SOURCE" ] || BO_SCRIPT_SOURCE="$_bo_dir/$BO_SCRIPT_SOURCE"
done
BO_ROOT="$(cd -P "$(dirname -- "$BO_SCRIPT_SOURCE")" && pwd -P)"

# --- sane defaults ----------------------------------------------------------
BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/opencode"
STATE_DIR="${HOME}/.local/state/better-opencode"
MANIFEST_FILE="${STATE_DIR}/manifest.txt"

# --- flags (parsed from an array below are just $1/$2 shifted) --------------
FLAG_YES=0        # --yes
FLAG_DRY=0        # --dry-run
FLAG_REPORT=0     # --os-report-only
FLAG_FORCE=0      # --force
FLAG_NO_MEMRAG=0  # --no-memrag
FLAG_WITH_REA=0   # --with-rea
FLAG_WITH_WSHOBSON=0  # --with-wshobson
FLAG_SKIP_CONTEXT7=0  # --skip-context7

BO_RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"   # identifies one install run in manifest
BO_READ_ONLY=0                          # 1 => any guarded write is a bug
BO_DRY=0                                # 1 => guarded writes become echo lines

# --------------------------------------------------------------------------
# Logging helpers (used by all lib/*.sh files; undefined there on purpose,
# defined here exactly once so all phases share the same prefix).
# --------------------------------------------------------------------------
bo_log()  { printf '[better-opencode] %s\n' "$*"; }
bo_warn() { printf '[better-opencode][warn]  %s\n' "$*"; }
bo_err()  { printf '[better-opencode][error] %s\n' "$*" >&2; }
bo_die()  { bo_err "$*"; exit 1; }
bo_phase(){ printf '\n[better-opencode] ==> phase %s: %s\n' "$1" "$2"; }

# Guarded-mutation helpers. Every phase routes its writes through these so
# --dry-run and --os-report-only can enforce "zero writes" centrally.

# Print a line describing an action (always), and mark dry-run for clarity.
bo_action() {
    if [ "$BO_DRY" = 1 ]; then printf '[dry-run] %s\n' "$*";
    else printf '[better-opencode] %s\n' "$*"; fi
}

# mkdir -p, dry-run aware; refuses to run in read-only (report) mode.
bo_mkdir() {
    if [ "$BO_READ_ONLY" = 1 ]; then bo_die "internal: bo_mkdir called in --os-report-only mode"; fi
    if [ "$BO_DRY" = 1 ]; then
        bo_action "mkdir -p $*"
        return 0
    fi
    mkdir -p "$@"
}

# Append an absolute path to the manifest (deduped). Creates the state dir
# and the per-run header line lazily, on first record of this run.
bo_record() {
    if [ "$BO_READ_ONLY" = 1 ]; then bo_die "internal: bo_record called in --os-report-only mode"; fi
    if [ "$BO_DRY" = 1 ]; then bo_action "record in manifest: $1"; return 0; fi
    [ -n "$1" ] || return 0
    mkdir -p "$STATE_DIR" 2>/dev/null || bo_die "cannot create state dir: $STATE_DIR"
    # add the per-run header line exactly once
    if ! grep -q "run_id=${BO_RUN_ID} " "$MANIFEST_FILE" 2>/dev/null; then
        printf '# run_id=%s timestamp=%s root=%s config-dir=%s bin-dir=%s flags=%s\n' \
            "${BO_RUN_ID}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BO_ROOT" "$CONFIG_DIR" "$BIN_DIR" \
            "${BO_RUN_FLAGS_NOTE:-manual}" >> "$MANIFEST_FILE"
    fi
    # dedupe: record a path only once across all runs
    if [ -s "$MANIFEST_FILE" ] && grep -Fxq -- "$1" "$MANIFEST_FILE"; then
        return 0
    fi
    printf '%s\n' "$1" >> "$MANIFEST_FILE"
}

# Run a command unless --dry-run (then only print it). "$@" = argv.
bo_run() {
    bo_action "+ $*"
    [ "$BO_DRY" = 1 ] && return 0
    "$@"
}

# Run a shell snippet unless --dry-run. Arguments passed as $1 = snippet string.
bo_run_script() {
    bo_action "+ $1"
    [ "$BO_DRY" = 1 ] && return 0
    bash -c "$1"
}

# Confirm helper: returns 0 when the user (or --yes) says yes.
bo_confirm() {
    if [ "$FLAG_YES" = 1 ]; then return 0; fi
    if [ ! -t 0 ]; then return 1; fi
    local _ans=""
    printf '%s [y/N] ' "$*" >&2
    read -r _ans || return 1
    case "$_ans" in [Yy]|[Yy][Ee][Ss]) return 0 ;; *) return 1 ;; esac
}

# Usage / help text.
bo_usage() {
    cat <<'USG'
better-opencode installer

Usage: ./install.sh [flags]
  --help              show this help
  --yes               non-interactive (answer yes)
  --dry-run           full trace, zero writes
  --os-report-only    print SYSTEM STUDY report and exit 0 (read-only)
  --force             overwrite existing files instead of skipping
  --no-memrag         skip the mandatory Rust memrag build
  --with-rea          install REA stack (npm -g rea-agents + rea setup)
  --with-wshobson     build/install the wshobson community agents pack
  --skip-context7     skip Context7 MCP setup
  --bin-dir DIR       context bin dir   (default ~/.local/bin)
  --config-dir DIR    config dir         (default ~/.config/opencode)
USG
}

# --------------------------------------------------------------------------
# Flag parsing (space-value forms supported; --flag=value normalized).
# --------------------------------------------------------------------------
_args=("$@")
_i=0
while [ "$_i" -lt "${#_args[@]}" ]; do
    case "${_args[$_i]}" in
        --help|-h)          bo_usage; exit 0 ;;
        --yes|-y)           FLAG_YES=1 ;;
        --dry-run)          FLAG_DRY=1 ;;
        --os-report-only)   FLAG_REPORT=1 ;;
        --force|-f)         FLAG_FORCE=1 ;;
        --no-memrag)        FLAG_NO_MEMRAG=1 ;;
        --with-rea)         FLAG_WITH_REA=1 ;;
        --with-wshobson)    FLAG_WITH_WSHOBSON=1 ;;
        --skip-context7)    FLAG_SKIP_CONTEXT7=1 ;;
        --bin-dir)          _i=$((_i+1)); [ "$_i" -lt "${#_args[@]}" ] || bo_die "--bin-dir requires a value"; BIN_DIR="${_args[$_i]}"; BIN_DIR="${BIN_DIR/#\~/$HOME}" ;;
        --config-dir)       _i=$((_i+1)); [ "$_i" -lt "${#_args[@]}" ] || bo_die "--config-dir requires a value"; CONFIG_DIR="${_args[$_i]}"; CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}" ;;
        --bin-dir=*)        BIN_DIR="${_args[$_i]#--bin-dir=}"; BIN_DIR="${BIN_DIR/#\~/$HOME}" ;;
        --config-dir=*)     CONFIG_DIR="${_args[$_i]#--config-dir=}"; CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}" ;;
        *)                  bo_err "unknown flag: ${_args[$_i]}"; bo_usage; exit 1 ;;
    esac
    _i=$((_i+1))
done

# --------------------------------------------------------------------------
# Phase 0: banner
# --------------------------------------------------------------------------
printf '%s\n' "=================================================================="
printf '%s\n' " better-opencode :: installer"
printf '%s\n' " root: $BO_ROOT"
printf '%s\n' "=================================================================="

# --os-report-only: print the SYSTEM STUDY report and exit 0. Read-only by
# construction: we enable read-only mode FIRST and only source lib/detect.sh,
# which never writes anything. No state dir, no log, no manifest.
if [ "$FLAG_REPORT" = 1 ]; then
    BO_READ_ONLY=1
    bo_phase "1/6" "SYSTEM STUDY (os-report-only: read-only, will not touch anything)"
    source "$BO_ROOT/lib/detect.sh"
    detect::report
    exit 0
fi

# --dry-run: enable a full shell trace for the rest of the run (zero writes
# are still enforced by the bo_* helpers, which switch to echo-only mode).
if [ "$FLAG_DRY" = 1 ]; then
    BO_DRY=1
    PS4='+[trace] '
    set -x
    export BO_RUN_FLAGS_NOTE="dry-run"
fi

# Pre-flight: the vendored tree must be complete (honest early failure).
for _req in \
    "$BO_ROOT/config/opencode.json.template" \
    "$BO_ROOT/config/AGENTS.md" \
    "$BO_ROOT/bin/websearch" \
    "$BO_ROOT/bin/page-extract" \
    "$BO_ROOT/bin/page_md.py" \
    "$BO_ROOT/vendor/opencode-memory-rag/rust/Cargo.toml"
do
    if [ ! -e "$_req" ]; then
        bo_warn "expected vendored file is missing: $_req"
    fi
done

# Source all phase libraries (same process => shared BO_* variables).
source "$BO_ROOT/lib/detect.sh"
source "$BO_ROOT/lib/prereq.sh"
source "$BO_ROOT/lib/build.sh"
source "$BO_ROOT/lib/config.sh"
source "$BO_ROOT/lib/integrate.sh"
source "$BO_ROOT/lib/verify.sh"

# --------------------------------------------------------------------------
# Phase 1/6: SYSTEM STUDY (mandatory on every run, including --dry-run).
# --------------------------------------------------------------------------
bo_phase "1/6" "SYSTEM STUDY"
detect::report

# --------------------------------------------------------------------------
# Phase 2/6: DEPENDENCIES (auto-adaptation done in phase 1 drives this).
# --------------------------------------------------------------------------
bo_phase "2/6" "DEPENDENCIES"
prereq::run

# --------------------------------------------------------------------------
# Phase 3/6: MANDATORY BUILD (vendored Rust memrag CLI).
# --------------------------------------------------------------------------
bo_phase "3/6" "MANDATORY BUILD (memrag)"
build::mandatory

# --------------------------------------------------------------------------
# Phase 4/6: OPENCODE SETUP — only after dependencies and the build succeed.
# The optional wshobson pack lands here too: it is config-dir territory and
# runs strictly after the core config files are in place. Consent rules:
#   --with-wshobson passed          -> pack installs (explicit consent)
#   interactive run, no --yes       -> installer ASKS explicitly [y/N]
#   --yes without the flag          -> skipped silently with a hint
# --------------------------------------------------------------------------
bo_phase "4/6" "OPENCODE SETUP"
config::install

if [ "$FLAG_WITH_WSHOBSON" = 1 ]; then
    bo_phase "4/6" "OPENCODE SETUP (wshobson pack)"
    build::wshobson
elif [ "$FLAG_DRY" != 1 ] && [ "$FLAG_YES" != 1 ] && [ -t 0 ]; then
    printf '[better-opencode] install the optional wshobson community pack (8 plugins, uv + git clone)? [y/N]: '
    read -r bo_wsh_answer || bo_wsh_answer="n"
    case "$bo_wsh_answer" in
        y|Y|yes|YES) FLAG_WITH_WSHOBSON=1; bo_phase "4/6" "OPENCODE SETUP (wshobson pack, approved)"; build::wshobson ;;
        *) bo_action "wshobson pack skipped (opt in later with --with-wshobson)" ;;
    esac
else
    bo_action "wshobson pack skipped (opt in with --with-wshobson)"
fi

# --------------------------------------------------------------------------
# Phase 5/6: INTEGRATIONS (Context7 MCP unless skipped/wrong node; REA when
# requested; the device-code OAuth note is printed by integrate itself).
# --------------------------------------------------------------------------
bo_phase "5/6" "INTEGRATIONS"
integrate::run

# --------------------------------------------------------------------------
# Phase 6/6: VERIFY (prints final "INSTALL: complete" + TODO for the user).
# --------------------------------------------------------------------------
bo_phase "6/6" "VERIFY"
verify::run

exit 0
