#!/bin/sh
# Stop hook: once per session, when the primary usage window crosses the threshold,
# tell Claude to stop and agree a plan with the user instead of ending the turn.
#
#   CONTINUUM_THRESHOLD   percent, default 80
#   CONTINUUM_PROVIDER    which provider to ask, default anthropic
#   CONTINUUM_OFF=1       disable
set -eu

[ -n "${CONTINUUM_OFF:-}" ] && exit 0

LIB="${CLAUDE_PLUGIN_ROOT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/lib/core.sh"
[ -f "$LIB" ] || exit 0
. "$LIB"

event=$(cat)

# Never re-block while Claude is already handling a block (infinite loop guard).
case "$event" in *'"stop_hook_active":true'*) exit 0 ;; esac

sid=$(printf '%s' "$event" | cnt_json_str session_id)
[ -z "$sid" ] && sid=unknown

# A Stop hook that exits non-zero spams the user, so never let a missing dir fail us.
mkdir -p "$CNT_CFG" 2>/dev/null || exit 0

flag="$CNT_CFG/.continuum-warned-$sid"
[ -f "$flag" ] && exit 0                     # warn only once per session

# The hook runs after every turn, but providers hit rate-limited endpoints, so cache
# aggressively and back off after a failure ("negative cache").
cache="$CNT_CFG/.continuum-cache-$CNT_PROVIDER"
failed="$cache.fail"
ttl="${CONTINUUM_CACHE_MIN:-10}"

if [ -f "$failed" ] && [ -n "$(find "$failed" -mmin "-$ttl" 2>/dev/null)" ]; then
    exit 0                                    # recently failed - do not retry yet
fi

if [ -f "$cache" ] && [ -n "$(find "$cache" -mmin "-$ttl" 2>/dev/null)" ]; then
    lines=$(cat "$cache")
else
    # offline / rate limited / no token -> stay silent, remember the failure
    lines=$(cnt_read 2>/dev/null) || { : > "$failed"; exit 0; }
    printf '%s\n' "$lines" > "$cache"
    rm -f "$failed"
fi

# First line is the primary window: <window> <utilization> <reset_epoch>
util=$(printf '%s\n' "$lines" | cnt_field 2)
reset=$(printf '%s\n' "$lines" | cnt_field 3)
[ -z "$util" ] && exit 0

threshold="${CONTINUUM_THRESHOLD:-80}"
util_i=${util%%.*}                            # integer compare (utilization can be "46.0")
case "$util_i" in ''|*[!0-9]*) exit 0 ;; esac
[ "$util_i" -lt "$threshold" ] && exit 0

when=""
[ -n "$reset" ] && [ "$reset" != "-" ] && when=$(cnt_epoch_hhmm "$reset" 2>/dev/null || echo "")

# Any window beyond the first, for context ("weekly window 41.0%").
rest=$(printf '%s\n' "$lines" | awk 'NR>1 {printf "%s window %s%%, ", $1, $2}' | sed 's/, $//')

printf '%s' "$util_i" > "$flag"

# Stop hook contract: {"decision":"block","reason":"..."} feeds the reason back to Claude.
cat <<EOF
{"decision":"block","reason":"[continuum] The primary usage window is ${util_i}% used (threshold ${threshold}%)${when:+, resets at ${when}}${rest:+. Also: ${rest}}. Do not end the turn silently: run the session-budget skill - briefly state where we stopped, then use AskUserQuestion to ask the user how to spend the rest of the window, offering the options from that skill. This warning fires once per session."}
EOF
