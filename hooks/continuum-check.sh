#!/bin/sh
# Moved to adapters/claude/stop.sh. Kept so existing configs keep working; removed in v0.7.
d="$(dirname "$0")/../adapters/claude"
[ -f "$d/stop.sh" ] && exec sh "$d/stop.sh"
exit 0
