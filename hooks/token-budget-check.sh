#!/bin/sh
# Stop hook: once per session, when the 5-hour usage window crosses the threshold,
# tell Claude to stop and agree a plan with the user instead of ending the turn.
#
#   CLAUDE_USAGE_THRESHOLD   percent, default 80
#   CLAUDE_USAGE_HOOK_OFF=1  disable
set -eu

[ -n "${CLAUDE_USAGE_HOOK_OFF:-}" ] && exit 0

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# lib/ ships next to this hook (plugin install); fall back to a manual ~/.claude copy.
LIB="${CLAUDE_PLUGIN_ROOT:-$CFG}/lib/usage.sh"
[ -f "$LIB" ] || LIB="$CFG/lib/usage.sh"
[ -f "$LIB" ] || exit 0
. "$LIB"

event=$(cat)

# Never re-block while Claude is already handling a block (infinite loop guard).
case "$event" in *'"stop_hook_active":true'*) exit 0 ;; esac

sid=$(printf '%s' "$event" | cug_json_str session_id)
[ -z "$sid" ] && sid=unknown
flag="$CFG/.budget-warned-$sid"
[ -f "$flag" ] && exit 0                     # warn only once per session

# The hook runs after every turn, but the endpoint rate-limits hard, so cache
# aggressively and back off after a failure ("negative cache").
cache="$CFG/.usage-cache.json"
failed="$CFG/.usage-cache.fail"
ttl="${CLAUDE_USAGE_CACHE_MIN:-10}"

# A Stop hook that exits non-zero spams the user, so never let a missing dir fail us.
mkdir -p "$CFG" 2>/dev/null || exit 0

if [ -f "$failed" ] && [ -n "$(find "$failed" -mmin "-$ttl" 2>/dev/null)" ]; then
    exit 0                                    # recently failed - do not retry yet
fi

if [ -f "$cache" ] && [ -n "$(find "$cache" -mmin "-$ttl" 2>/dev/null)" ]; then
    json=$(cat "$cache")
else
    # offline / rate limited / token rotated -> stay silent, remember the failure
    json=$(cug_fetch 2>/dev/null) || { : > "$failed"; exit 0; }
    printf '%s' "$json" > "$cache"
    rm -f "$failed"
fi

five=$(printf '%s' "$json" | cug_json_block five_hour)
[ -z "$five" ] && exit 0
util=$(printf '%s' "$five" | cug_json_num utilization)
[ -z "$util" ] && exit 0

threshold="${CLAUDE_USAGE_THRESHOLD:-80}"
# integer compare (utilization can be "46.0")
util_i=${util%%.*}
[ "$util_i" -lt "$threshold" ] && exit 0

iso=$(printf '%s' "$five" | cug_json_str resets_at)
epoch=$(cug_iso_epoch "$iso" 2>/dev/null) || epoch=""
reset=${epoch:+$(cug_epoch_hhmm "$epoch")}
weekly=$(printf '%s' "$json" | cug_json_block seven_day | cug_json_num utilization)

printf '%s' "$util_i" > "$flag"

# Stop hook contract: {"decision":"block","reason":"..."} feeds the reason back to Claude.
cat <<EOF
{"decision":"block","reason":"[usage] The 5-hour window is ${util_i}% used (threshold ${threshold}%), resets at ${reset:-?}${weekly:+, weekly window ${weekly}%}. Do not end the turn silently: run the session-budget skill - briefly state where we stopped, then use AskUserQuestion to ask the user how to spend the rest of the window, offering the options from that skill. This warning fires once per session."}
EOF
