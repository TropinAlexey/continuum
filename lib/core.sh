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
CNT_ROOT="${CLAUDE_PLUGIN_ROOT:-${CNT_ROOT:-$(dirname "$(dirname "$0")")}}"
CNT_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CNT_PROVIDER="${CONTINUUM_PROVIDER:-anthropic}"

# --- provider dispatch -------------------------------------------------
cnt_provider_path() {
    for d in "$CNT_ROOT/providers" "$CNT_CFG/providers"; do
        [ -f "$d/$1.sh" ] && { printf '%s' "$d/$1.sh"; return 0; }
    done
    return 1
}

cnt_providers() {
    for d in "$CNT_ROOT/providers" "$CNT_CFG/providers"; do
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
cnt_json_block() { grep -o '"'"$1"'"[[:space:]]*:[[:space:]]*{[^{}]*}' | head -1 | sed 's/^[^{]*{//; s/}$//'; }

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
    _wl_pf="$CNT_CFG/.continuum-wakelock-$(date +%s).pid"
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
