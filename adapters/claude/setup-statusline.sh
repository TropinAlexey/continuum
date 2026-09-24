#!/bin/sh
# Claude Code SessionStart hook: keep the status line wired up.
#   - records where the code lives (the plugin cache path changes on every update),
#     so the copy in ~/.claude/hooks/ can find it with no environment;
#   - refreshes that copy when it is ours and out of date;
#   - adds statusLine to settings.json once, if no statusLine is set (ours or anyone's).
set -eu

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
settings="$CLAUDE_DIR/settings.json"
src="$(cd "$(dirname "$0")" && pwd)/statusline.sh"

root="${CONTINUUM_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}}"
if [ -f "$root/lib/core.sh" ]; then
    (CNT_ROOT="$root" . "$root/lib/core.sh" && cnt_set_root_pointer) 2>/dev/null || true
fi

copy="$CLAUDE_DIR/hooks/statusline.sh"
if [ -f "$copy" ] && [ -f "$src" ] && grep -q continuum "$copy" 2>/dev/null && ! cmp -s "$src" "$copy"; then
    cp "$src" "$copy" 2>/dev/null || true
fi

[ -f "$settings" ] || exit 0
grep -q '"statusLine"' "$settings" && exit 0

mkdir -p "$CLAUDE_DIR/hooks" 2>/dev/null || true
[ -f "$src" ] && cp "$src" "$copy" 2>/dev/null || true

# Insert statusLine after the opening brace
awk 'NR==1{print; print "  \"statusLine\": { \"type\": \"command\", \"command\": \"sh \\\"$HOME/.claude/hooks/statusline.sh\\\"\" },"; next}{print}' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"

echo "[continuum] Status line enabled — usage % will appear in the status bar. Restart the session to activate."
