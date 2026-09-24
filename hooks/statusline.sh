#!/bin/sh
# Moved to adapters/claude/statusline.sh. Kept so existing configs keep working; removed in v0.7.
d="$(dirname "$0")/../adapters/claude"
[ -f "$d/statusline.sh" ] && exec sh "$d/statusline.sh"
exit 0
