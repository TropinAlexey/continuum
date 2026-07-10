#!/bin/sh
# continuum provider: Anthropic (Claude Code subscription windows).
#
# Emits:
#   5h <utilization> <reset_epoch>
#   7d <utilization> <reset_epoch>
#
# Reads https://api.anthropic.com/api/oauth/usage - the endpoint behind `/usage`.
# It is NOT a public API and may change without notice. Nothing is sent anywhere
# except that host, and only as an Authorization header.
set -eu

. "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}/lib/core.sh"

USAGE_URL="https://api.anthropic.com/api/oauth/usage"

# --- token -------------------------------------------------------------
# 1. $CLAUDE_CODE_OAUTH_TOKEN  2. macOS Keychain  3. ~/.claude/.credentials.json
#
# WARNING: prints your OAuth access token on stdout. Never run it in a shell whose
# output is logged, pasted, or fed to an AI transcript. To exercise the fallback
# chain, use the `mock` provider instead - `security` lives in /usr/bin, so trimming
# PATH does *not* disable the Keychain branch.
_token() {
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN"; return 0
    fi
    raw=""
    if command -v security >/dev/null 2>&1; then
        raw=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || raw=""
    fi
    if [ -z "$raw" ] && [ -f "$CNT_CFG/.credentials.json" ]; then
        raw=$(cat "$CNT_CFG/.credentials.json")
    fi
    [ -z "$raw" ] && return 1
    printf '%s' "$raw" | cnt_json_str accessToken
}

tok=$(_token) || { echo "no OAuth token found - are you logged in to Claude Code?" >&2; exit 1; }

json=$(curl -fsS -m 15 -H "Authorization: Bearer $tok" \
            -H "anthropic-beta: oauth-2025-04-20" "$USAGE_URL" 2>/dev/null) || {
    echo "usage endpoint unavailable (rate limited, offline, or token expired)" >&2; exit 1
}

case "$json" in
    *'"five_hour"'*) ;;
    *) echo "unexpected response from usage endpoint" >&2; exit 1 ;;
esac

emit() {  # emit <label> <json_key>
    block=$(printf '%s' "$json" | cnt_json_block "$2")
    [ -z "$block" ] && return 0
    util=$(printf '%s' "$block" | cnt_json_num utilization)
    [ -z "$util" ] && return 0
    iso=$(printf '%s' "$block" | cnt_json_str resets_at)
    epoch=$(cnt_iso_epoch "$iso" 2>/dev/null) || epoch="-"
    printf '%s %s %s\n' "$1" "$util" "${epoch:--}"
}

emit 5h five_hour
emit 7d seven_day
