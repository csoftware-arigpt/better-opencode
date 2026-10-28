#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# better-opencode :: lib/build.sh
#
# Two responsibilities:
#   Phase 3 (mandatory): build::mandatory  -> vendored Rust memrag CLI
#   Phase 4 (optional):  build::wshobson   -> wshobson pack, runs AFTER config
#                           install; consent = --with-wshobson flag or an
#                           interactive [y/N] ask in install.sh
#
# memrag layout: vendor/opencode-memory-rag/rust/Cargo.toml; a successful
# `cargo build --release` produces vendor/opencode-memory-rag/rust/target/
# release/memrag, which is symlinked to $BIN_DIR/memrag.
#
# Known NixOS quirk: without a `cc` wrapper on PATH the vendored crate fails
# (zerocopy build scripts). When no C compiler is present on a NixOS-ish
# system, the build is wrapped in `nix-shell -p gcc cargo --run '...'`.
# ---------------------------------------------------------------------------
set -euo pipefail

BO_WSHOBSON_DONE=0
WSHOBSON_REPO="${HOME}/projects/agents-community"
WSHOBSON_PLUGINS="python-development javascript-typescript developer-essentials security-scanning unit-testing code-refactoring debugging-toolkit comprehensive-review"

# Which C compiler (if any) is on PATH; echo "none" when absent.
build::cc_or_none() {
    local _c
    for _c in cc gcc clang; do
        if command -v "$_c" >/dev/null 2>&1; then echo "$_c"; return; fi
    done
    echo none
}

# Smoke-test a built memrag binary. First try --help; if that fails, retry
# `stats` with MEMRAG_DIR pointing at a fresh temp dir (a missing MEMRAG_DIR
# may be the only reason for failure). Returns 0 when either succeeds.
build::memrag_smoke() {
    local bin="$1"
    if "$bin" --help >/dev/null 2>&1; then
        echo "help"
        return 0
    fi
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/bo-memrag-smoke.XXXXXX")"
    if MEMRAG_DIR="$tmp" "$bin" stats >/dev/null 2>&1; then
        echo "tmpdir"
        return 0
    fi
    return 1
}

# Phase 3a entry: optional units. Default install = nothing here.
build::optional_units() {
    if [ "${FLAG_WITH_WSHOBSON:-0}" = 1 ]; then
        bo_action "optional unit: wshobson community agents pack (clone -> generate -> sanitize -> install)"
        build::wshobson
        BO_WSHOBSON_DONE=1
    else
        bo_action "no optional units requested (pass --with-wshobson to opt in)"
    fi
    return 0
}

# After CONFIG INSTALL re-entry point (phase 5b): if the flow already ran in
# 3a, only re-verify; otherwise run it now (files land after config exists).
build::wshobson_after_config() {
    if [ "$BO_WSHOBSON_DONE" = 1 ]; then
        bo_action "wshobson flow already detected as complete: re-verifying counts"
        build::wshobson_verify
    else
        build::wshobson
        BO_WSHOBSON_DONE=1
    fi
    return 0
}

# ---- wshobson flow ----------------------------------------------------------
build::wshobson_new_link_snapshot() {
    local d out=""
    for d in "$CONFIG_DIR/agents" "$CONFIG_DIR/skills" "$CONFIG_DIR/commands"; do
        [ -d "$d" ] || continue
        while IFS= read -r -d '' l; do
            printf '%s -> %s\n' "$l" "$(readlink -f "$l" 2>/dev/null || readlink "$l" 2>/dev/null || echo '?')"
        done < <(find "$d" -maxdepth 2 -type l -print0 2>/dev/null)
    done
}

build::wshobson() {
    if [ "$BO_DRY" = 1 ]; then
        bo_action "would git clone --depth 1 https://github.com/wshobson/agents -> $WSHOBSON_REPO (skipped if dir exists)"
        bo_action "would run: uv run --project plugins/plugin-eval python tools/generate.py --harness opencode --plugin <p> for: $WSHOBSON_PLUGINS"
        bo_action "would sanitize .opencode/agents/*.md (drop '^model: anthropic/' lines)"
        bo_action "would run python3 tools/install_opencode.py install + verify 17 agents / 36 skills / 12 commands"
        return 0
    fi
    if ! command -v git >/dev/null 2>&1; then
        bo_warn "git missing: cannot obtain wshobson pack (skipping)"
        return 1
    fi
    if [ ! -d "$WSHOBSON_REPO" ]; then
        if [ "$BO_DRY" = 1 ]; then
            bo_action "would mkdir -p $HOME/projects"
        else
            mkdir -p "$HOME/projects"
        fi
        if bo_run git clone --depth 1 https://github.com/wshobson/agents "$WSHOBSON_REPO"; then
            bo_record "$WSHOBSON_REPO"
        else
            bo_warn "git clone failed (network?); skipping wshobson unit"
            return 1
        fi
    else
        bo_action "$WSHOBSON_REPO already exists: reusing it as-is (no pull)"
    fi

    # 1) generate per-plugin harness output
    local p pdir failed=0
    for p in $WSHOBSON_PLUGINS; do
        pdir="$WSHOBSON_REPO/plugins/$p"
        if [ ! -d "$pdir" ]; then
            bo_warn "upstream layout changed: plugins/$p not found in repo; skipping it"
            failed=1
            continue
        fi
        bo_action "generating plugin: $p"
        if ! (cd "$WSHOBSON_REPO" && bo_run_script "uv run --project plugins/plugin-eval python tools/generate.py --harness opencode --plugin $p"); then
            bo_warn "generation failed for plugin $p (see output above)"
            failed=1
        fi
    done

    # 2) sanitize: remove faction-pinned model lines from generated agents
    if compgen -G "$WSHOBSON_REPO/.opencode/agents/*.md" >/dev/null; then
        local _f _sx=""
        if sed --version >/dev/null 2>&1; then _sx="gnu"; else _sx="bsd"; fi
        for _f in "$WSHOBSON_REPO/.opencode/agents/"*.md; do
            bo_action "sanitize: $_f (drop ^model: anthropic/ lines)"
            [ "$BO_DRY" = 1 ] && continue
            if [ "$_sx" = gnu ]; then
                sed -i '/^model: anthropic\//d' "$_f"
            else
                sed -i '' '/^model: anthropic\//d' "$_f"
            fi
        done
    fi

    # 3) install into config dir (upstream installer; we diff symlinks itself)
    local _before _after _new _src
    _before="$(build::wshobson_new_link_snapshot | sort)" || true
    if ! (cd "$WSHOBSON_REPO" && bo_run python3 tools/install_opencode.py install); then
        bo_warn "tools/install_opencode.py install failed; verify skipped"
        return 1
    fi
    _after="$(build::wshobson_new_link_snapshot | sort)" || true
    _new="$(mktemp -d "${TMPDIR:-/tmp}/bo-manifest.XXXXXX")"
    printf '%s\n' "$_before" | sort > "$_new/before"
    printf '%s\n' "$_after" | sort > "$_new/after"
    comm -13 "$_new/before" "$_new/after" | awk '{print $1}' | while IFS= read -r _src; do
        [ -z "$_src" ] && continue
        bo_record "$_src"
    done
    rm -rf "$_new"
    bo_action "wshobson install step complete (new links recorded in manifest)"

    # 4) count verification
    build::wshobson_verify || true
    return 0
}

# verify 17 agents / 36 skills / 12 commands symlinked into the config dir
build::wshobson_verify() {
    local a=0 s=0 c=0 d
    for d in agents skills commands; do
        [ -d "$CONFIG_DIR/$d" ] || continue
        while IFS= read -r -d '' l; do
            if [ -n "$(readlink "$l" 2>/dev/null || echo "")" ]; then
                case "$d" in agents) a=$((a+1)) ;; skills) s=$((s+1)) ;; commands) c=$((c+1)) ;; esac
            fi
        done < <(find "$CONFIG_DIR/$d" -maxdepth 1 -type l -print0 2>/dev/null)
    done
    bo_action "wshobson symlinks: agents=$a (expect 17) skills=$s (expect 36) commands=$c (expect 12)"
    if [ "$a" -ne 17 ] || [ "$s" -ne 36 ] || [ "$c" -ne 12 ]; then
        bo_warn "wshobson counts differ from the documented 17/36/12 (upstream content may have changed; informational, not fatal)"
    fi
    return 0
}

# ---- phase 4: mandatory build ----------------------------------------------
build::mandatory() {
    local rust_dir="$BO_ROOT/vendor/opencode-memory-rag/rust"
    local bin_rel="target/release/memrag"
    local bin_abs="$rust_dir/$bin_rel"
    local link="$BIN_DIR/memrag"

    if [ "${FLAG_NO_MEMRAG:-0}" = 1 ]; then
        bo_action "skipping memrag build (--no-memrag): the memory-rag plugin and memrag CLI stay unusable until built manually"
        bo_action "manual path: (cd $rust_dir && cargo build --release) then linked into $BIN_DIR"
        return 0
    fi

    if [ "$BO_DRY" = 1 ]; then
        if [ -x "$bin_abs" ]; then
            bo_action "binary already exists at $bin_abs; a real run would reuse it (use --force to rebuild)"
        else
            bo_action "would cargo build --release -j ${BO_BUILD_JOBS:-8} in $rust_dir"
            bo_action "would symlink $bin_abs -> $link"
            bo_action "would smoke-test the binary (help / MEMRAG_DIR=tmpdir stats)"
        fi
        return 0
    fi

    if ! [ -d "$rust_dir" ] || ! [ -f "$rust_dir/Cargo.toml" ]; then
        bo_die "mandatory build failed: vendored rust crate missing at $rust_dir (tree incomplete?)"
    fi
    if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
        bo_die "cargo/rustc unavailable. This build is mandatory; re-run install.sh with --no-memrag to skip, or install a Rust toolchain >=1.75 and re-run."
    fi
    if [ "$BO_HAS_CC" != 1 ]; then
        bo_warn "no C compiler on PATH; the vendored crate needs one to link bundled sqlite"
    fi

    bo_mkdir "$(dirname "$link")"   # real mode here (dry-run returned earlier)

    # reuse an already-built binary unless --force
    if [ -x "$bin_abs" ] && [ "${FLAG_FORCE:-0}" != 1 ]; then
        bo_action "$bin_abs already exists: reusing (pass --force to rebuild)"
    else
        local cc_cmd
        cc_cmd="$(build::cc_or_none)"
        local jobs="${BO_BUILD_JOBS:-8}"
        if [ "${BO_IS_NIXOS:-no}" = yes ] && [ "$cc_cmd" = none ]; then
            bo_action "compiling memrag inside nix-shell -p gcc cargo (NixOS without cc wrapper)"
            if ! (cd "$rust_dir" && nix-shell -p gcc cargo --run "cargo build --release -j $jobs"); then
                bo_die "mandatory build failed (nix-shell cargo). Inspect the error above; aborting install. Escape hatch: re-run with --no-memrag."
            fi
        else
            bo_action "compiling memrag: cargo build --release -j $jobs (C compiler: $cc_cmd)"
            if ! (cd "$rust_dir" && cargo build --release -j "$jobs"); then
                bo_die "mandatory build failed (cargo). Inspect the error above; aborting install. Escape hatch: re-run with --no-memrag."
            fi
        fi
        bo_action "cargo build finished OK"
    fi

    if [ ! -x "$bin_abs" ]; then
        bo_die "mandatory build failed: $bin_abs not found after build; aborting install. Escape hatch: re-run with --no-memrag."
    fi

    # smoke test before exposing it via symlink
    local smoke_out
    if ! smoke_out="$(build::memrag_smoke "$bin_abs")"; then
        bo_die "mandatory build succeeded but the memrag binary failed its smoke test; aborting install. Escape hatch: re-run with --no-memrag."
    fi
    bo_action "memrag smoke test OK (mode: $smoke_out)"

    if bo_run ln -sfn "$bin_abs" "$link"; then
        bo_record "$bin_abs"
        bo_record "$link"
        chmod 755 "$bin_abs" 2>/dev/null || true
    else
        bo_die "could not create symlink $link -> $bin_abs"
    fi
    return 0
}
