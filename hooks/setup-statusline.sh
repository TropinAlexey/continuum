#!/bin/sh
# Moved to adapters/claude/setup-statusline.sh. Kept so existing configs keep working; removed in v0.7.
d="$(dirname "$0")/../adapters/claude"
[ -f "$d/setup-statusline.sh" ] && exec sh "$d/setup-statusline.sh"
exit 0
