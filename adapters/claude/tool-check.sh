#!/bin/sh
# Claude Code PostToolUse hook: the same warning as stop.sh, but in the middle of a turn.
# A long turn (builds, parallel subagents, background reviews) can go from under the
# threshold to the limit without ever reaching Stop. After each tool call this asks
# `continuum check` and, on a new tier, hands Claude the warning as additionalContext.
# Tiers, cache and per-session flags are shared with stop.sh: each tier fires once,
# whichever hook sees it first. The 10-min cache keeps this off the network.
#
#   CONTINUUM_OFF=1 disables it, like every other hook.
set -u

[ -n "${CONTINUUM_OFF:-}" ] && exit 0

# Find the code: explicit env, the plugin root, this checkout, or the pointer the
# CLI leaves in the state dir (for copies living in an agent's config dir).
find_root() {
    for r in "${CONTINUUM_ROOT:-}" "${CLAUDE_PLUGIN_ROOT:-}" "$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)"; do
        [ -n "$r" ] && [ -f "$r/bin/continuum" ] && { printf '%s' "$r"; return 0; }
    done
    if [ -n "${CONTINUUM_STATE_DIR:-}" ]; then s="$CONTINUUM_STATE_DIR"
    elif [ -n "${XDG_STATE_HOME:-}" ]; then s="$XDG_STATE_HOME/continuum"
    else s="$HOME/.local/state/continuum"; fi
    r=$(cat "$s/root" 2>/dev/null) && [ -f "$r/bin/continuum" ] && { printf '%s' "$r"; return 0; }
    return 1
}
root=$(find_root) || exit 0

event=$(cat)

# Inside a subagent there is nobody to ask, and firing there would use up the tier
# before the main conversation sees it. Subagent tool calls carry agent_id.
printf '%s' "$event" | grep -q '"agent_id"[[:space:]]*:' && exit 0

sid=$(printf '%s' "$event" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')

# Runs after every tool call: any failure means silence, never a hook error.
# Junie CLI installs this plugin from the marketplace and runs the same hooks; its
# events carry project_path, Claude Code's do not.
agent=claude
printf '%s' "$event" | grep -q '"project_path"[[:space:]]*:' && agent=junie
# Junie fires PreToolUse but not PostToolUse, so this hook is wired to both; Claude
# Code keeps the PostToolUse one and skips the duplicate.
hook=PostToolUse
printf '%s' "$event" | grep -q '"hook_event_name"[[:space:]]*:[[:space:]]*"PreToolUse"' && hook=PreToolUse
[ "$hook" = PreToolUse ] && [ "$agent" != junie ] && exit 0

reason=$(sh "$root/bin/continuum" check --session "${sid:-unknown}" --agent "$agent" 2>/dev/null) || exit 0
[ -n "$reason" ] || exit 0

reason="Mid-turn usage check. Finish the step you are on and leave the work in a consistent state (commit or a note), then act on this: $reason"

# The provider controls window labels, which end up inside a JSON string. Escape it.
esc_reason=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r')

printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$hook" "$esc_reason"
