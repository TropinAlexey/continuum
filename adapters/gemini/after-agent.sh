#!/bin/sh
# Gemini CLI AfterAgent hook. A new tier becomes {"decision":"deny","reason":...}:
# Gemini rejects the final response and sends the reason back as a new prompt, so
# the agent asks the user instead of ending the turn.
set -u
[ -n "${CONTINUUM_OFF:-}" ] && exit 0
. "$(dirname "$0")/../lib.sh" 2>/dev/null || exit 0
root=$(cnt_adapter_root) || exit 0
event=$(cat)
# Never deny again while Gemini is already retrying because of a hook.
cnt_adapter_true "$event" stop_hook_active && exit 0
reason=$(cnt_adapter_warn "$root" "$(cnt_adapter_str "$event" session_id)" gemini) || exit 0
printf '{"decision":"deny","reason":"%s"}\n' "$(cnt_json_escape "$reason")"
