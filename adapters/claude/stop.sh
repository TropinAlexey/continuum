#!/bin/sh
# Claude Code Stop hook. A thin adapter: all the logic (tiers, cache, flags, wording)
# lives in `continuum check`. This only translates Claude's event into its arguments,
# and its warning into a blocking reply, so Claude stops and agrees a plan with the user.
#
#   CONTINUUM_THRESHOLD, CONTINUUM_TIERS, CONTINUUM_PROVIDER, CONTINUUM_OFF=1 - see
#   `continuum check` in bin/continuum.
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

# Never re-block while Claude is already handling a block (infinite loop guard).
printf '%s' "$event" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true' && exit 0

sid=$(printf '%s' "$event" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')

# A Stop hook that exits non-zero spams the user: any failure means silence.
reason=$(sh "$root/bin/continuum" check --session "${sid:-unknown}" --agent claude 2>/dev/null) || exit 0
[ -n "$reason" ] || exit 0

# The provider controls window labels, which end up inside `reason`, which ends up
# inside a JSON string. Escape it: an unescaped quote would emit invalid JSON.
esc_reason=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r')

printf '{"decision":"block","reason":"%s"}\n' "$esc_reason"
