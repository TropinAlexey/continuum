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

CNT_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}"
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

# cnt_read -> the provider's lines on stdout, non-zero on failure
cnt_read() {
    p=$(cnt_provider_path "$CNT_PROVIDER") || {
        echo "unknown provider '$CNT_PROVIDER' (have: $(cnt_providers | tr '\n' ' '))" >&2
        return 1
    }
    out=$(sh "$p") || return 1
    [ -n "$out" ] || { echo "provider '$CNT_PROVIDER' returned nothing" >&2; return 1; }
    printf '%s\n' "$out"
}

# cnt_field N < lines -> Nth whitespace field of the first line
cnt_field() { awk -v n="$1" 'NR==1{print $n}'; }

# --- tiny JSON readers (flat scalar extraction; enough for these APIs) ---
cnt_json_str() { sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1; }
cnt_json_num() { sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p' | head -1; }
cnt_json_block() { sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*{\([^{}]*\)}.*/\1/p' | head -1; }

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
