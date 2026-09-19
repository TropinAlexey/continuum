#!/bin/sh
# continuum test suite (POSIX sh). Runs against the mock provider - no network.
#   sh tests/run.sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export CLAUDE_PLUGIN_ROOT="$ROOT" CONTINUUM_PROVIDER=mock
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }
check(){ # check <name> <expected substring> <actual>
    case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain '$2', got: $3" ;; esac
}
hook() { # hook <config dir> <stdin json>  -> stdout
    printf '%s' "$2" | CLAUDE_CONFIG_DIR="$TMP/$1" sh "$ROOT/hooks/continuum-check.sh" 2>/dev/null || true
}

echo "cli:"
check "status lists both windows" "5 hours" "$(sh "$ROOT/bin/continuum" status)"
check "status shows weekly"       "7 days"  "$(sh "$ROOT/bin/continuum" status)"
check "providers lists mock"      "mock"    "$(sh "$ROOT/bin/continuum" providers)"
check "reset prints HH:MM"        ":"       "$(sh "$ROOT/bin/continuum" reset)"

# A failing provider must not look like success: the exit status has to survive
# the pipeline inside cmd_status.
if CONTINUUM_MOCK_FAIL=1 sh "$ROOT/bin/continuum" status >/dev/null 2>&1
then bad "status fails when provider fails" "exit 0"
else ok  "status fails when provider fails"; fi

if CONTINUUM_PROVIDER=nope sh "$ROOT/bin/continuum" status >/dev/null 2>&1
then bad "unknown provider fails" "exit 0"
else ok  "unknown provider fails"; fi

# install.sh puts a symlink on PATH, so $0 is the link, not the checkout. Without
# CLAUDE_PLUGIN_ROOT (the plugin-only escape hatch) the root has to come from it.
# Git Bash on Windows copies instead of linking, and install.sh is POSIX-only
# anyway - there is nothing to assert there.
if ln -s "$ROOT/bin/continuum" "$TMP/continuum-link" 2>/dev/null && [ -L "$TMP/continuum-link" ]; then
    out=$(unset CLAUDE_PLUGIN_ROOT; sh "$TMP/continuum-link" providers 2>&1)
    check "runs through a PATH symlink" "mock" "$out"
else
    printf '  skip runs through a PATH symlink (no symlink support)\n'
fi

echo "json:"
# The credential store holds an accessToken per MCP OAuth server as well as ours,
# all on one line. A greedy sed would return the LAST one - a token for some other
# host, which the usage endpoint rejects with a 401.
two='{"claudeAiOauth":{"accessToken":"ours","expiresAt":1},"mcpOAuth":{"x":{"accessToken":"theirs"}}}'
. "$ROOT/lib/core.sh"
check "reads the first accessToken" "ours" "$(printf '%s' "$two" | cnt_json_str accessToken)"
check "block reader scopes the key"  "ours" "$(printf '%s' "$two" | cnt_json_block claudeAiOauth | cnt_json_str accessToken)"
# Blocks stay intact through nesting, braces in strings, and pretty printing.
nested='{"five_hour":{"utilization":86.5,"meta":{"src":"x"},"resets_at":"2026-07-09T17:40:00Z"}}'
blk=$(printf '%s' "$nested" | cnt_json_block five_hour)
check "block spans nested object"   "86.5"                 "$(printf '%s' "$blk" | cnt_json_num utilization)"
check "block keeps later keys"      "2026-07-09T17:40:00Z" "$(printf '%s' "$blk" | cnt_json_str resets_at)"
check "block ignores braces in strings" "7" "$(printf '%s' '{"five_hour":{"note":"a{b}c","utilization":7}}' | cnt_json_block five_hour | cnt_json_num utilization)"
pretty=$(printf '{\n "five_hour": {\n "utilization": 50.0,\n "resets_at": "2026-01-01T00:00:00Z"\n }\n}')
check "block spans multiple lines" "50.0" "$(printf '%s' "$pretty" | cnt_json_block five_hour | cnt_json_num utilization)"

echo "install:"
# `curl | sh` must fetch the repo, never scoop up whatever the current directory
# happens to be. Run it piped from inside a checkout, behind a git that refuses to
# clone: reaching that git at all proves it did not take the cwd, and it keeps the
# test off the network. (Trimming PATH would not hide git - it lives in /usr/bin.)
mkdir -p "$TMP/fakebin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/fakebin/git"; chmod +x "$TMP/fakebin/git"
out=$(cd "$ROOT" && PATH="$TMP/fakebin:$PATH" CONTINUUM_HOME="$TMP/inst" sh < "$ROOT/install.sh" 2>&1 || true)
check "piped install ignores the cwd" "git clone failed" "$out"
case "$out" in *"copying from"*) bad "piped install never copies the cwd" "$out" ;;
                              *) ok  "piped install never copies the cwd" ;; esac

echo "resume:"
dry() { CONTINUUM_DRY_RUN=1 CONTINUUM_RESUME_CMD="$1" sh "$ROOT/bin/continuum" resume 23:59 "$ROOT" "$2" 2>&1; }
check "default agent is claude"   'claude --continue -p "finish it.' "$(dry '' 'finish it')"
check "default agent autonomous"  'Work autonomously'                "$(dry '' 'finish it')"
check "swappable agent"           'sh exec "run it.'                 "$(dry 'sh exec "{prompt}"' 'run it')"
check "template without {prompt}" 'sh --continue'                    "$(dry 'sh --continue' 'ignored')"
check "hostile prompt escaped"    '\"the\"'                        "$(dry 'sh run "{prompt}"' 'fix "the" bug')"
# No dry run here: the PATH check only runs on the real scheduling path.
if CONTINUUM_RESUME_CMD='nosuchagent {prompt}' sh "$ROOT/bin/continuum" resume 23:59 "$ROOT" x >/dev/null 2>&1
then bad "missing agent fails" "exit 0"
else ok  "missing agent fails"; fi

echo "resume report:"
# Fake resume log: one recent entry with ANSI/control junk, one ancient entry.
# Started stamps go through date -d/-j, so format them portably.
rr_dir="$TMP/rr"; mkdir -p "$rr_dir"
fmt_epoch() { date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M:%S'; }
recent=$(fmt_epoch "$(date +%s)")
esc=$(printf '\033')
{
    printf '### %s - resumed in /tmp/proj\n' "$recent"
    printf '%s[32mGreen task%s[0m done\n' "$esc" "$esc"
    printf '%s]8;;http://evil\aLinked\n' "$esc"
    printf '%s]8;;http://st-evil%s\\ ST-linked\n' "$esc" "$esc"
    printf '%s]0;window title\atitled\n' "$esc"
    printf '### end (exit 0) - /tmp/proj\n'
    printf '### 2020-01-01 00:00:00 - resumed in /tmp/old\nancient-marker text\n### end (exit 1) - /tmp/old\n'
} > "$rr_dir/continuum-resume.log"
out=$(CLAUDE_CONFIG_DIR="$rr_dir" sh "$ROOT/hooks/resume-report.sh" 2>&1)
check "resume report shows recent"     "Green task done" "$out"
check "resume report keeps BEL link text" "Linked"    "$out"
check "resume report keeps ST link text"  "ST-linked" "$out"
check "resume report strips BEL titles" "titled"         "$out"
case "$out" in *"$esc"*) bad "resume report strips escapes" "ESC leaked" ;; *) ok "resume report strips escapes" ;; esac
case "$out" in *ancient-marker*) bad "resume report ignores old entries" "$out" ;; *) ok "resume report ignores old entries" ;; esac
case "$out" in *http://evil*) bad "resume report strips URLs" "$out" ;; *) ok "resume report strips URLs" ;; esac
out=$(CLAUDE_CONFIG_DIR="$TMP/rr_missing" sh "$ROOT/hooks/resume-report.sh" 2>&1)
[ -z "$out" ] && ok "resume report silent without log" || bad "resume report silent without log" "$out"

echo "watch:"
check "watch fires over threshold" "resets at" "$(CONTINUUM_MOCK='91.0' sh "$ROOT/bin/continuum" watch 1 2>&1)"

echo "hook:"
out=$(hook a '{"session_id":"a"}')
check "blocks over threshold"  '"decision":"block"' "$out"
check "reports utilization"    "86% used"           "$out"
check "mentions second window" "7d window 41.0%"    "$out"

out=$(hook a '{"session_id":"a"}')
[ -z "$out" ] && ok "warns once per session" || bad "warns once per session" "$out"

out=$(CONTINUUM_MOCK="46.0 10.0" hook b '{"session_id":"b"}')
[ -z "$out" ] && ok "silent under threshold" || bad "silent under threshold" "$out"

out=$(CONTINUUM_MOCK="93.2" hook e '{"session_id":"e"}')
check "single-window provider" '"decision":"block"' "$out"
case "$out" in *"Also:"*) bad "no phantom second window" "$out" ;; *) ok "no phantom second window" ;; esac

# Escalating tiers: each of 80/90/95/99 fires once as usage climbs, and only upward.
# CONTINUUM_CACHE_MIN=0 disables the cache, so each call re-reads the changing mock.
esc() { CONTINUUM_CACHE_MIN=0 CONTINUUM_MOCK="$1" hook esc '{"session_id":"esc"}'; }
check "tier 80 warns"          "80% tier" "$(esc 82.0)"
[ -z "$(esc 88.0)" ] && ok "quiet between tiers" || bad "quiet between tiers" "warned again at 88%"
check "tier 95 warns next"     "95% tier" "$(esc 96.0)"
[ -z "$(esc 96.0)" ] && ok "same tier warns once" || bad "same tier warns once" "warned twice at 96%"
check "tier 99 warns last"     "99% tier" "$(esc 99.0)"

# Re-arm: a drop below the floor (top-up, rollover) clears the flag, so the
# same tier fires again on the way back up instead of staying silent.
rearm() { CONTINUUM_CACHE_MIN=0 CONTINUUM_MOCK="$1" hook rearm '{"session_id":"rearm"}'; }
check "re-arm warns at 80" "80% tier" "$(rearm 82.0)"
[ -z "$(rearm 46.0)" ] && ok "re-arm drop is silent" || bad "re-arm drop is silent" "warned at 46%"
[ ! -f "$TMP/rearm/.continuum-warned-rearm" ] && ok "re-arm clears the flag" || bad "re-arm clears the flag" "flag still present"
check "re-arm warns again at 80" "80% tier" "$(rearm 83.0)"

# The "fires once per tier (...)" line reflects the configured tiers, not a hardcoded list.
out=$(CONTINUUM_TIERS="50 75" CONTINUUM_THRESHOLD=50 CONTINUUM_MOCK="80.0" hook cti '{"session_id":"cti"}')
check "message lists configured tiers"   "fire once each (50/75)" "$out"
case "$out" in *"80/90/95/99"*) bad "no hardcoded tier list" "$out" ;; *) ok "no hardcoded tier list" ;; esac

# A custom floor drops the tiers beneath it.
out=$(CONTINUUM_THRESHOLD=90 CONTINUUM_MOCK="85.0" hook flr '{"session_id":"flr"}')
[ -z "$out" ] && ok "floor silences lower tiers" || bad "floor silences lower tiers" "$out"

out=$(CONTINUUM_MOCK_FAIL=1 hook c '{"session_id":"c"}')
[ -z "$out" ] && ok "silent when provider fails" || bad "silent when provider fails" "$out"
[ -f "$TMP/c/.continuum-cache-mock.fail" ] && ok "negative cache written" || bad "negative cache written" "missing"

out=$(hook d '{"session_id":"d","stop_hook_active":true}')
[ -z "$out" ] && ok "respects stop_hook_active" || bad "respects stop_hook_active" "$out"

out=$(CONTINUUM_OFF=1 hook f '{"session_id":"f"}')
[ -z "$out" ] && ok "respects CONTINUUM_OFF" || bad "respects CONTINUUM_OFF" "$out"

# The hook must never exit non-zero: Claude Code surfaces that to the user.
printf '{"session_id":"g"}' | CLAUDE_CONFIG_DIR=/proc/nonexistent sh "$ROOT/hooks/continuum-check.sh" >/dev/null 2>&1 \
    && ok "exit 0 on unwritable config dir" || bad "exit 0 on unwritable config dir" "non-zero exit"

echo "estimate:"
out=$(sh "$ROOT/bin/continuum" estimate 2>&1)
check "estimate shows time left"   "At this pace" "$out"
check "estimate shows utilization"  "Currently"   "$out"

echo "history:"
# status writes history; we already called status above
out=$(sh "$ROOT/bin/continuum" history 2>&1)
check "history shows entries" "5h:" "$out"

echo "cleanup:"
# Isolated dir: earlier revisions touched $HOME/.claude here via $CNT_CFG
# (sourced from core.sh). Never write outside $TMP in tests.
cleanup_dir="$TMP/cleanup_test"; mkdir -p "$cleanup_dir"
touch -t 202501010000 "$cleanup_dir/.continuum-warned-stale" 2>/dev/null || true
out=$(CLAUDE_CONFIG_DIR="$cleanup_dir" sh "$ROOT/bin/continuum" cleanup 2>&1)
check "cleanup reports count" "Cleaned" "$out"

echo "weekly tiers:"
# Weekly window crosses its tier independently of primary (primary at 50% = below 80% floor)
out=$(CONTINUUM_CACHE_MIN=0 CONTINUUM_MOCK="50.0 75.0" hook wk7 '{"session_id":"wk7"}')
check "weekly tier fires"  "weekly window" "$out"
out=$(CONTINUUM_CACHE_MIN=0 CONTINUUM_MOCK="50.0 75.0" hook wk7 '{"session_id":"wk7"}')
[ -z "$out" ] && ok "weekly same tier quiet" || bad "weekly same tier quiet" "$out"
out=$(CONTINUUM_CACHE_MIN=0 CONTINUUM_MOCK="50.0 90.0" hook wk7 '{"session_id":"wk7"}')
check "weekly next tier fires" "weekly window" "$out"

echo "wakelock:"
wl_wrap=$(. "$ROOT/lib/core.sh" && cnt_wakelock_wrap)
case "$(uname)" in
    Darwin) check "wakelock wrap is caffeinate" "caffeinate" "$wl_wrap" ;;
    Linux)  check "wakelock wrap is systemd-inhibit" "systemd-inhibit" "$wl_wrap" ;;
    *)      [ -z "$wl_wrap" ] && ok "wakelock wrap empty on unsupported" || bad "wakelock wrap on unsupported" "$wl_wrap" ;;
esac

wl_pf=$(. "$ROOT/lib/core.sh" && cnt_wakelock_start 5)
if [ -n "$wl_pf" ]; then
    [ -f "$wl_pf" ] && ok "wakelock pidfile created" || bad "wakelock pidfile created" "missing $wl_pf"
    wl_pid=$(cat "$wl_pf")
    kill -0 "$wl_pid" 2>/dev/null && ok "wakelock process alive" || bad "wakelock process alive" "dead"
    . "$ROOT/lib/core.sh" && cnt_wakelock_stop "$wl_pf"
    kill -0 "$wl_pid" 2>/dev/null && bad "wakelock stopped" "still alive" || ok "wakelock stopped"
    [ ! -f "$wl_pf" ] && ok "wakelock pidfile cleaned" || bad "wakelock pidfile cleaned" "still exists"
else
    printf '  skip wakelock start/stop (no tool available)\n'
fi

# nohup resume path should mention sleep inhibition
out=$(CONTINUUM_DRY_RUN=1 sh "$ROOT/bin/continuum" resume 23:59 "$ROOT" "test task" 2>&1)
check "dry run resume works with wakelock" "would sleep" "$out"

echo "frugal gate:"
# The PreToolUse hook blocks Agent when CONTINUUM_FRUGAL=1
out=$(printf '{"tool_name":"Agent"}' | CONTINUUM_FRUGAL=1 sh "$ROOT/hooks/frugal-gate.sh" 2>/dev/null)
check "frugal blocks Agent" '"decision":"block"' "$out"
out=$(printf '{"tool_name":"Read"}' | CONTINUUM_FRUGAL=1 sh "$ROOT/hooks/frugal-gate.sh" 2>/dev/null)
[ -z "$out" ] && ok "frugal allows Read" || bad "frugal allows Read" "$out"
out=$(printf '{"tool_name":"Agent"}' | sh "$ROOT/hooks/frugal-gate.sh" 2>/dev/null)
[ -z "$out" ] && ok "no frugal allows Agent" || bad "no frugal allows Agent" "$out"

echo "multi-provider:"
out=$(CONTINUUM_PROVIDER=mock,mock sh "$ROOT/bin/continuum" status 2>&1)
check "multi-provider status works" "5 hours" "$out"
# Comma lists are often written with a space ("mock, mock"): it must not fail lookup.
out=$(CONTINUUM_PROVIDER="mock, mock" sh "$ROOT/bin/continuum" status 2>&1)
check "multi-provider tolerates spaces" "5 hours" "$out"
# Float comparison: 86.9 must win over 86.1 (integer truncation calls them equal).
# Both entries are mock primaries here; the point is only that it does not fail.
out=$(CONTINUUM_PROVIDER="mock,mock" CONTINUUM_MOCK="86.9" sh "$ROOT/bin/continuum" status 2>&1)
check "multi-provider float compare" "5 hours" "$out"

echo "resume quoting:"
# A project dir with a single quote must not break scheduling (sq-escaping).
qdir="$TMP/o'brien"; mkdir -p "$qdir"
out=$(CONTINUUM_DRY_RUN=1 sh "$ROOT/bin/continuum" resume 23:59 "$qdir" "test task" 2>&1)
check "resume accepts quote in dir" "would sleep" "$out"

echo "spend validation:"
# Invalid cap must fail before any network call (ADMIN_KEY dummy, cap 0).
if ANTHROPIC_ADMIN_KEY=dummy CONTINUUM_SPEND_CAP=0 sh "$ROOT/providers/spend.sh" >/dev/null 2>&1
then bad "spend rejects zero cap" "exit 0"
else ok  "spend rejects zero cap"; fi
if ANTHROPIC_ADMIN_KEY=dummy CONTINUUM_SPEND_CAP=abc sh "$ROOT/providers/spend.sh" >/dev/null 2>&1
then bad "spend rejects non-numeric cap" "exit 0"
else ok  "spend rejects non-numeric cap"; fi

echo "statusline:"
# Prepare a fake cache with known data
sl_dir="$TMP/sl_test"; mkdir -p "$sl_dir"
now=$(date +%s)
d_reset=$(( now + 3600 ))
w_reset=$(( now + 4 * 86400 ))
printf '5h 46.0 %s\n7d 94.0 %s\n' "$d_reset" "$w_reset" > "$sl_dir/.continuum-cache-mock"

sl_out=$(CLAUDE_CONFIG_DIR="$sl_dir" sh "$ROOT/hooks/statusline.sh" 2>/dev/null)
check "statusline shows daily percent" "46%" "$sl_out"
check "statusline shows weekly percent" "94%" "$sl_out"
check "statusline shows today for daily" "today" "$sl_out"

# Test config commands
out=$(CLAUDE_CONFIG_DIR="$sl_dir" sh "$ROOT/bin/continuum" statusline)
check "statusline cmd shows format" "format" "$out"

CLAUDE_CONFIG_DIR="$sl_dir" sh "$ROOT/bin/continuum" statusline today "сегодня" >/dev/null
sl_out=$(CLAUDE_CONFIG_DIR="$sl_dir" sh "$ROOT/hooks/statusline.sh" 2>/dev/null)
check "statusline respects today config" "сегодня" "$sl_out"

CLAUDE_CONFIG_DIR="$sl_dir" sh "$ROOT/bin/continuum" statusline reset >/dev/null
sl_out=$(CLAUDE_CONFIG_DIR="$sl_dir" sh "$ROOT/hooks/statusline.sh" 2>/dev/null)
check "statusline reset restores defaults" "today" "$sl_out"

# Test format-single (no weekly data)
printf '5h 46.0 %s\n' "$d_reset" > "$sl_dir/.continuum-cache-mock"
sl_out=$(CLAUDE_CONFIG_DIR="$sl_dir" sh "$ROOT/hooks/statusline.sh" 2>/dev/null)
check "statusline single shows daily" "46%" "$sl_out"
case "$sl_out" in *94%*) bad "statusline single hides weekly" "found 94% in: $sl_out" ;; *) ok "statusline single hides weekly" ;; esac

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
