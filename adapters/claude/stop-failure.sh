#!/bin/sh
# Claude Code (and Junie) StopFailure hook, matcher rate_limit: the limit ran out in
# the middle of a turn. A thin adapter: all the logic lives in `continuum limit-hit`.
# StopFailure has no decision control - nothing can be asked or blocked here - so this
# only hands over session, agent and directory. Output is ignored; always exits 0.
#
#   CONTINUUM_RESUME_ON_LIMIT=1, CONTINUUM_NOTIFY_CMD, CONTINUUM_OFF=1 - see
#   `continuum limit-hit` in bin/continuum.
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

printf '%s' "$event" | grep -q '"error"[[:space:]]*:[[:space:]]*"rate_limit"' || exit 0

str() { printf '%s' "$event" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'; }
sid=$(str session_id)

# Junie's events carry project_path and no transcript_path; its cwd is ~/.junie, the
# project is project_path. Claude Code's cwd is the project.
agent=claude; dir=$(str cwd)
if printf '%s' "$event" | grep -q '"project_path"[[:space:]]*:' \
    && ! printf '%s' "$event" | grep -q '"transcript_path"[[:space:]]*:'; then
    agent=junie; dir=$(str project_path)
fi
[ -n "$dir" ] && [ -d "$dir" ] || dir=$PWD

sh "$root/bin/continuum" limit-hit "${sid:-unknown}" "$agent" "$dir" >/dev/null 2>&1 || true
exit 0
