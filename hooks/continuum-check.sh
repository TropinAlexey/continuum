#!/bin/sh
# Stop hook: as the primary usage window fills, tell Claude to stop and agree a plan
# with the user instead of ending the turn. Fires once per tier crossed (80/90/95/99
# by default), not once per turn - escalating, but never nagging: each tier warns once.
#
#   CONTINUUM_THRESHOLD   floor percent, default 80 (tiers at/above it stay active)
#   CONTINUUM_TIERS       space-separated tiers, default "80 90 95 99"
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

# The flag records the highest tier already warned this session, so each tier fires once.
flag="$CNT_CFG/.continuum-warned-$sid"
warned=0
[ -f "$flag" ] && warned=$(cat "$flag")
case "$warned" in ''|*[!0-9]*) warned=0 ;; esac

# The hook runs after every turn, but providers hit rate-limited endpoints, so cache
# aggressively and back off after a failure ("negative cache").
cache="$CNT_CFG/.continuum-cache-$CNT_PROVIDER"
failed="$cache.fail"
ttl="${CONTINUUM_CACHE_MIN:-10}"

# fresh <file> -> true if the file was modified within ttl minutes. ttl=0 disables the
# cache: `find -mmin -0` counts a just-written file as fresh, so guard it explicitly.
fresh() { [ "$ttl" -gt 0 ] && [ -f "$1" ] && [ -n "$(find "$1" -mmin "-$ttl" 2>/dev/null)" ]; }

if fresh "$failed"; then
    exit 0                                    # recently failed - do not retry yet
fi

if fresh "$cache"; then
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

# Highest tier the current utilization has reached (tiers below the floor are ignored).
tier=0
tiers=""                                       # active tiers, for the message
for t in ${CONTINUUM_TIERS:-80 90 95 99}; do
    [ "$t" -lt "$threshold" ] && continue
    tiers="${tiers:+$tiers/}$t"
    [ "$util_i" -ge "$t" ] && [ "$t" -gt "$tier" ] && tier=$t
done
[ "$tier" -eq 0 ] && exit 0                   # below the floor
[ "$tier" -le "$warned" ] && exit 0           # already warned at this tier or higher

when=""
[ -n "$reset" ] && [ "$reset" != "-" ] && when=$(cnt_epoch_hhmm "$reset" 2>/dev/null || echo "")

# Any window beyond the first, for context ("weekly window 41.0%").
rest=$(printf '%s\n' "$lines" | awk 'NR>1 {printf "%s window %s%%, ", $1, $2}' | sed 's/, $//')

printf '%s' "$tier" > "$flag"

# Stop hook contract: {"decision":"block","reason":"..."} feeds the reason back to Claude.
cat <<EOF
{"decision":"block","reason":"[continuum] The primary usage window is ${util_i}% used (crossed the ${tier}% tier)${when:+, resets at ${when}}${rest:+. Also: ${rest}}. Do not end the turn silently: run the session-budget skill - briefly state where we stopped, then use AskUserQuestion to ask the user how to spend the rest of the window, offering the options from that skill. This fires once per tier (${tiers}), so the next warning only comes if usage climbs into the next tier."}
EOF
