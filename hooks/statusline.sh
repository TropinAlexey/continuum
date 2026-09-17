#!/bin/sh
# Status-line hook: shows primary-window utilization% with color coding.
# Colors: green <80, yellow 80-94, red ≥95.
# Refreshes the cache in the background every 30s so the display stays current.
set -eu

CNT_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CNT_PROVIDER="${CONTINUUM_PROVIDER:-anthropic}"

# Multi-provider: pick the first provider name for cache lookup
case "$CNT_PROVIDER" in *,*) CNT_PROVIDER="${CNT_PROVIDER%%,*}" ;; esac

cache="$CNT_CFG/.continuum-cache-$CNT_PROVIDER"

# Background refresh if cache is older than 30s (find -mmin -0.5 = within 30s)
LIB="${CLAUDE_PLUGIN_ROOT:-$CNT_CFG}/lib/core.sh"
if [ -f "$LIB" ] && { [ ! -f "$cache" ] || [ -z "$(find "$cache" -mmin -0.5 2>/dev/null)" ]; }; then
    (CNT_ROOT="${CLAUDE_PLUGIN_ROOT:-$CNT_CFG}" . "$LIB" && cnt_read > "$cache" 2>/dev/null) &
fi

[ -f "$cache" ] || exit 0

d_util=$(awk 'NR==1{print $2}' "$cache")
w_util=$(awk 'NR==2{print $2}' "$cache")
[ -z "$d_util" ] && exit 0

d_pct=${d_util%%.*}
case "$d_pct" in ''|*[!0-9]*) exit 0 ;; esac

w_pct=${w_util%%.*}
case "$w_pct" in ''|*[!0-9]*) w_pct="" ;; esac

cnt_color() { if [ "$1" -ge 95 ]; then printf '31'; elif [ "$1" -ge 80 ]; then printf '33'; else printf '32'; fi; }

if [ -n "$w_pct" ]; then
    printf '\033[%sm%s%%\033[0m D \033[%sm%s%%\033[0m W' "$(cnt_color "$d_pct")" "$d_pct" "$(cnt_color "$w_pct")" "$w_pct"
else
    printf '\033[%sm%s%%\033[0m' "$(cnt_color "$d_pct")" "$d_pct"
fi
