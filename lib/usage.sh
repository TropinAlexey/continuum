#!/bin/sh
# Shared helpers: OAuth token lookup, usage fetch, portable date math.
# POSIX sh + curl only. No python, no node, no jq.

USAGE_URL="https://api.anthropic.com/api/oauth/usage"
CLAUDE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# --- token -------------------------------------------------------------
# 1. $CLAUDE_CODE_OAUTH_TOKEN  2. macOS Keychain  3. ~/.claude/.credentials.json
#
# WARNING: this prints your OAuth access token on stdout. Never run it in a shell
# whose output is logged, pasted, or fed to an AI transcript. It exists only so
# cug_fetch can put the token in a curl header. If you want to test the fallback
# chain, set CUG_FIXTURE and call cug_fetch instead - `security` lives in /usr/bin,
# so trimming PATH does *not* disable the Keychain branch.
cug_token() {
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi
    raw=""
    if command -v security >/dev/null 2>&1; then
        raw=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    fi
    if [ -z "$raw" ] && [ -f "$CLAUDE_CFG/.credentials.json" ]; then
        raw=$(cat "$CLAUDE_CFG/.credentials.json")
    fi
    [ -z "$raw" ] && return 1
    printf '%s' "$raw" | cug_json_str accessToken
}

# --- tiny JSON readers (flat scalar extraction, good enough for this API) ---
# cug_json_str KEY  < json   -> first string value for "KEY":"..."
cug_json_str() {
    sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}
# cug_json_num KEY  < json   -> first numeric value for "KEY":123.4
cug_json_num() {
    sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p' | head -1
}
# cug_json_block KEY < json  -> the {...} object that follows "KEY":
cug_json_block() {
    sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*{\([^{}]*\)}.*/\1/p' | head -1
}

# --- usage fetch -------------------------------------------------------
# Prints the usage JSON on stdout. Non-zero exit on any failure (-f: HTTP >=400 too).
# The endpoint rate-limits aggressively - callers must cache (see hooks/token-budget-check.sh).
cug_fetch() {
    if [ -n "${CUG_FIXTURE:-}" ]; then   # tests: read canned JSON instead of the network
        cat "$CUG_FIXTURE"
        return 0
    fi
    tok=$(cug_token) || { echo "no OAuth token found - are you logged in to Claude Code?" >&2; return 1; }
    out=$(curl -fsS -m 15 -H "Authorization: Bearer $tok" \
               -H "anthropic-beta: oauth-2025-04-20" "$USAGE_URL" 2>/dev/null) || {
        echo "usage endpoint unavailable (rate limited, offline, or token expired)" >&2
        return 1
    }
    case "$out" in
        *'"five_hour"'*) printf '%s' "$out" ;;
        *) echo "unexpected response from usage endpoint" >&2; return 1 ;;
    esac
}

# --- portable date math ------------------------------------------------
# cug_iso_epoch "2026-07-09T17:40:00.180+00:00" -> unix epoch (UTC input)
cug_iso_epoch() {
    iso=$(printf '%s' "$1" | sed 's/\..*//; s/Z$//; s/+00:00$//')
    date -u -d "${iso}Z" +%s 2>/dev/null && return 0                       # GNU
    date -u -j -f "%Y-%m-%dT%H:%M:%S" "$iso" +%s 2>/dev/null && return 0   # BSD
    return 1
}

# cug_epoch_hhmm 1783000000 [margin_seconds] -> local HH:MM
cug_epoch_hhmm() {
    e=$(( $1 + ${2:-0} ))
    date -r "$e" +%H:%M 2>/dev/null && return 0    # BSD
    date -d "@$e" +%H:%M 2>/dev/null && return 0   # GNU
    return 1
}

# cug_num 09 -> 9 ; cug_num 00 -> 0   (strip leading zeros without breaking arithmetic)
cug_num() {
    v=$(printf '%s' "$1" | sed 's/^0*//')
    [ -z "$v" ] && v=0
    printf '%s' "$v"
}

# cug_hhmm_delay "19:40" -> seconds until the next occurrence of HH:MM (local)
cug_hhmm_delay() {
    case "$1" in
        [0-9]:[0-9][0-9]|[0-9][0-9]:[0-9][0-9]) ;;
        *) echo "invalid time: $1 (expected HH:MM)" >&2; return 1 ;;
    esac
    h=$(cug_num "${1%%:*}"); m=$(cug_num "${1##*:}")
    if [ "$h" -gt 23 ] || [ "$m" -gt 59 ]; then
        echo "invalid time: $1 (expected HH:MM)" >&2; return 1
    fi
    now=$(date +%s)
    midnight=$(( now - ( $(cug_num "$(date +%H)") * 3600 \
                       + $(cug_num "$(date +%M)") * 60 \
                       + $(cug_num "$(date +%S)") ) ))
    target=$(( midnight + h * 3600 + m * 60 ))
    [ "$target" -le "$now" ] && target=$(( target + 86400 ))  # already passed -> tomorrow
    echo $(( target - now ))
}
