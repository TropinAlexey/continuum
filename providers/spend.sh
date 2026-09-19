#!/bin/sh
# continuum provider: Anthropic API spend (API-key billing, not subscription).
#
# Emits:
#   month <utilization> -
#
# Uses the Admin API billing endpoint. Requires:
#   ANTHROPIC_ADMIN_KEY   - admin API key
#   CONTINUUM_SPEND_CAP   - monthly budget in dollars (default: 100)
#
# The utilization is (current spend / cap) * 100.
set -eu

. "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}/lib/core.sh"

ADMIN_KEY="${ANTHROPIC_ADMIN_KEY:-}"
[ -z "$ADMIN_KEY" ] && { echo "ANTHROPIC_ADMIN_KEY not set" >&2; exit 1; }

CAP="${CONTINUUM_SPEND_CAP:-100}"
# A non-numeric or non-positive cap would divide by zero (awk prints inf) or
# produce nonsense utilization. Fail fast with a human message.
case "$CAP" in ''|*[!0-9.]*) echo "invalid CONTINUUM_SPEND_CAP='$CAP' (need a positive number)" >&2; exit 1 ;; esac
if ! awk -v cap="$CAP" 'BEGIN{exit !(cap+0 > 0)}'; then
    echo "invalid CONTINUUM_SPEND_CAP='$CAP' (need a positive number)" >&2; exit 1
fi

# Current month billing: end_date is the real last day of the month, not a
# hardcoded 31 (February/April/June/... would query a non-existent date).
year=$(date -u +%Y)
month=$(date -u +%m)
last_day=$(date -u -d "$year-$month-01 +1 month -1 day" +%d 2>/dev/null \
    || date -u -j -f "%Y-%m-%d" "$year-$month-01" -v+1m -v-1d +%d 2>/dev/null \
    || printf '28')
case "$last_day" in ''|*[!0-9]*) last_day=28 ;; esac

json=$(curl -fsS -m 15 \
    -H "x-api-key: $ADMIN_KEY" \
    -H "anthropic-version: 2023-06-01" \
    "https://api.anthropic.com/v1/billing/usage?start_date=${year}-${month}-01&end_date=${year}-${month}-${last_day}" 2>/dev/null) || {
    echo "billing endpoint unavailable (check ANTHROPIC_ADMIN_KEY)" >&2; exit 1
}

# Extract total cost in dollars from the response (allows 1e-5 scientific form).
cost=$(printf '%s' "$json" | grep -o '"total_cost"[[:space:]]*:[[:space:]]*[0-9.eE+-]*' | head -1 | sed 's/.*:[[:space:]]*//')
[ -z "$cost" ] && cost=0
case "$cost" in ''|*[!0-9.eE+-]*) cost=0 ;; esac

# utilization = (cost / cap) * 100, done with awk for float math
util=$(awk -v c="$cost" -v cap="$CAP" 'BEGIN { printf "%.1f", (c / cap) * 100 }')

printf 'month %s -\n' "$util"
