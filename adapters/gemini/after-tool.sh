#!/bin/sh
# Gemini CLI AfterTool hook: the same warning in the middle of a turn, appended to
# the tool result as hookSpecificOutput.additionalContext. Never hides the result.
set -u
[ -n "${CONTINUUM_OFF:-}" ] && exit 0
. "$(dirname "$0")/../lib.sh" 2>/dev/null || exit 0
root=$(cnt_adapter_root) || exit 0
event=$(cat)
reason=$(cnt_adapter_warn "$root" "$(cnt_adapter_str "$event" session_id)" gemini) || exit 0
printf '{"hookSpecificOutput":{"hookEventName":"AfterTool","additionalContext":"%s"}}\n' "$(cnt_json_escape "$CNT_MIDTURN_PREFIX$reason")"
