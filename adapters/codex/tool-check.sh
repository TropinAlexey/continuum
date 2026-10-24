#!/bin/sh
# Codex CLI PostToolUse hook: the same warning in the middle of a turn, as
# hookSpecificOutput.additionalContext. Never blocks. Tiers are shared with stop.sh.
set -u
[ -n "${CONTINUUM_OFF:-}" ] && exit 0
. "$(dirname "$0")/../lib.sh" 2>/dev/null || exit 0
root=$(cnt_adapter_root) || exit 0
event=$(cat)
reason=$(cnt_adapter_warn "$root" "$(cnt_adapter_str "$event" session_id)" codex) || exit 0
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$(cnt_json_escape "$CNT_MIDTURN_PREFIX$reason")"
