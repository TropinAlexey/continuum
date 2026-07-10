#!/bin/sh
# continuum provider: mock. Canned numbers, no network.
#
# This file is both the test rig and the template for new providers. Copy it,
# replace the two `printf` lines with a real lookup, done.
#
#   CONTINUUM_MOCK="86.5 41.0"   utilization of the primary and secondary windows
#   CONTINUUM_MOCK_FAIL=1        pretend the source is unreachable
#
# Usage:
#   CONTINUUM_PROVIDER=mock continuum status
set -eu

. "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}/lib/core.sh"

# A provider that cannot answer prints a human message to stderr, nothing to
# stdout, and exits non-zero. Never guess, never print a fake zero.
[ -n "${CONTINUUM_MOCK_FAIL:-}" ] && { echo "mock: pretending the source is down" >&2; exit 1; }

# Word splitting is the point here: "86.5 41.0" -> two positional params.
# shellcheck disable=SC2086
set -- ${CONTINUUM_MOCK:-86.5 41.0}
primary="$1"
secondary="${2:-}"

now=$(date +%s)

# <window> <utilization> <reset_epoch>   -- first line is the one the hook watches.
printf '5h %s %s\n' "$primary" "$(( now + 3600 ))"
[ -n "$secondary" ] && printf '7d %s %s\n' "$secondary" "$(( now + 4 * 86400 ))"

exit 0
