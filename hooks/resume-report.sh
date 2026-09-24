#!/bin/sh
# Moved to adapters/claude/resume-report.sh. Kept so existing configs keep working; removed in v0.7.
d="$(dirname "$0")/../adapters/claude"
[ -f "$d/resume-report.sh" ] && exec sh "$d/resume-report.sh"
exit 0
