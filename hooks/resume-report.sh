#!/bin/sh
# SessionStart hook: report completed resume runs so the user sees results on session start.
# Reads ~/.claude/continuum-resume.log, finds entries from the last 24h, prints a summary.
set -eu

LOG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/continuum-resume.log"
[ -f "$LOG" ] || exit 0

now=$(date +%s)
cutoff=$((now - 86400))

awk -v cutoff="$cutoff" '
BEGIN { dir=""; started=""; body="" }
/^### [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} - resumed in / {
    started = $2 " " $3
    s = $0; sub(/^### .* - resumed in /, "", s); dir = s
    body = ""
    next
}
/^### end \(exit [0-9]+\)/ {
    if (started == "") next
    s = $0; sub(/.*exit /, "", s); sub(/\).*/, "", s); status = s + 0
    cmd = "date -d \"" started "\" +%s 2>/dev/null || date -j -f \"%Y-%m-%d %H:%M:%S\" \"" started "\" +%s 2>/dev/null"
    cmd | getline epoch
    close(cmd)
    if (epoch + 0 >= cutoff) {
        word = (status == 0) ? "OK" : "FAILED (exit " status ")"
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", body)
        if (length(body) > 200) body = substr(body, 1, 200) "..."
        printf "[continuum] resume %s in %s at %s — %s\n", word, dir, started, body
    }
    started = ""; dir = ""; body = ""
    next
}
started != "" && !/^===/ { body = body " " $0 }
' "$LOG"
