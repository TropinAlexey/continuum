#!/bin/sh
# Claude Code SessionStart hook: report completed resume runs so the user sees results
# on session start. Reads continuum-resume.log in the continuum state dir, finds entries
# from the last 24h, prints a summary.
# Also checks for pending resumes (scheduled but not yet executed) for this project
# and executes them if their scheduled time has passed (handles compaction/new session).
set -eu

# Load the core when we can: it resolves the state dir and runs the one-time
# migration from ~/.claude, so the first session after an upgrade still reports.
root="${CONTINUUM_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}}"
if [ -f "$root/lib/core.sh" ]; then
    CNT_ROOT="$root" . "$root/lib/core.sh"
elif [ -n "${CONTINUUM_STATE_DIR:-}" ]; then CNT_STATE="$CONTINUUM_STATE_DIR"
elif [ -n "${XDG_STATE_HOME:-}" ]; then CNT_STATE="$XDG_STATE_HOME/continuum"
else CNT_STATE="$HOME/.local/state/continuum"; fi

LOG="$CNT_STATE/continuum-resume.log"

# Get current project directory from the event (cwd, project_path, or transcript_path)
event=$(cat 2>/dev/null || true)
proj_dir=""
if [ -n "$event" ]; then
    # Try cwd first (Claude Code - this is the actual project directory)
    proj_dir=$(printf '%s' "$event" | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')
    # Fallback to project_path (Junie)
    [ -z "$proj_dir" ] && proj_dir=$(printf '%s' "$event" | grep -o '"project_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')
    # Fallback to transcript_path (last resort, extract project from it)
    [ -z "$proj_dir" ] && proj_dir=$(printf '%s' "$event" | grep -o '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//; s|/[^/]*$||; s|/[^/]*$||; s|/[^/]*$||')
fi
[ -z "$proj_dir" ] && proj_dir="$PWD"

# Check for pending resumes for this project and execute if due
check_pending_resumes() {
    now=$(date +%s)
    # Find pending resume files matching this project directory
    proj_hash=$(printf '%s' "$proj_dir" | cksum | cut -d' ' -f1)
    pending_file="$CNT_STATE/.continuum-pending-resume-$proj_hash"
    
    if [ -f "$pending_file" ]; then
        IFS='|' read -r p_dir p_epoch p_prompt p_agent p_scheduler < "$pending_file"
        # Verify directory matches (hash collision protection)
        if [ "$p_dir" = "$proj_dir" ] && [ "$p_epoch" -le "$((now + 60))" ]; then
            # Scheduled time has passed (or within 60 seconds) - execute now
            printf '[continuum] Pending resume found for this project, executing now...\n'
            
            # Cancel the OS-level scheduled job if possible
            case "$p_scheduler" in
                launchd:*)
                    label=${p_scheduler#launchd:}
                    launchctl remove "$label" 2>/dev/null || true
                    ;;
                systemd:*)
                    unit=${p_scheduler#systemd:}
                    systemctl --user stop "${unit}.timer" 2>/dev/null || true
                    ;;
                daemon:*)
                    pid=${p_scheduler#daemon:}
                    kill "$pid" 2>/dev/null || true
                    ;;
                nohup:*)
                    pid=${p_scheduler#nohup:}
                    kill "$pid" 2>/dev/null || true
                    ;;
            esac
            
            # Remove pending file so we don't execute again
            rm -f "$pending_file" 2>/dev/null || true
            
            # Execute the resume command in the current session
            # Build the resume command like cmd_resume does
            CNT_RESUME_CMD=$(cnt_resume_cmd 2>/dev/null) || CNT_RESUME_CMD='claude --continue -p "{prompt}" --permission-mode acceptEdits'
            PROMPT="$p_prompt. Work autonomously: do not ask questions or wait for confirmation — make reasonable decisions, commit results when done, and report what you did in the final message."
            cmd=$(CNT_TMPL="$CNT_RESUME_CMD" CNT_P="$PROMPT" awk 'BEGIN {
                t = ENVIRON["CNT_TMPL"]; p = ENVIRON["CNT_P"]
                gsub(/[\\"$`]/, "\\\\&", p)
                i = index(t, "{prompt}")
                if (i == 0) print t
                else print substr(t, 1, i - 1) p substr(t, i + 8)
            }')
            
            printf '\n### %s - resumed in %s (post-compaction)\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$proj_dir" >> "$LOG"
            cd "$proj_dir" && sh -c "$cmd" >> "$LOG" 2>&1
            status=$?
            printf '\n### end (exit %s) - %s\n' "$status" "$proj_dir" >> "$LOG"
            
            if [ "$status" -eq 0 ]; then
                printf '[continuum] Resume completed successfully.\n'
            else
                printf '[continuum] Resume failed (exit %s). Check %s\n' "$status" "$LOG"
            fi
            
            # Send notification
            cnt_notify "continuum" "Resume ${status:-0} in $(basename "$proj_dir")" 2>/dev/null || true
        fi
    fi
}

# Run pending resume check first (before reporting completed ones)
check_pending_resumes

# `continuum limit-hit` leaves a note when the limit ran out mid-turn; show it at the
# next session start, once (last 24 h), without control characters.
notes="$CNT_STATE/.continuum-limit-notes"
if [ -f "$notes" ]; then
    awk -F '\t' -v cutoff="$(( $(date +%s) - 86400 ))" '$1 + 0 >= cutoff && NF >= 2 {
        s = $2; gsub(/[\001-\037\177]/, "", s); print "[continuum] " s
    }' "$notes"
    rm -f "$notes"
fi

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
