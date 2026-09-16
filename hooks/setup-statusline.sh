#!/bin/sh
# SessionStart hook: auto-configure statusLine in settings.json if not already set.
# Runs once — if statusLine exists (ours or another plugin's), does nothing.
set -eu

CNT_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
settings="$CNT_CFG/settings.json"

[ -f "$settings" ] || exit 0
grep -q '"statusLine"' "$settings" && exit 0

# Copy the script if missing (plugin install may not put it in ~/.claude/hooks/)
hooks_dir="$CNT_CFG/hooks"
mkdir -p "$hooks_dir" 2>/dev/null || true
src="${CLAUDE_PLUGIN_ROOT:-$CNT_CFG}/hooks/statusline.sh"
[ -f "$src" ] && cp "$src" "$hooks_dir/statusline.sh" 2>/dev/null || true

# Insert statusLine after the opening brace
awk 'NR==1{print; print "  \"statusLine\": { \"type\": \"command\", \"command\": \"sh \\\"$HOME/.claude/hooks/statusline.sh\\\"\" },"; next}{print}' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"

echo "[continuum] Status line enabled — usage % will appear in the status bar. Restart the session to activate."
