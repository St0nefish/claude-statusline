#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUSLINE_SH="$SCRIPT_DIR/statusline.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"

# ── Colors ────────────────────────────────────────────────────────────────────

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
yellow(){ printf '\033[33m%s\033[0m' "$*"; }
dim()   { printf '\033[2m%s\033[0m' "$*"; }

ok()   { echo "  $(green ✓) $*"; }
warn() { echo "  $(yellow ⚠) $*"; }
fail() { echo "  $(red ✗) $*"; }

# ── Dependency checks ────────────────────────────────────────────────────────

echo "Checking dependencies..."

missing=0

check_tool() {
    local tool="$1" hint="${2:-}"
    if command -v "$tool" &>/dev/null; then
        ok "$tool $(dim "($(command -v "$tool"))")"
    else
        fail "$tool — $hint"
        missing=1
    fi
}

check_tool jq      "install with: apt install jq / brew install jq"
check_tool curl    "install with: apt install curl / brew install curl"
check_tool awk     "should be pre-installed on all systems"
check_tool git     "install with: apt install git / brew install git"

# Optional: gitstatusd for fast git status
platform=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$arch" in
    x86_64)  arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
esac
gitstatusd_bin="$HOME/.cache/gitstatus/gitstatusd-${platform}-${arch}"
if [[ -x "$gitstatusd_bin" ]]; then
    ok "gitstatusd $(dim "(optional, found at $gitstatusd_bin)")"
else
    warn "gitstatusd not found $(dim "(optional — will use git CLI fallback)")"
fi

echo ""

if (( missing )); then
    fail "Missing required dependencies. Install them and re-run."
    exit 1
fi

# ── Cache directory ───────────────────────────────────────────────────────────

echo "Setting up cache directory..."
mkdir -p "$CACHE_DIR"
ok "$CACHE_DIR"
echo ""

# ── Make script executable ────────────────────────────────────────────────────

chmod +x "$STATUSLINE_SH"

# ── Configure Claude settings ────────────────────────────────────────────────

echo "Configuring Claude Code status line..."

if [[ ! -d "$HOME/.claude" ]]; then
    fail "$HOME/.claude does not exist — is Claude Code installed?"
    exit 1
fi

# Build the statusLine object
statusline_json=$(jq -n \
    --arg cmd "bash $STATUSLINE_SH" \
    '{type: "command", command: $cmd, refresh: 150}')

if [[ -f "$SETTINGS_FILE" ]]; then
    # Merge into existing settings
    updated=$(jq --argjson sl "$statusline_json" '.statusLine = $sl' "$SETTINGS_FILE")
    echo "$updated" > "$SETTINGS_FILE.tmp"
    mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
    ok "Updated existing $SETTINGS_FILE"
else
    # Create new settings file with just the statusLine
    jq -n --argjson sl "$statusline_json" '{statusLine: $sl}' > "$SETTINGS_FILE"
    ok "Created $SETTINGS_FILE"
fi

echo ""

# ── Summary ───────────────────────────────────────────────────────────────────

echo "$(green "Done!") claude-statusline is installed."
echo ""
echo "  Script:   $(dim "$STATUSLINE_SH")"
echo "  Cache:    $(dim "$CACHE_DIR")"
echo "  Settings: $(dim "$SETTINGS_FILE")"
echo ""
echo "  $(dim "Optional: copy config.json to")"
echo "  $(dim "${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/config.json")"
echo "  $(dim "to customize segments, colors, and labels.")"
echo ""
