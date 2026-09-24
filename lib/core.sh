#!/bin/sh
# continuum - shared helpers. POSIX sh + curl only. No python, no node, no jq.
#
# Provider protocol
# ----------------
# A provider is an executable script in providers/<name>.sh. It prints one line per
# usage window on stdout:
#
#     <window> <utilization> <reset_epoch>
#
#   window        short label, no spaces      e.g. 5h, 7d, daily, month
#   utilization   percent used, 0-100         e.g. 86.5
#   reset_epoch   unix seconds, or "-"        when the window rolls over
#
# The FIRST line is the primary window: the one the Stop hook watches.
# On failure: write a human message to stderr and exit non-zero. Print nothing.
#
# Providers may source this file for the helpers below.

# $0 is the caller, which may be a PATH symlink pointing here; a caller that has
# already resolved its own location passes CNT_ROOT in.
# CLAUDE_PLUGIN_ROOT is honoured for compatibility: Claude Code sets it for hooks.
CNT_ROOT="${CONTINUUM_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CNT_ROOT:-$(dirname "$(dirname "$0")")}}}"
CNT_PROVIDER="${CONTINUUM_PROVIDER:-anthropic}"

# State (cache, flags, logs, config, user providers) is continuum's own, not any
# agent's. Not ~/.continuum: the installer keeps the code there, and may re-clone it.
if [ -n "${CONTINUUM_STATE_DIR:-}" ]; then CNT_STATE="$CONTINUUM_STATE_DIR"
elif [ -n "${XDG_STATE_HOME:-}" ]; then CNT_STATE="$XDG_STATE_HOME/continuum"
else CNT_STATE="$HOME/.local/state/continuum"; fi
# shellcheck disable=SC2034  # deprecated alias, kept for third-party providers
CNT_CFG="$CNT_STATE"

# --- one-time migration from ~/.claude ---------------------------------
# Before the agent-neutral layout, state lived in the Claude Code config dir. Copy
# what is worth keeping (never the ephemeral cache/flags), never overwrite, never
# delete the originals, never fail the caller. No marker on error: retry next run.
cnt_migrate() {
    [ -n "${CONTINUUM_STATE_DIR:-}" ] && return 0
    [ -f "$CNT_STATE/.migrated" ] && return 0
    _old="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    mkdir -p "$CNT_STATE" 2>/dev/null || return 0
    if [ -d "$_old" ]; then
        for _f in .continuum-statusline.conf .continuum-history.log continuum-resume.log; do
            [ -f "$_old/$_f" ] && [ ! -e "$CNT_STATE/$_f" ] && { cp "$_old/$_f" "$CNT_STATE/$_f" 2>/dev/null || return 0; }
        done
        for _f in "$_old"/providers/*.sh "$_old"/providers/*.ps1; do
            [ -f "$_f" ] || continue
            mkdir -p "$CNT_STATE/providers" 2>/dev/null || return 0
            [ -e "$CNT_STATE/providers/${_f##*/}" ] || cp "$_f" "$CNT_STATE/providers/" 2>/dev/null || return 0
        done
    fi
    : > "$CNT_STATE/.migrated" 2>/dev/null || true
}
cnt_migrate

# cnt_set_root_pointer -> record where the code lives, for scripts started without
# any environment (a statusline copied into an agent's config dir).
cnt_set_root_pointer() {
    mkdir -p "$CNT_STATE" 2>/dev/null || return 0
    [ "$(cat "$CNT_STATE/root" 2>/dev/null)" = "$CNT_ROOT" ] && return 0
    printf '%s\n' "$CNT_ROOT" > "$CNT_STATE/root.tmp" 2>/dev/null && mv "$CNT_STATE/root.tmp" "$CNT_STATE/root" 2>/dev/null || true
}

# --- provider dispatch -------------------------------------------------
cnt_provider_path() {
    for d in "$CNT_ROOT/providers" "$CNT_STATE/providers"; do
        [ -f "$d/$1.sh" ] && { printf '%s' "$d/$1.sh"; return 0; }
    done
    return 1
}

cnt_providers() {
    for d in "$CNT_ROOT/providers" "$CNT_STATE/providers"; do
        [ -d "$d" ] || continue
        for f in "$d"/*.sh; do
            [ -f "$f" ] || continue
            n=$(basename "$f"); printf '%s\n' "${n%.sh}"
        done
    done | sort -u
}

# cnt_read_single <provider> -> that provider's lines on stdout
cnt_read_single() {
    p=$(cnt_provider_path "$1") || {
        echo "unknown provider '$1' (have: $(cnt_providers | tr '\n' ' '))" >&2
        return 1
    }
    out=$(sh "$p") || return 1
    [ -n "$out" ] || { echo "provider '$1' returned nothing" >&2; return 1; }
    printf '%s\n' "$out"
}

# cnt_read -> the provider's lines on stdout, non-zero on failure.
# Supports comma-separated providers (CONTINUUM_PROVIDER=anthropic,spend):
# runs all, keeps the line with the highest utilization as the primary.
cnt_read() {
    case "$CNT_PROVIDER" in
        *,*)
            best_util=0; best_line=""; rest=""
            IFS=','
            for prov in $CNT_PROVIDER; do
                unset IFS
                # The list is comma-separated, so "anthropic, spend" keeps a
                # leading space that would otherwise fail provider lookup.
                prov=$(printf '%s' "$prov" | tr -d '[:space:]')
                [ -z "$prov" ] && { IFS=','; continue; }
                out=$(cnt_read_single "$prov") || { IFS=','; continue; }
                line1=$(printf '%s\n' "$out" | head -1)
                u=$(printf '%s' "$line1" | awk '{print $2}')
                case "$u" in ''|*[!0-9.]*) u=0 ;; esac
                # Float comparison: 86.9 must beat 86.1 (integer truncation
                # would call them equal and keep whichever ran first).
                if awk -v a="$u" -v b="$best_util" 'BEGIN{exit !(a+0 > b+0)}'; then
                    best_util=$u; best_line="$line1"
                fi
                rest="${rest}$(printf '%s\n' "$out" | tail -n +2)
"
                IFS=','
            done
            unset IFS
            [ -z "$best_line" ] && { echo "all providers failed" >&2; return 1; }
            printf '%s\n' "$best_line"
            [ -n "$(printf '%s' "$rest" | tr -d '[:space:]')" ] && printf '%s\n' "$rest" | grep .
            return 0
            ;;
        *)
            cnt_read_single "$CNT_PROVIDER"
            ;;
    esac
}

# cnt_field N < lines -> Nth whitespace field of the first line
cnt_field() { awk -v n="$1" 'NR==1{print $n}'; }

# --- tiny JSON readers (flat scalar extraction; enough for these APIs) ---
# grep -o, not sed: a leading `.*` is greedy, so on a one-line document with the
# key repeated (credentials.json has an accessToken per OAuth server) sed returns
# the LAST one. These return the first.
cnt_json_str() { grep -o '"'"$1"'"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'; }
cnt_json_num() { grep -o '"'"$1"'"[[:space:]]*:[[:space:]]*[0-9][0-9.]*' | head -1 | sed 's/.*:[[:space:]]*//'; }
# First {...} block after "key": — brace-counted with string awareness, so a
# nested object ({"meta":{...}}) or braces inside a string ("a{b") do not cut
# the match short, and pretty-printed multi-line JSON works too. Prints the
# block's INNER content (outer braces stripped). Still no jq: plain awk.
cnt_json_block() {
    awk -v key="$1" '
        function scan(   s, i, rest, tmp) {
            s = $0
            while ((i = index(s, "\"" key "\"")) > 0) {
                rest = substr(s, i + length(key) + 2)
                if (rest ~ /^[[:space:]]*:/) {
                    tmp = rest
                    sub(/^[[:space:]]*:[[:space:]]*/, "", tmp)
                    if (substr(tmp, 1, 1) == "{") { $0 = tmp; return 1 }
                }
                s = substr(s, i + 1)
            }
            return 0
        }
        !started { if (!scan()) next; started = 1; first = 1; depth = 0; buf = "" }
        started {
            n = length($0)
            for (pos = (first ? 2 : 1); pos <= n; pos++) {
                c = substr($0, pos, 1)
                if (in_str) {
                    if (esc) esc = 0
                    else if (c == "\\") esc = 1
                    else if (c == "\"") in_str = 0
                    buf = buf c
                } else if (c == "\"") { in_str = 1; buf = buf c }
                else if (c == "{") { depth++; buf = buf c }
                else if (c == "}") {
                    if (depth == 0) { print buf; exit }
                    depth--; buf = buf c
                }
                else buf = buf c
            }
            buf = buf "\n"
            first = 0
        }
    '
}

# --- portable date math (GNU and BSD) ----------------------------------
# cnt_iso_epoch "2026-07-09T17:40:00.180+00:00" -> unix epoch (UTC input)
cnt_iso_epoch() {
    iso=$(printf '%s' "$1" | sed 's/\..*//; s/Z$//; s/+00:00$//')
    date -u -d "${iso}Z" +%s 2>/dev/null && return 0                       # GNU
    date -u -j -f "%Y-%m-%dT%H:%M:%S" "$iso" +%s 2>/dev/null && return 0   # BSD
    return 1
}

# cnt_epoch_hhmm 1783000000 [margin_seconds] -> local HH:MM
cnt_epoch_hhmm() {
    # A custom provider returning garbage must not kill the caller under
    # `set -eu` via a failed $(( )) arithmetic expansion: validate first.
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    e=$(( $1 + ${2:-0} ))
    date -r "$e" +%H:%M 2>/dev/null && return 0    # BSD
    date -d "@$e" +%H:%M 2>/dev/null && return 0   # GNU
    return 1
}

# cnt_num 09 -> 9 ; cnt_num 00 -> 0   (strip leading zeros, keep arithmetic sane)
cnt_num() {
    v=$(printf '%s' "$1" | sed 's/^0*//')
    [ -z "$v" ] && v=0
    printf '%s' "$v"
}

# cnt_notify "title" "message" - desktop notification, best-effort, never fails
cnt_notify() {
    title="$1"; msg="$2"
    if command -v osascript >/dev/null 2>&1; then
        osascript -e "display notification \"$msg\" with title \"$title\"" 2>/dev/null || true
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send "$title" "$msg" 2>/dev/null || true
    fi
}

# --- wakelock (prevent system sleep during scheduled resume) ----------
# cnt_wakelock_start <seconds> -> prints pidfile path (empty if no tool)
cnt_wakelock_start() {
    _wl_pf="$CNT_STATE/.continuum-wakelock-$(date +%s).pid"
    case "$(uname)" in
        Darwin)
            command -v caffeinate >/dev/null 2>&1 || return 0
            caffeinate -i -t "$1" >/dev/null 2>&1 &
            printf '%s' "$!" > "$_wl_pf" ;;
        Linux)
            command -v systemd-inhibit >/dev/null 2>&1 || return 0
            systemd-inhibit --what=idle:sleep --who=continuum --why=resume \
                sleep "$1" >/dev/null 2>&1 &
            printf '%s' "$!" > "$_wl_pf" ;;
        *) return 0 ;;
    esac
    printf '%s' "$_wl_pf"
}

# cnt_wakelock_stop <pidfile>
cnt_wakelock_stop() {
    [ -f "$1" ] || return 0
    kill "$(cat "$1")" 2>/dev/null || true; rm -f "$1"
}

# cnt_wakelock_wrap -> prefix command for wrapping a process (empty if unavailable)
cnt_wakelock_wrap() {
    case "$(uname)" in
        Darwin) command -v caffeinate >/dev/null 2>&1 && printf 'caffeinate -i' ;;
        Linux)  command -v systemd-inhibit >/dev/null 2>&1 && printf 'systemd-inhibit --what=idle:sleep --who=continuum --why=resume' ;;
    esac
}

# cnt_hhmm_delay "19:40" -> seconds until the next occurrence of HH:MM (local)
cnt_hhmm_delay() {
    case "$1" in
        [0-9]:[0-9][0-9]|[0-9][0-9]:[0-9][0-9]) ;;
        *) echo "invalid time: $1 (expected HH:MM)" >&2; return 1 ;;
    esac
    h=$(cnt_num "${1%%:*}"); m=$(cnt_num "${1##*:}")
    if [ "$h" -gt 23 ] || [ "$m" -gt 59 ]; then
        echo "invalid time: $1 (expected HH:MM)" >&2; return 1
    fi
    now=$(date +%s)
    midnight=$(( now - ( $(cnt_num "$(date +%H)") * 3600 \
                       + $(cnt_num "$(date +%M)") * 60 \
                       + $(cnt_num "$(date +%S)") ) ))
    target=$(( midnight + h * 3600 + m * 60 ))
    [ "$target" -le "$now" ] && target=$(( target + 86400 ))  # already passed -> tomorrow
    echo $(( target - now ))
}
