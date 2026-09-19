#!/bin/sh
# SessionStart hook: report completed resume runs so the user sees results on session start.
# Reads ~/.claude/continuum-resume.log, finds entries from the last 24h, prints a summary.
set -eu

LOG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/continuum-resume.log"
[ -f "$LOG" ] || exit 0

now=$(date +%s)
cutoff=$((now - 86400))

awk -v cutoff="$cutoff" -v esc="$(printf '\033')" '
BEGIN { dir=""; started=""; body="" }
# Resume output lands on the user terminal via SessionStart: strip ANSI escape
# sequences and stray control chars so log content cannot restyle output or
# smuggle hyperlinks. Plain text (including UTF-8) passes through untouched.
function clean(s) {
    gsub(esc "\\[[0-9;?]*[A-Za-z]", "", s)  # CSI ... letter (colors, cursor)
    gsub(esc "\\][^\007" esc "]*\007", "", s)  # OSC ... BEL (titles, links)
    gsub(esc "\\][^" esc "]*" esc "\\\\", "", s)  # OSC ... ST (alt terminator)
    gsub(esc "\\\\", "", s)                   # stray ST after ESC
    gsub(esc "[()][0-9A-Za-z]", "", s)       # charset selection
    gsub(esc, "", s)                          # stray ESC
    gsub(/[\001-\010\013\014\016-\037\177]/, "", s)
    return s
}
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
        dir = clean(dir); body = clean(body)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", body)
        if (length(body) > 200) body = substr(body, 1, 200) "..."
        printf "[continuum] resume %s in %s at %s — %s\n", word, dir, started, body
    }
    started = ""; dir = ""; body = ""
    next
}
started != "" && !/^===/ { body = body " " $0 }
' "$LOG"
