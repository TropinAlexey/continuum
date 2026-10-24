#!/bin/sh
# Cursor postToolUse hook: the same warning in the middle of a turn, injected after
# the tool result as additional_context. Tiers are shared with stop.sh.
set -u
[ -n "${CONTINUUM_OFF:-}" ] && exit 0
. "$(dirname "$0")/../lib.sh" 2>/dev/null || exit 0
root=$(cnt_adapter_root) || exit 0
event=$(cat)
reason=$(cnt_adapter_warn "$root" "$(cnt_adapter_str "$event" conversation_id)" cursor) || exit 0
printf '{"additional_context":"%s"}\n' "$(cnt_json_escape "$CNT_MIDTURN_PREFIX$reason")"
