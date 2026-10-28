#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# better-opencode :: lib/prereq.sh  (phase 2: PREREQUISITES)
#
# Installs missing base dependencies. Sourced by install.sh; every write is
# routed through bo_run / bo_run_script so --dry-run prints instead of acts.
#
# Install order (per contract):
#   1) NixOS / any machine with `nix`      -> nix profile install nixpkgs#... (user-level, no root)
#   2) else detected package manager       -> apt/dnf/pacman/zypper/apk/brew/pkg with $PKG_ROOT
#
# Maps:
#   node >=20 -> nodejs npm        python3 -> python3      curl -> curl
#   git -> git                     make -> make            tmux -> tmux
#   notify-send -> libnotify*      cc      -> build-essential / development-tools / base-devel / gcc
#   rust/cargo (>=1.75) -> distro rust+cargo, else rustup (downloaded, never piped to shell)
#
# RAM hard check: total RAM < 2 GiB => BUILD_JOBS := 2 AND a warning is printed.
# ---------------------------------------------------------------------------
set -euo pipefail

# Picked package manager is exported so other libs can reference it.
BO_PREREQ_PM=""
BO_PREREQ_INCOMPLETE=0
BO_MANUAL_INSTALL_HINTS=""

prereq::_jobs_final() {
    local ram="${BO_TOTAL_RAM_KB:-0}"
    if [ -n "$ram" ] && [ "$ram" -gt 0 ] && [ "$ram" -lt 2097152 ]; then
        bo_warn "only ${ram} KB total RAM (< 2GB): build jobs forced to 2"
        BO_BUILD_JOBS=2
    fi
    bo_action "BUILD_JOBS=${BO_BUILD_JOBS} (cargo -j)"
    export BO_BUILD_JOBS
}

# Choose one package manager: prefer nix (user-level, works on NixOS),
# else the first of the standard list, else Termux pkg.
prereq::pm_pick() {
    local _pm
    case " ${BO_PACKAGE_MANAGERS:-} " in
        *" nix "*) echo nix; return ;;
    esac
    if [ "${BO_IS_TERMUX:-}" = yes ]; then echo pkg; return; fi
    for _pm in apt dnf pacman zypper apk brew; do
        case " ${BO_PACKAGE_MANAGERS:-} " in
            *" $_pm "*) echo "$_pm"; return ;;
        esac
    done
    echo ""
}

# Translate (pm, dependency-kind) into package names.
prereq::pkg_for() {
    local pm="$1" kind="$2"
    case "$kind.$pm" in
        node.nix)        echo nodejs ;;
        node.pkg|node.nix-env) echo nodejs ;;
        node.*)          echo "nodejs npm" ;;                 # apt/dnf/pacman/zypper/apk
        python3.nix)     echo python3 ;;
        python3.*)       echo python3 ;;
        curl.nix)        echo curl ;;
        curl.*)          echo curl ;;
        git.nix)         echo git ;;
        git.*)           echo git ;;
        make.nix)        echo gnumake ;;
        make.*)          echo make ;;
        tmux.nix)        echo tmux ;;
        tmux.*)          echo tmux ;;
        notify.nix)      echo libnotify ;;
        notify.apt)      echo libnotify-bin ;;
        notify.brew)     echo ""          ;;  # no libnotify formula; warn in caller
        notify.*)        echo libnotify ;;
        cc.nix)          echo gcc ;;
        cc.apt)          echo build-essential ;;
        cc.dnf)          echo "gcc gcc-c++" ;;                # "development-tools" group tried as fallback
        cc.pacman)       echo base-devel ;;
        cc.zypper)       echo "gcc gcc-c++" ;;
        cc.apk)          echo build-base ;;
        cc.pkg)          echo clang ;;
        cc.brew)         echo gcc ;;
        rust.nix)        echo "cargo rustc" ;;
        rust.apt)        echo "rustc cargo" ;;
        rust.dnf)        echo "rust cargo" ;;
        rust.pacman)     echo rust ;;
        rust.zypper)     echo "rust cargo" ;;
        rust.apk)        echo "rust cargo" ;;
        rust.pkg)        echo rust ;;
        rust.brew)       echo rust ;;
        uv.nix)          echo uv ;;
        uv.*)            echo uv ;;
        *)               echo "" ;;
    esac
}

# Execute an install command for the chosen pm. Root wrapper (sudo/pkexec from
# the SYSTEM STUDY phase) applied when needed and available. Never actually
# runs under --dry-run (bo_run prints the exact argv instead).
prereq::install_pkgs() {
    local pm="$1"; shift
    local pkgs="$*"
    local wrapper=""

    if [ "$pm" = nix ]; then
        prereq::install_nix "$pkgs"   # user-level: no root needed
        return $?
    fi

    # decide whether a privilege wrapper is needed for this pm
    if [ "$(id -u)" -eq 0 ]; then
        wrapper=""
    else
        case "$pm" in
            brew|pkg) wrapper="" ;;                      # rootless ecosystems
            apt|dnf|pacman|zypper|apk)
                case "${BO_PKG_ROOT:-none}" in
                    sudo|pkexec) wrapper="$BO_PKG_ROOT" ;;
                    *)
                        bo_warn "$pm needs root but PKG_ROOT=none: cannot install [$pkgs] automatically"
                        BO_MANUAL_INSTALL_HINTS="${BO_MANUAL_INSTALL_HINTS} [$pkgs via $pm]"
                        BO_PREREQ_INCOMPLETE=1
                        return 1
                        ;;
                esac
                ;;
            *) return 1 ;;
        esac
    fi

    case "$pm" in
        apt)
            # unquoted $pkgs is intentional: package names are word-splitted
            bo_run "$wrapper" env DEBIAN_FRONTEND=noninteractive apt-get update -y || true
            bo_run "$wrapper" env DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs \
                || { BO_PREREQ_INCOMPLETE=1; BO_MANUAL_INSTALL_HINTS="${BO_MANUAL_INSTALL_HINTS} [$pkgs via apt]"; return 1; }
            ;;
        dnf)
            if [ "$pkgs" = "gcc gcc-c++" ]; then
                # try the "development-tools" group first; fall back to pkgs
                bo_run "$wrapper" dnf group install -y development-tools \
                    || bo_run "$wrapper" dnf install -y $pkgs \
                    || { BO_PREREQ_INCOMPLETE=1; BO_MANUAL_INSTALL_HINTS="${BO_MANUAL_INSTALL_HINTS} [$pkgs via dnf]"; return 1; }
            else
                bo_run "$wrapper" dnf install -y $pkgs \
                    || { BO_PREREQ_INCOMPLETE=1; BO_MANUAL_INSTALL_HINTS="${BO_MANUAL_INSTALL_HINTS} [$pkgs via dnf]"; return 1; }
            fi
            ;;
        pacman)
            bo_run "$wrapper" pacman -S --needed --noconfirm $pkgs \
                || { BO_PREREQ_INCOMPLETE=1; BO_MANUAL_INSTALL_HINTS="${BO_MANUAL_INSTALL_HINTS} [$pkgs via pacman]"; return 1; }
            ;;
        zypper)
            bo_run "$wrapper" zypper -n install $pkgs \
                || { BO_PREREQ_INCOMPLETE=1; BO_MANUAL_INSTALL_HINTS="${BO_MANUAL_INSTALL_HINTS} [$pkgs via zypper]"; return 1; }
            ;;
        apk)
            bo_run "$wrapper" apk add $pkgs \
                || { BO_PREREQ_INCOMPLETE=1; BO_MANUAL_INSTALL_HINTS="${BO_MANUAL_INSTALL_HINTS} [$pkgs via apk]"; return 1; }
            ;;
        brew)
            bo_run brew install $pkgs \
                || { BO_PREREQ_INCOMPLETE=1; BO_MANUAL_INSTALL_HINTS="${BO_MANUAL_INSTALL_HINTS} [$pkgs via brew]"; return 1; }
            ;;
        pkg)   # Termux, rootless
            bo_run pkg install -y $pkgs \
                || { BO_PREREQ_INCOMPLETE=1; BO_MANUAL_INSTALL_HINTS="${BO_MANUAL_INSTALL_HINTS} [$pkgs via pkg]"; return 1; }
            ;;
        *)
            bo_warn "no supported install path for [$pkgs] (pm=$pm)"
            BO_PREREQ_INCOMPLETE=1
            return 1
            ;;
    esac
    return 0
}

# nix profile install of "pkg1 pkg2 ..." -> nixpkgs#pkg1 nixpkgs#pkg2 ...
prereq::install_nix() {
    local pieces args=""
    for pieces in $1; do
        args="$args nixpkgs#$pieces"
    done
    args="${args# }"
    if bo_run nix profile install "$args"; then
        return 0
    fi
    # older nix without flakes: fall back to nix-env -iA (also user-level)
    bo_warn "nix profile install failed; trying nix-env -iA (legacy)"
    local o ok=0 sum=""
    for o in $1; do
        if bo_run nix-env -iA "nixpkgs.$o"; then ok=1; else BO_PREREQ_INCOMPLETE=1; fi
        sum="$sum $o"
    done
    [ "$ok" = 1 ]
}

# Generic gate: ensure `cmd` exists, else install mapped packages.
prereq::ensure() {
    local kind="$1" check="$2" note="${3:-}"
    if command -v "$check" >/dev/null 2>&1; then
        bo_action "dependency ok: $kind ($note)"
        return 0
    fi
    bo_action "missing: $kind -> installing via $BO_PREREQ_PM"
    if ! prereq::install_pkgs "$BO_PREREQ_PM" "$(prereq::pkg_for "$BO_PREREQ_PM" "$kind")"; then
        bo_warn "could not install [$kind] automatically; continuing (later phases may degrade)"
        BO_MANUAL_INSTALL_HINTS="${BO_MANUAL_INSTALL_HINTS} [$kind]"
        return 1
    fi
    return 0
}

# notify-send only makes sense on a desktop session.
prereq::ensure_notify() {
    if command -v notify-send >/dev/null 2>&1; then
        bo_action "dependency ok: notify-send (libnotify)"
        return 0
    fi
    case "${BO_SESSION_TYPE:-}" in
        wayland|x11|gui)
            bo_action "missing: notify-send -> installing libnotify (GUI session)"
            if [ "$BO_PREREQ_PM" = brew ]; then
                bo_warn "brew has no libnotify formula: desktop notifications stay unavailable (manual build needed)"
                return 1
            fi
            prereq::install_pkgs "$BO_PREREQ_PM" "$(prereq::pkg_for "$BO_PREREQ_PM" notify)" \
                && return 0
            bo_warn "libnotify install failed (non-fatal)"
            return 1
            ;;
        *)
            bo_action "notify-send missing: skipped (no graphical session, plugin session-notify will be excluded)"
            return 0
            ;;
    esac
}

# Rust: required to compile vendored memrag (>= 1.75). Prefer distro packages,
# fall back to rustup when the distro toolchain is too old or unavailable.
prereq::ensure_rust() {
    local ok=0
    if command -v rustc >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
        local v
        v="$(rustc --version 2>/dev/null | awk 'NR==1{print $2}')"
        if [ "$BO_VER_SORT_OK" = 1 ] && bo_ver_ge "$v" "1.75.0"; then
            bo_action "dependency ok: rust toolchain $v (>=1.75)"
            return 0
        fi
        bo_action "rust $v is <1.75 -> attempting newer distribution packages"
        prereq::install_pkgs "$BO_PREREQ_PM" "$(prereq::pkg_for "$BO_PREREQ_PM" rust)" && ok=1
    else
        bo_action "missing: cargo/rustc -> installing via $BO_PREREQ_PM (MUST-compile requirement)"
        prereq::install_pkgs "$BO_PREREQ_PM" "$(prereq::pkg_for "$BO_PREREQ_PM" rust)" && ok=1
    fi
    # re-probe after package installation
    if command -v rustc >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
        local v2
        v2="$(rustc --version 2>/dev/null | awk 'NR==1{print $2}')"
        if [ "$BO_VER_SORT_OK" = 1 ] && bo_ver_ge "$v2" "1.75.0"; then
            bo_action "dependency ok: rust toolchain $v2 (>=1.75) after install"
            return 0
        fi
        bo_action "distro rust is still <1.75 ($v2) -> falling back to rustup"
        prereq::rustup_fallback && return 0
    fi
    # last chance: rustup even when pm install failed outright
    bo_warn "rust toolchain still not usable at >=1.75"
    if bo_confirm "rust is REQUIRED to build memrag (mandatory). Run rustup fallback now?"; then
        prereq::rustup_fallback && return 0
    fi
    if [ "${FLAG_NO_MEMRAG:-0}" = 1 ]; then
        bo_warn "continuing with --no-memrag; cargo build phase will be skipped"
        return 0
    fi
    bo_die "rust >=1.75 unavailable (exit). Either install rustup manually or re-run this installer with --no-memrag to skip the mandatory memrag build."
}

# rustup via https://sh.rustup.rs: download to a file first (NO `curl | bash`).
prereq::rustup_fallback() {
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/bo-rustup.XXXXXX")"
    bo_action "+ curl -fsSL https://sh.rustup.rs -o $tmp/rustup-init.sh"
    [ "$BO_DRY" = 1 ] && return 0
    if ! curl -fsSL https://sh.rustup.rs -o "$tmp/rustup-init.sh"; then
        bo_warn "could not download rustup installer (check network/proxy)"
        BO_PREREQ_INCOMPLETE=1
        return 1
    fi
    if bo_run_script "sh $tmp/rustup-init.sh -y --profile minimal --default-toolchain stable"; then
        export PATH="$HOME/.cargo/bin:$PATH"
        return 0
    fi
    bo_warn "rustup installer returned an error"
    BO_PREREQ_INCOMPLETE=1
    return 1
}

# uv: only needed for --with-wshobson; astral.sh official installer as fallback.
prereq::ensure_uv() {
    if command -v uv >/dev/null 2>&1; then
        bo_action "dependency ok: uv"
        return 0
    fi
    bo_action "missing: uv -> installing via $BO_PREREQ_PM"
    if [ "$BO_PREREQ_PM" != "" ] && prereq::install_pkgs "$BO_PREREQ_PM" "$(prereq::pkg_for "$BO_PREREQ_PM" uv)"; then
        if command -v uv >/dev/null 2>&1; then return 0; fi
    fi
    # fallback: official non-interactive installer script (download -> execute)
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/bo-uv.XXXXXX")"
    bo_action "+ curl -fsSL https://astral.sh/uv/install.sh -o $tmp/uv.sh"
    [ "$BO_DRY" = 1 ] && return 0
    if curl -fsSL https://astral.sh/uv/install.sh -o "$tmp/uv.sh" \
       && bo_run_script "sh $tmp/uv.sh"; then
        if [ -x "$HOME/.local/bin/uv" ]; then
            bo_action "uv installed via astral.sh installer"
            return 0
        fi
    fi
    bo_warn "uv could not be installed automatically; wshobson generation may fail"
    BO_MANUAL_INSTALL_HINTS="${BO_MANUAL_INSTALL_HINTS} [uv]"
    BO_PREREQ_INCOMPLETE=1
    return 1
}

prereq::run() {
    BO_PREREQ_PM="$(prereq::pm_pick)"
    bo_action "package manager selected: ${BO_PREREQ_PM:-NONE} (PKG_ROOT=${BO_PKG_ROOT:-none})"
    if [ -z "$BO_PREREQ_PM" ]; then
        bo_warn "no package manager found; dependencies must already be present"
        BO_PREREQ_INCOMPLETE=1
    fi
    prereq::_jobs_final

    if [ "$BO_DRY" = 1 ]; then
        bo_action "would ensure node>=20, python3>=3.8, curl, git, make, tmux via selected pm"
        bo_action "would enforce cargo/rustc >=1.75 (nixpkgs / distro rust / rustup fallback)"
        [ "${BO_SESSION_TYPE:-}" != headless ] && bo_action "would ensure notify-send (libnotify) for GUI notifications"
        [ "${FLAG_WITH_WSHOBSON:-0}" = 1 ] && bo_action "would ensure uv (needed by the wshobson flow)"
        return 0
    fi

    local dep fail_all=0
    # base set (contract map)
    prereq::ensure node    node    "node>=20 target" || fail_all=1
    prereq::ensure python3 python3 "python >=3.8 target" || fail_all=1
    prereq::ensure curl    curl    "curl" || fail_all=1
    prereq::ensure git     git     "git" || fail_all=1
    prereq::ensure make    make    "make" || fail_all=1
    prereq::ensure tmux    tmux    "tmux" || fail_all=1

    # C compiler (required to link bundled sqlite in the memrag build)
    if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1 && ! command -v clang >/dev/null 2>&1; then
        prereq::ensure cc cc "C compiler" || fail_all=1
    else
        bo_action "dependency ok: C compiler present"
    fi

    # libnotify for desktop notifications (GUI sessions only)
    prereq::ensure_notify || true

    # MUST-compile requirement
    prereq::ensure_rust || fail_all=1

    # re-scan gates so later phases see post-install reality
    detect::gates

    # node version hard gate: >=20 (Context7 integration needs npx)
    if [ "${BO_HAS_NODE:-0}" != 1 ]; then
        bo_warn "node >=20 still missing after install attempt: Context7 integration will be skipped"
        BO_PREREQ_INCOMPLETE=1
    fi
    if [ "${BO_HAS_PY3:-0}" != 1 ]; then
        bo_warn "python3 still missing: manifest/verify helpers and config normalization are degraded"
        BO_PREREQ_INCOMPLETE=1
    fi
    if [ "${BO_HAS_CC:-0}" != 1 ]; then
        bo_warn "no C compiler (cc/gcc/clang) found after install attempt: the memrag build will fail on NixOS/most distros"
        BO_PREREQ_INCOMPLETE=1
    fi

    # optional unit support
    if [ "${FLAG_WITH_WSHOBSON:-0}" = 1 ]; then
        prereq::ensure_uv || fail_all=1
    fi

    if [ "$fail_all" = 1 ]; then
        bo_warn "one or more base dependencies could not be installed automatically [hints>${BO_MANUAL_INSTALL_HINTS:-none}]"
    fi
    export BO_PREREQ_PM BO_PREREQ_INCOMPLETE BO_MANUAL_INSTALL_HINTS
    bo_action "prerequisites phase finished (incomplete=${BO_PREREQ_INCOMPLETE})"
    return 0
}
