#!/bin/sh
# Codex CLI Stop hook. A new tier becomes {"decision":"block","reason":...}: Codex
# takes the reason as a continuation prompt and asks the user instead of stopping.
set -u
[ -n "${CONTINUUM_OFF:-}" ] && exit 0
. "$(dirname "$0")/../lib.sh" 2>/dev/null || exit 0
root=$(cnt_adapter_root) || exit 0
event=$(cat)
# Never re-block while Codex is already continuing because of a Stop hook.
cnt_adapter_true "$event" stop_hook_active && exit 0
reason=$(cnt_adapter_warn "$root" "$(cnt_adapter_str "$event" session_id)" codex) || exit 0
printf '{"decision":"block","reason":"%s"}\n' "$(cnt_json_escape "$reason")"
