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

# Current month billing
year=$(date -u +%Y)
month=$(date -u +%m)

json=$(curl -fsS -m 15 \
    -H "x-api-key: $ADMIN_KEY" \
    -H "anthropic-version: 2023-06-01" \
    "https://api.anthropic.com/v1/billing/usage?start_date=${year}-${month}-01&end_date=${year}-${month}-31" 2>/dev/null) || {
    echo "billing endpoint unavailable (check ANTHROPIC_ADMIN_KEY)" >&2; exit 1
}

# Extract total cost in dollars from the response
cost=$(printf '%s' "$json" | grep -o '"total_cost"[[:space:]]*:[[:space:]]*[0-9.]*' | head -1 | sed 's/.*:[[:space:]]*//')
[ -z "$cost" ] && cost=0

# utilization = (cost / cap) * 100, done with awk for float math
util=$(awk -v c="$cost" -v cap="$CAP" 'BEGIN { printf "%.1f", (c / cap) * 100 }')

printf 'month %s -\n' "$util"
