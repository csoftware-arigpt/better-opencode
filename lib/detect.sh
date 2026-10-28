#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# better-opencode :: lib/detect.sh  (phase 1: SYSTEM STUDY)
#
# Purely read-only system inspection. Sourced by install.sh (and by the
# read-only `--os-report-only` mode, which sources ONLY this file). This
# library must never write to disk in any mode.
#
# Populates (exports) these variables for later phases:
#   BO_OS_FAMILY         linux | darwin | wsl | termux
#   BO_DISTRO_ID / BO_DISTRO_VERSION   from /etc/os-release when available
#   BO_ARCH              uname -m
#   BO_CPU_CORES         nproc / getconf / sysctl fallback
#   BO_TOTAL_RAM_KB      /proc/meminfo MemTotal or sysctl hw.memsize (KB)
#   BO_FREE_HOME_KB / BO_FREE_CFG_KB   df (KB) of $HOME fs / config dir fs
#   BO_SESSION_TYPE      wayland | x11 | headless | gui (darwin)
#   BO_PKG_ROOT          pkexec | sudo | none     (privilege escalation)
#   BO_PACKAGE_MANAGERS  space list: nix nix-env apt dnf pacman zypper apk brew pkg
#   BO_IS_NIXOS / BO_IS_TERMUX / BO_IS_WSL  yes/no
#   BO_BUILD_JOBS        min(cores,8); forced to 2 when total RAM < 2GiB
#   BO_VER_SORT_OK       1 when `sort -V` supports version compare
#   BO_HAS_CC / BO_HAS_NODE / BO_HAS_NPM / BO_HAS_PY3  gate flags
# ---------------------------------------------------------------------------
set -euo pipefail

# First line of a string (no pipes from live commands: no SIGPIPE hazards).
bo_first_line() { printf '%s\n' "$1" | awk 'NR==1{print}'; }

# True when version $1 >= $2 (GNU `sort -V`; guarded by BO_VER_SORT_OK).
# Semantics: A >= B  <=>  the ascending-minimum of {A,B} is B.
bo_ver_ge() {
    [ -n "$1" ] || return 1
    [ "$2" = "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" ]
}

# NOTE: never put a possibly-failing `&&` chain inside a heredoc/command
# substitution: under `set -e` a failed expansion aborts the enclosing command.

detect::is_nixos() {
    [ -e /etc/NIXOS ] && return 0
    command -v nixos-version >/dev/null 2>&1 && return 0
    return 1
}

detect::os_family() {
    # Termux (Android): TERMUX_VERSION or $PREFIX containing com.termux
    case "${PREFIX:-}" in *com.termux*) echo termux; return ;; esac
    if [ -n "${TERMUX_VERSION:-}" ]; then echo termux; return; fi
    case "$(uname -s 2>/dev/null || echo unknown)" in
        Darwin) echo darwin; return ;;
    esac
    if grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; return; fi
    echo linux
}

detect::distro() {
    BO_DISTRO_ID=""
    BO_DISTRO_VERSION=""
    if [ -r /etc/os-release ]; then
        BO_DISTRO_ID="$(awk -F= '$1=="ID"{gsub(/"/,"",$2);print $2;exit}' /etc/os-release 2>/dev/null || echo "")"
        BO_DISTRO_VERSION="$(awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2);print $2;exit}' /etc/os-release 2>/dev/null || echo "")"
    elif [ "${BO_OS_FAMILY:-}" = darwin ]; then
        BO_DISTRO_ID="macos"
        BO_DISTRO_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    fi
}

detect::cores() {
    # `nproc --all` ignores artificial CPU-affinity restrictions (containers/
    # sandboxes often restrict to 1 core); plain `nproc` as fallback.
    if command -v nproc >/dev/null 2>&1; then
        if _all="$(nproc --all 2>/dev/null)" && [ -n "$_all" ]; then
            echo "$_all"; return
        fi
        nproc 2>/dev/null || echo 2; return
    elif command -v getconf >/dev/null 2>&1; then
        getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2; return
    fi
    sysctl -n hw.ncpu 2>/dev/null || echo 2
}

detect::ram_kb() {
    if [ -r /proc/meminfo ]; then
        awk '/^MemTotal:/{print $2; exit}' /proc/meminfo
    elif command -v sysctl >/dev/null 2>&1; then
        # || true: never let a probing pipeline kill the run under set -e
        sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d\n", $1/1024}' || true
    else echo 0; fi
    return 0
}

# Free space in KB on the filesystem containing $1 (falls back to $HOME).
detect::free_kb() {
    local target="${1:-$HOME}"
    if [ ! -e "$target" ]; then target="$HOME"; fi
    df -P -k "$target" 2>/dev/null | awk 'NR==2{print $4}' || true
    return 0
}

detect::session_type() {
    case "${BO_OS_FAMILY:-}" in darwin) echo gui; return ;; esac
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then echo wayland; return; fi
    if [ -n "${DISPLAY:-}" ]; then echo x11; return; fi
    echo headless
}

# Privilege escalation per contract:
#   (a) graphical session AND pkexec present -> pkexec  (PKG_ROOT="pkexec")
#   (b) else sudo present                    -> sudo
#   (c) else                                 -> none (warn: user-level only)
detect::pkg_root() {
    case "${BO_SESSION_TYPE:-}" in
        wayland|x11|gui)
            if command -v pkexec >/dev/null 2>&1; then echo pkexec; return; fi ;;
    esac
    if command -v sudo >/dev/null 2>&1; then echo sudo; return; fi
    echo none
}

detect::package_managers() {
    local list=""
    if [ "${BO_OS_FAMILY:-}" = termux ]; then
        command -v pkg >/dev/null 2>&1 && list="pkg"
        echo "${list:-none}"; return
    fi
    if command -v nix >/dev/null 2>&1; then list="${list}${list:+ }nix"; fi
    if command -v nix-env >/dev/null 2>&1; then list="${list}${list:+ }nix-env"; fi
    local _pm
    for _pm in apt dnf pacman zypper apk brew; do
        if command -v "$_pm" >/dev/null 2>&1; then list="${list}${list:+ }${_pm}"; fi
    done
    echo "${list:-none}"
}

detect::build_jobs() {
    local cores="${BO_CPU_CORES:-2}" jobs ram="${BO_TOTAL_RAM_KB:-0}"
    case "$cores" in ''|*[!0-9]*) cores=2 ;; esac
    case "$ram" in ''|*[!0-9]*) ram=0 ;; esac
    if [ "$ram" -gt 0 ] && [ "$ram" -lt 2097152 ]; then
        jobs=2            # < 2 GiB RAM: hard cap for parallel compilation
    else
        jobs=$(( cores > 8 ? 8 : cores ))   # default: min(cores, 8)
    fi
    echo "$jobs"
}

# Trustworthy `sort -V`? (GNU extension; BSD/macOS sort may not support -V)
detect::_sort_v_ok() {
    if printf 'b\na\n' | sort -V 2>/dev/null | awk 'NR==1{print}' | grep -qx "a" 2>/dev/null; then
        echo 1
    else
        echo 0
    fi
    return 0
}

# --- tool gate flags reused by later phases ---------------------------------
detect::gates() {
    BO_HAS_CC=0
    local _c
    for _c in cc gcc clang; do
        if command -v "$_c" >/dev/null 2>&1; then BO_HAS_CC=1; break; fi
    done
    BO_HAS_NODE=0
    if command -v node >/dev/null 2>&1; then
        BO_NODE_VERSION="$(bo_first_line "$(node --version 2>/dev/null || echo v0.0.0)")"
        # strip leading "v" then take the major number
        BO_NODE_MAJOR="${BO_NODE_VERSION#v}"; BO_NODE_MAJOR="${BO_NODE_MAJOR%%[!0-9]*}"
        if [ "$BO_NODE_MAJOR" -ge 20 ] 2>/dev/null; then BO_HAS_NODE=1; fi
    fi
    BO_HAS_PY3=0
    if command -v python3 >/dev/null 2>&1; then BO_HAS_PY3=1; fi
    BO_HAS_NPM=0
    if command -v npm >/dev/null 2>&1; then BO_HAS_NPM=1; fi
    return 0
}

aligned_row() {
    printf '  %-21s %-30s %s\n' "$1" "$(printf '%s' "$2" | cut -c1-30)" "${3:-}"
}

# ---- main entry ------------------------------------------------------------
detect::report() {
    BO_OS_FAMILY=$(detect::os_family)
    BO_ARCH="$(uname -m 2>/dev/null || echo unknown)"
    detect::distro
    if detect::is_nixos; then BO_IS_NIXOS=yes; else BO_IS_NIXOS=no; fi
    BO_IS_TERMUX=no; BO_IS_WSL=no
    [ "$BO_OS_FAMILY" = termux ] && BO_IS_TERMUX=yes
    [ "$BO_OS_FAMILY" = wsl ] && BO_IS_WSL=yes
    BO_CPU_CORES="$(detect::cores)"
    BO_TOTAL_RAM_KB="$(detect::ram_kb)"
    BO_FREE_HOME_KB="$(detect::free_kb "$HOME")"
    BO_SESSION_TYPE="$(detect::session_type)"
    BO_PKG_ROOT="$(detect::pkg_root)"
    BO_PACKAGE_MANAGERS="$(detect::package_managers)"
    BO_BUILD_JOBS="$(detect::build_jobs)"
    BO_VER_SORT_OK="$(detect::_sort_v_ok)"
    export BO_OS_FAMILY BO_ARCH BO_DISTRO_ID BO_DISTRO_VERSION BO_IS_NIXOS BO_IS_TERMUX \
           BO_IS_WSL BO_CPU_CORES BO_TOTAL_RAM_KB BO_FREE_HOME_KB BO_SESSION_TYPE \
           BO_PKG_ROOT BO_PACKAGE_MANAGERS BO_BUILD_JOBS BO_VER_SORT_OK
    detect::gates

    local cfg_target="${CONFIG_DIR:-$HOME/.config/opencode}"
    BO_FREE_CFG_KB="$(detect::free_kb "$cfg_target")"

    # ---- precompute every note string BEFORE the heredoc (set -e safe) ----
    local fam_note="" pm_note="" esc_note="" jobs_note=""
    case "$BO_OS_FAMILY" in wsl) fam_note="${fam_note} (WSL detected)" ;; termux) fam_note="${fam_note} (Termux)" ;; esac
    if [ "$BO_IS_NIXOS" = yes ]; then pm_note="   [NixOS detected; nix profile preferred]"; fi
    if [ "$BO_PKG_ROOT" = none ]; then esc_note="   (warn: graphical pkexec absent; user-level only)"; fi
    if [ -n "${BO_TOTAL_RAM_KB:-0}" ] && [ "${BO_TOTAL_RAM_KB:-0}" -lt 2097152 ]; then
        jobs_note="   (RAM < 2GB -> build jobs capped)"
    fi
    local ram_gb="?" home_gb="?" cfg_gb="?"
    if [ "${BO_TOTAL_RAM_KB:-0}" -gt 0 ] 2>/dev/null; then ram_gb="$(( BO_TOTAL_RAM_KB / 1024 / 1024 ))"; fi
    if [ "${BO_FREE_HOME_KB:-0}" -gt 0 ] 2>/dev/null; then home_gb="$(( BO_FREE_HOME_KB / 1024 / 1024 ))"; fi
    if [ "${BO_FREE_CFG_KB:-0}" -gt 0 ] 2>/dev/null; then cfg_gb="$(( BO_FREE_CFG_KB / 1024 / 1024 ))"; fi

    cat <<EOF
== SYSTEM STUDY ================================================
  os family      : ${BO_OS_FAMILY}${fam_note}
  distro         : ${BO_DISTRO_ID:-unknown} ${BO_DISTRO_VERSION:-}
  arch           : ${BO_ARCH}
  cpu cores      : ${BO_CPU_CORES}
  total RAM      : ${BO_TOTAL_RAM_KB} KB (~${ram_gb} GiB)
  free disk HOME : ${BO_FREE_HOME_KB} KB (~${home_gb} GiB)
  free disk cfg  : ${BO_FREE_CFG_KB} KB (~${cfg_gb} GiB)  [target: ${cfg_target}]
  session type   : ${BO_SESSION_TYPE}
  privilege esc  : ${BO_PKG_ROOT}${esc_note}
  package mgrs   : ${BO_PACKAGE_MANAGERS}${pm_note}
  build jobs     : ${BO_BUILD_JOBS}${jobs_note}
EOF

    printf '  ---- tool probe ---------------------------------------------------\n'

    # node (<20 blocks the Context7 integration; npm/npx come with nodejs)
    local node_line="MISSING" node_note=""
    if command -v node >/dev/null 2>&1; then
        node_line="$(node --version 2>/dev/null || echo MISSING)"
        if [ "$BO_HAS_NODE" = 1 ]; then
            node_note="ok (>=20)"
        else
            node_note="PRESENT BUT <20 (Context7 will be skipped)"
        fi
    fi
    aligned_row "node" "$node_line" "$node_note"

    aligned_row "npx" "$({ command -v npx >/dev/null 2>&1 && npx --version 2>/dev/null || echo MISSING; })"
    aligned_row "npm" "$({ command -v npm >/dev/null 2>&1 && npm --version 2>/dev/null || echo MISSING; })"
    aligned_row "curl" "$({ command -v curl >/dev/null 2>&1 && curl --version 2>/dev/null | awk 'NR==1{print $2}' || echo MISSING; })"

    local py_line="MISSING" py_note=""
    if command -v python3 >/dev/null 2>&1; then
        py_line="$(python3 -V 2>/dev/null | awk '{print $2}')"
        py_note="$(python3 -c 'import sys; print("ok (>=3.8)" if sys.version_info>=(3,8) else "PRESENT TOO OLD (<3.8)")' 2>/dev/null || echo unknown)"
    fi
    aligned_row "python3" "$py_line" "$py_note"

    local git_line="MISSING"
    command -v git >/dev/null 2>&1 && git_line="$(git --version 2>/dev/null | awk 'NR==1{print $3}')"
    aligned_row "git" "$git_line"

    aligned_row "cargo/rustc" \
        "$({ command -v cargo >/dev/null 2>&1 && cargo --version 2>/dev/null | awk 'NR==1{print $2}' || echo MISSING; })" \
        "$(detect::_rust_note)"
    aligned_row "cc/gcc/clang" "$(detect::_cc_list)" "$(detect::_cc_note)"
    aligned_row "uv" "$({ command -v uv >/dev/null 2>&1 && uv --version 2>/dev/null | awk 'NR==1{print $2}' || echo MISSING; })" "(needed only for --with-wshobson)"
    aligned_row "make" "$({ command -v make >/dev/null 2>&1 && make --version 2>/dev/null | awk 'NR==1{print $3}' || echo MISSING; })"
    aligned_row "jq" "$({ command -v jq >/dev/null 2>&1 && jq --version 2>/dev/null | sed 's/^jq-//' || echo MISSING; })"
    aligned_row "tmux" "$({ command -v tmux >/dev/null 2>&1 && tmux -V 2>/dev/null || echo MISSING; })"
    local ns_line ns_note=""
    ns_line="MISSING"
    command -v notify-send >/dev/null 2>&1 && ns_line="$(notify-send --version 2>/dev/null | awk 'NR==1{print $2}')"
    [ "$BO_SESSION_TYPE" = headless ] && ns_note="(headless session: will not install session-notify plugin)"
    aligned_row "notify-send" "$ns_line" "$ns_note"
    aligned_row "shell" "${SHELL:-?}" "$( { command -v fish >/dev/null 2>&1 && printf 'fish available'; } || true )"
    if case ":$PATH:" in *":$HOME/.local/bin:"*) true ;; *) false ;; esac; then
        aligned_row "PATH check" "yes" "~/.local/bin already on PATH"
    else
        aligned_row "PATH check" "no" "~/.local/bin NOT on PATH (fix printed in VERIFY)"
    fi
    printf '================================================================\n'
}

# optional notes for the rust row (>=1.75 is the MUST-compile bar)
detect::_rust_note() {
    command -v rustc >/dev/null 2>&1 || { echo "REQUIRED (>=1.75): missing"; return; }
    local v; v="$(rustc --version 2>/dev/null | awk 'NR==1{print $2}')"
    if [ "$BO_VER_SORT_OK" = 1 ] && bo_ver_ge "$v" "1.75.0"; then
        echo "ok (>=1.75)"
    elif [ "$BO_VER_SORT_OK" = 1 ]; then
        echo "PRESENT BUT <1.75 -> rustup fallback available"
    else
        echo "version comparison unavailable (no functional sort -V)"
    fi
}

# list of C compiler frontends actually present (cc/gcc/clang)
detect::_cc_list() {
    local _c out=""
    for _c in cc gcc clang; do
        if command -v "$_c" >/dev/null 2>&1; then out="${out:+$out, }$_c"; fi
    done
    echo "${out:-MISSING}"
}
detect::_cc_note() {
    if detect::_cc_list | grep -q "MISSING"; then
        echo "REQUIRED to link vendored sqlite (rusqlite)"
    else
        echo "ok (C compiler present)"
    fi
}
