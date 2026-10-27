#!/bin/sh
# continuum provider: OpenRouter key budget (any agent that routes through OpenRouter).
#
# Emits one line:
#   <window> <utilization> <reset_epoch|->
# window is day / week / month when the key's limit resets on that schedule, key otherwise.
#
#   OPENROUTER_API_KEY        - the key (required; read from nowhere else)
#   CONTINUUM_OPENROUTER_CAP  - budget in dollars for a key without a limit
#   OPENROUTER_API_BASE       - https://... or file://... (tests: recorded responses)
#
# Uses the documented GET /api/v1/key. The key goes only to that host.
set -eu

. "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}/lib/core.sh"

KEY="${OPENROUTER_API_KEY:-}"
[ -z "$KEY" ] && { echo "OPENROUTER_API_KEY not set" >&2; exit 1; }
BASE="${OPENROUTER_API_BASE:-https://openrouter.ai/api/v1}"
case "$BASE" in https://*|file://*) ;; *) echo "OPENROUTER_API_BASE must be https:// or file://" >&2; exit 1 ;; esac

json=$(curl -fsS -m 15 -H "Authorization: Bearer $KEY" "$BASE/key" 2>/dev/null) || {
    echo "openrouter: /key unavailable (offline, or the key is invalid)" >&2; exit 1
}

num() { printf '%s' "$json" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*-\{0,1\}[0-9][0-9.eE+-]*" | head -1 | sed 's/.*:[[:space:]]*//'; }
str() { printf '%s' "$json" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'; }

usage=$(num usage); limit=$(num limit); remaining=$(num limit_remaining); period=$(str limit_reset)
[ -n "$usage" ] || { echo "openrouter: unexpected response (no usage)" >&2; exit 1; }

now=$(date -u +%s)
# Next reset at UTC midnight / Monday 00:00 / the 1st, from today's UTC date.
midnight=$(( now - now % 86400 + 86400 ))
case "$period" in
    daily)   window=day;   reset=$midnight ;;
    weekly)  window=week;  dow=$(date -u +%u); reset=$(( midnight + (7 - dow) * 86400 )) ;;
    monthly) window=month
             dom=$(date -u +%d); dom=$(cnt_num "$dom"); y=$(date -u +%Y); m=$(cnt_num "$(date -u +%m)")
             case $m in 1|3|5|7|8|10|12) dim=31 ;; 4|6|9|11) dim=30 ;;
                 2) if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then dim=29; else dim=28; fi ;; esac
             reset=$(( midnight + (dim - dom) * 86400 )) ;;
    *)       window=key;   reset=- ;;
esac

if [ -n "$limit" ] && awk -v l="$limit" 'BEGIN { exit !(l + 0 > 0) }'; then
    if [ -n "$remaining" ]; then
        util=$(awk -v l="$limit" -v r="$remaining" 'BEGIN { u = (l - r) / l * 100; if (u < 0) u = 0; printf "%.1f", u }')
    else
        util=$(awk -v l="$limit" -v u="$usage" 'BEGIN { printf "%.1f", u / l * 100 }')
    fi
else
    CAP="${CONTINUUM_OPENROUTER_CAP:-}"
    case "$CAP" in ''|*[!0-9.]*) echo "openrouter: the key has no limit; set CONTINUUM_OPENROUTER_CAP to a budget in dollars" >&2; exit 1 ;; esac
    awk -v c="$CAP" 'BEGIN { exit !(c + 0 > 0) }' || { echo "invalid CONTINUUM_OPENROUTER_CAP='$CAP' (need a positive number)" >&2; exit 1; }
    window=key; reset=-
    util=$(awk -v c="$CAP" -v u="$usage" 'BEGIN { printf "%.1f", u / c * 100 }')
fi

printf '%s %s %s\n' "$window" "$util" "$reset"
