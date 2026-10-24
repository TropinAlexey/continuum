#!/bin/sh
# Cursor stop hook. A new tier becomes {"followup_message":...}: Cursor submits it
# as the next user message, so the agent goes on and asks the user.
set -u
[ -n "${CONTINUUM_OFF:-}" ] && exit 0
. "$(dirname "$0")/../lib.sh" 2>/dev/null || exit 0
root=$(cnt_adapter_root) || exit 0
event=$(cat)
# Only after a turn that completed, and never inside our own follow-up loop.
case "$(cnt_adapter_str "$event" status)" in ''|completed) ;; *) exit 0 ;; esac
[ "$(cnt_adapter_num "$event" loop_count)" -gt 0 ] 2>/dev/null && exit 0
reason=$(cnt_adapter_warn "$root" "$(cnt_adapter_str "$event" conversation_id)" cursor) || exit 0
printf '{"followup_message":"%s"}\n' "$(cnt_json_escape "$reason")"
