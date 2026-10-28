#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# better-opencode :: lib/integrate.sh  (phase 6: INTEGRATIONS)
#
# 1) Context7 MCP (unless --skip-context7 or node < 20):
#      npx -y ctx7 setup --opencode --mcp --yes
#    That CLI's older shape writes `mcp.context7` directly at the JSON root;
#    if such a sibling key exists afterwards we NORMALIZE it into
#    `mcp.servers.context7` (moving type/url/headers) with an inline python
#    snippet, then record the modified file in the manifest.
#    The device-code OAuth flow prints a one-time code on the terminal.
#
# 2) REA reverse-engineering stack (only with --with-rea):
#      npm -g rea-agents   +   rea setup --client opencode
#    aarch64 note: REA historically had android-arm issues; warn on ARM64.
# ---------------------------------------------------------------------------
set -euo pipefail

integrate::node_ok() {
    [ "${BO_HAS_NODE:-0}" = 1 ]
}

normalize_opencode_json() {
    python3 - "$CONFIG_DIR/opencode.json" <<'PY'
import json, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    d = json.load(f)

mcp = d.get("mcp")
if not isinstance(mcp, dict):
    print("no mcp section: nothing to normalize")
    sys.exit(0)

c7 = mcp.get("context7")
if not isinstance(c7, dict):
    print("no v1 mcp.context7 sibling at root: nothing to normalize")
    sys.exit(0)

servers = mcp.get("servers")
if not isinstance(servers, dict):
    servers = {}
    mcp["servers"] = servers

merged = servers.get("context7") or {}
# preserve type/url/headers from the v1 shape
merged.update({k: v for k, v in c7.items()})
servers["context7"] = merged

# delete the v1 sibling at mcp.context7 (keep mcp itself)
del mcp["context7"]
# avoid an empty mcp dict
if not mcp:
    d.pop("mcp", None)

with open(path, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2)
    f.write("\n")

print("normalized: mcp.context7 -> mcp.servers.context7 (type/url/headers preserved)")
PY
}

# File fingerprint used to notice config changes made by third-party CLIs.
integrate::_fingerprint() {
    if [ -f "$CONFIG_DIR/opencode.json" ]; then
        sha256sum "$CONFIG_DIR/opencode.json" 2>/dev/null | awk '{print $1}'
    fi
    return 0
}

integrate::context7() {
    if [ "${FLAG_SKIP_CONTEXT7:-0}" = 1 ]; then
        bo_action "Context7 integration skipped (--skip-context7)"
        return 0
    fi
    if ! integrate::node_ok; then
        bo_action "Context7 integration skipped: node >=20 / npx required (see SYSTEM STUDY)"
        return 0
    fi
    if [ "$BO_DRY" = 1 ]; then
        bo_action "would run: npx -y ctx7 setup --opencode --mcp --yes"
        bo_action "watch the terminal for a one-time code (device-code OAuth)"
        bo_action "would normalize v1 mcp.context7 -> mcp.servers.context7 if created"
        return 0
    fi
    echo "[better-opencode] NOTE: Context7 uses device-code OAuth; watch the terminal for a one-time code."
    if ! bo_run_script "npx -y ctx7 setup --opencode --mcp --yes"; then
        bo_warn "Context7 setup command failed (network/OAuth or CLI changed)."
        bo_warn "re-run install.sh later without --skip-context7, or configure mcp.servers.context7 manually in $CONFIG_DIR/opencode.json"
        return 1
    fi
    # normalize the v1 shape if the CLI created it
    if [ ! -f "$CONFIG_DIR/opencode.json" ]; then
        bo_warn "$CONFIG_DIR/opencode.json not found after Context7 setup; nothing to normalize"
        return 1
    fi
    if [ "${BO_HAS_PY3:-0}" = 1 ]; then
        local norm_out
        if norm_out="$(normalize_opencode_json)"; then
            bo_action "opencode.json post-process: ${norm_out}"
        else
            bo_warn "opencode.json normalization failed (invalid JSON? inspect manually)"
        fi
    else
        bo_warn "python3 unavailable: skipping mcp.context7 -> mcp.servers.context7 normalization"
    fi
    bo_record "$CONFIG_DIR/opencode.json"
    return 0
}

integrate::rea() {
    if ! integrate::node_ok || ! command -v npm >/dev/null 2>&1; then
        bo_warn "--with-rea requested but npm (node>=20) is missing; skipping REA install"
        return 1
    fi
    # honest hardware note per contract
    case "${BO_ARCH:-}" in
        aarch64|arm64)
            bo_warn "arch ${BO_ARCH}: REA historically had android-arm issues; installing anyway per request"
            ;;
    esac
    if [ "$BO_DRY" = 1 ]; then
        bo_action "would run: npm install -g rea-agents"
        bo_action "would run: rea setup --client opencode"
        return 0
    fi
    # record any config change the CLI performs (third-party writes we trigger)
    local fp_before fp_after
    fp_before="$(integrate::_fingerprint)"
    if ! command -v rea >/dev/null 2>&1; then
        if ! bo_run npm install -g rea-agents; then
            bo_warn "npm install -g rea-agents failed (global permissions? try: sudo npm i -g rea-agents)"
            BO_PREREQ_INCOMPLETE=1
            return 1
        fi
    else
        bo_action "rea CLI already present: skipping npm -g rea-agents"
    fi
    if command -v rea >/dev/null 2>&1; then
        if bo_run rea setup --client opencode; then
            fp_after="$(integrate::_fingerprint)"
            if [ -n "$fp_after" ] && [ "$fp_before" != "$fp_after" ]; then
                bo_action "rea setup modified $CONFIG_DIR/opencode.json"
                bo_record "$CONFIG_DIR/opencode.json"
            fi
            return 0
        fi
        bo_warn "rea setup --client opencode failed (non-fatal; run manually later)"
        return 1
    fi
    bo_warn "rea CLI not found after npm install; check npm global prefix"
    return 1
}

integrate::run() {
    integrate::context7 || true
    if [ "${FLAG_WITH_REA:-0}" = 1 ]; then
        integrate::rea || true
    else
        bo_action "REA stack not requested (pass --with-rea to opt in)"
    fi
    return 0
}
