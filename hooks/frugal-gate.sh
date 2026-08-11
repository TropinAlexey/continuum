#!/bin/sh
# PreToolUse hook: when CONTINUUM_FRUGAL=1, block expensive tool calls.
# Blocks: Agent (subagents). Warns on large Read calls.
# Exit 0 with no output = allow. {"decision":"block","reason":"..."} = deny.
set -eu

[ -z "${CONTINUUM_FRUGAL:-}" ] && exit 0

event=$(cat)

tool=$(printf '%s' "$event" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tool_name"[[:space:]]*:[[:space:]]*"//; s/"$//')
[ -z "$tool" ] && exit 0

case "$tool" in
    Agent)
        cat <<'EOF'
{"decision":"block","reason":"[continuum] Frugal mode is active — subagent calls are blocked to conserve budget. Disable with CONTINUUM_FRUGAL= or pick 'Carry on' at the next budget check."}
EOF
        ;;
esac
