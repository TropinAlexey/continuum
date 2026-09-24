#!/bin/sh
# Moved to adapters/claude/frugal-gate.sh. Kept so existing configs keep working; removed in v0.7.
d="$(dirname "$0")/../adapters/claude"
[ -f "$d/frugal-gate.sh" ] && exec sh "$d/frugal-gate.sh"
exit 0
