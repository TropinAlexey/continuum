#!/bin/sh
# Claude Code status line: shows utilization% with color coding and optional reset times.
# Colors: green <80, yellow 80-94, red ≥95.
# Config: .continuum-statusline.conf in the continuum state dir (managed by
# `continuum statusline`). Settings.json usually runs a copy of this file from
# ~/.claude/hooks/, with no environment: the state dir's root pointer finds the code.
set -eu

if [ -n "${CONTINUUM_STATE_DIR:-}" ]; then CNT_STATE="$CONTINUUM_STATE_DIR"
elif [ -n "${XDG_STATE_HOME:-}" ]; then CNT_STATE="$XDG_STATE_HOME/continuum"
else CNT_STATE="$HOME/.local/state/continuum"; fi

find_root() {
    for r in "${CONTINUUM_ROOT:-}" "${CLAUDE_PLUGIN_ROOT:-}" "$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)" "$(cat "$CNT_STATE/root" 2>/dev/null)"; do
        [ -n "$r" ] && [ -f "$r/lib/core.sh" ] && { printf '%s' "$r"; return 0; }
    done
    return 1
}

CNT_PROVIDER="${CONTINUUM_PROVIDER:-anthropic}"
case "$CNT_PROVIDER" in *,*) CNT_PROVIDER="${CNT_PROVIDER%%,*}" ;; esac
# The provider name lands in a filename: keep it in-dir on hostile values.
CNT_PROVIDER=$(printf '%s' "$CNT_PROVIDER" | tr -d '[:space:]' | tr -c 'A-Za-z0-9_-' '_')
[ -z "$CNT_PROVIDER" ] && CNT_PROVIDER=anthropic

cache="$CNT_STATE/.continuum-cache-$CNT_PROVIDER"
conf="$CNT_STATE/.continuum-statusline.conf"

# Background refresh if cache is older than 30s; atomic write via tmp+mv.
# The tmp file carries the PID: two sessions refreshing at once must not share it.
root=$(find_root) || root=""
if [ -n "$root" ] && { [ ! -f "$cache" ] || [ -z "$(find "$cache" -mmin -0.5 2>/dev/null)" ]; }; then
    mkdir -p "$CNT_STATE" 2>/dev/null || true
    _tmp="$cache.$$.tmp"
    (CNT_ROOT="$root" . "$root/lib/core.sh" && cnt_read > "$_tmp" 2>/dev/null && mv "$_tmp" "$cache" || rm -f "$_tmp") &
fi

[ -f "$cache" ] || exit 0

d_util=$(awk 'NR==1{print $2}' "$cache")
w_util=$(awk 'NR==2{print $2}' "$cache")
d_reset=$(awk 'NR==1{print $3}' "$cache")
w_reset=$(awk 'NR==2{print $3}' "$cache")
[ -z "$d_util" ] && exit 0

d_pct=${d_util%%.*}
case "$d_pct" in ''|*[!0-9]*) exit 0 ;; esac

w_pct=${w_util%%.*}
case "$w_pct" in ''|*[!0-9]*) w_pct="" ;; esac

cnt_color() { if [ "$1" -ge 95 ]; then printf '31'; elif [ "$1" -ge 80 ]; then printf '33'; else printf '32'; fi; }

# --- config ---------------------------------------------------------------
_conf_val() {
    [ -f "$conf" ] || return 1
    v=$(grep "^$1=" "$conf" 2>/dev/null | head -1 | cut -d= -f2-)
    [ -n "$v" ] && printf '%s' "$v" || return 1
}

fmt=$(_conf_val FORMAT 2>/dev/null) || fmt='{d%}% d {dr} | {w%}% w {wr}'
fmt_single=$(_conf_val FORMAT_SINGLE 2>/dev/null) || fmt_single='{d%}% d {dr}'
time_fmt=$(_conf_val TIME_FORMAT 2>/dev/null) || time_fmt='%H:%M'
date_fmt=$(_conf_val DATE_FORMAT 2>/dev/null) || date_fmt='%d.%m'
today_word=$(_conf_val TODAY 2>/dev/null) || today_word='today'

# Format reset epoch -> "today HH:MM" or "DD.MM HH:MM"
_fmt_reset() {
    _e="$1"
    [ -z "$_e" ] || [ "$_e" = "-" ] && return 0
    _today=$(date +"$date_fmt")
    _rdate=$(date -r "$_e" +"$date_fmt" 2>/dev/null || date -d "@$_e" +"$date_fmt" 2>/dev/null) || return 0
    _rtime=$(date -r "$_e" +"$time_fmt" 2>/dev/null || date -d "@$_e" +"$time_fmt" 2>/dev/null) || return 0
    if [ "$_today" = "$_rdate" ]; then
        printf '%s %s' "$today_word" "$_rtime"
    else
        printf '%s %s' "$_rdate" "$_rtime"
    fi
}

# Replace first occurrence of $2 with $3 in $1
_sub() {
    case "$1" in *"$2"*) ;; *) printf '%s' "$1"; return ;; esac
    printf '%s%s%s' "${1%%"$2"*}" "$3" "${1#*"$2"}"
}

d_colored=$(printf '\033[%sm%s%%\033[0m' "$(cnt_color "$d_pct")" "$d_pct")
d_reset_str=$(_fmt_reset "$d_reset")

if [ -n "$w_pct" ]; then
    w_colored=$(printf '\033[%sm%s%%\033[0m' "$(cnt_color "$w_pct")" "$w_pct")
    w_reset_str=$(_fmt_reset "$w_reset")
    out="$fmt"
    out=$(_sub "$out" '{w%}' "$w_colored")
    out=$(_sub "$out" '{wr}' "$w_reset_str")
else
    out="$fmt_single"
fi

out=$(_sub "$out" '{d%}' "$d_colored")
out=$(_sub "$out" '{dr}' "$d_reset_str")
printf '%s' "$out"
