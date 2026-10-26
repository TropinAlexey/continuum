#!/bin/sh
# continuum test suite (POSIX sh). Runs against the mock provider - no network.
#   sh tests/run.sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# State goes to $TMP, never to the real home: every test that needs its own
# state dir overrides CONTINUUM_STATE_DIR.
export CLAUDE_PLUGIN_ROOT="$ROOT" CONTINUUM_PROVIDER=mock CONTINUUM_STATE_DIR="$TMP/state"
# The suite may itself run inside a bb thread; resume presets must not see it.
unset BB_THREAD_ID

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }
check(){ # check <name> <expected substring> <actual>
    case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain '$2', got: $3" ;; esac
}
hook() { # hook <config dir> <stdin json>  -> stdout
    printf '%s' "$2" | CONTINUUM_STATE_DIR="$TMP/$1" sh "$ROOT/adapters/claude/stop.sh" 2>/dev/null || true
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
check "agent preset claude"      'claude --continue'                "$(CONTINUUM_AGENT=claude dry '' 'x')"
check "agent preset codex"       'codex exec resume --last'         "$(CONTINUUM_AGENT=codex dry '' 'x')"
check "agent preset gemini"      'gemini --resume latest'           "$(CONTINUUM_AGENT=gemini dry '' 'x')"
check "agent preset cursor"      'agent -p --continue'      "$(CONTINUUM_AGENT=cursor dry '' 'x')"
check "agent preset opencode"    'opencode run --continue'          "$(CONTINUUM_AGENT=opencode dry '' 'x')"
check "agent preset junie"       'junie --skip-update-check --resume --task' "$(CONTINUUM_AGENT=junie dry '' 'x')"
if (CONTINUUM_AGENT=nope dry '' 'x') >/dev/null 2>&1
then bad "unknown agent without command fails" "exit 0"
else ok  "unknown agent without command fails"; fi
check "explicit command beats preset" 'sh exec "y.'  "$(CONTINUUM_AGENT=nope dry 'sh exec "{prompt}"' 'y')"
check "bb thread beats agent preset" 'thread tell th_1-A "x.'  "$(BB_THREAD_ID=th_1-A CONTINUUM_AGENT=codex dry '' 'x')"
check "explicit command beats bb thread" 'sh exec "y.'  "$(BB_THREAD_ID=th_1 dry 'sh exec "{prompt}"' 'y')"
check "unsafe bb thread id ignored" 'claude --continue'  "$(BB_THREAD_ID='t;rm -rf' dry '' 'x')"
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
out=$(CONTINUUM_STATE_DIR="$rr_dir" sh "$ROOT/adapters/claude/resume-report.sh" 2>&1)
check "resume report shows recent"     "Green task done" "$out"
check "resume report keeps BEL link text" "Linked"    "$out"
check "resume report keeps ST link text"  "ST-linked" "$out"
check "resume report strips BEL titles" "titled"         "$out"
case "$out" in *"$esc"*) bad "resume report strips escapes" "ESC leaked" ;; *) ok "resume report strips escapes" ;; esac
case "$out" in *ancient-marker*) bad "resume report ignores old entries" "$out" ;; *) ok "resume report ignores old entries" ;; esac
case "$out" in *http://evil*) bad "resume report strips URLs" "$out" ;; *) ok "resume report strips URLs" ;; esac
out=$(CONTINUUM_STATE_DIR="$TMP/rr_missing" sh "$ROOT/adapters/claude/resume-report.sh" 2>&1)
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
printf '{"session_id":"g"}' | CONTINUUM_STATE_DIR=/proc/nonexistent sh "$ROOT/adapters/claude/stop.sh" >/dev/null 2>&1 \
    && ok "exit 0 on unwritable state dir" || bad "exit 0 on unwritable state dir" "non-zero exit"

echo "check (agent-neutral):"
chkn() { d="$1"; shift; CONTINUUM_STATE_DIR="$TMP/chk/$d" sh "$ROOT/bin/continuum" check --session s "$@" 2>&1; }
out=$(chkn g)
check "check warns over threshold" "[continuum] The primary usage window is 86% used" "$out"
check "check generic wording"      "ask the user how to spend the rest" "$out"
case "$out" in *AskUserQuestion*|*'"decision"'*) bad "check output is agent-neutral" "$out" ;; *) ok "check output is agent-neutral" ;; esac
[ -z "$(chkn g)" ] && ok "check warns once per tier" || bad "check warns once per tier" "warned twice"
check "check claude wording" "use AskUserQuestion" "$(chkn c --agent claude)"
check "check agent from env" "use AskUserQuestion" "$(CONTINUUM_AGENT=claude CONTINUUM_STATE_DIR="$TMP/chk/e" sh "$ROOT/bin/continuum" check 2>&1)"
[ -z "$(CONTINUUM_MOCK="46.0 10.0" chkn u)" ] && ok "check silent under threshold" || bad "check silent under threshold" "warned"
[ -z "$(CONTINUUM_MOCK_FAIL=1 chkn f)" ] && ok "check silent when provider fails" || bad "check silent when provider fails" "output"
if sh "$ROOT/bin/continuum" check --bogus >/dev/null 2>&1; then bad "check rejects bad args" "exit 0"; else ok "check rejects bad args"; fi
# The Claude adapter must produce exactly what the pre-adapter hook did.
out=$(hook ad '{"session_id":"ad"}')
check "adapter keeps claude text" 'then use AskUserQuestion to ask the user how to spend the rest of the window, offering the options from that skill.' "$out"
out=$(hook ad2 '{"session_id": "ad2", "stop_hook_active": true}')
[ -z "$out" ] && ok "adapter respects spaced stop_hook_active" || bad "adapter respects spaced stop_hook_active" "$out"
out=$(printf '{"session_id":"fw"}' | CONTINUUM_STATE_DIR="$TMP/fw" sh "$ROOT/hooks/continuum-check.sh" 2>/dev/null)
check "old hook path still works" '"decision":"block"' "$out"

echo "state dir:"
sd() { (unset CONTINUUM_STATE_DIR XDG_STATE_HOME; eval "$1"; . "$ROOT/lib/core.sh"; printf '%s' "$CNT_STATE"); }
check "state dir from CONTINUUM_STATE_DIR" "$TMP/x1" "$(sd "export CONTINUUM_STATE_DIR='$TMP/x1' HOME='$TMP/h0'")"
check "state dir from XDG_STATE_HOME" "$TMP/x2/continuum" "$(sd "export XDG_STATE_HOME='$TMP/x2' HOME='$TMP/h0'")"
check "state dir default" "$TMP/h0/.local/state/continuum" "$(sd "export HOME='$TMP/h0'")"

echo "migration:"
mh="$TMP/mh"; mkdir -p "$mh/.claude/providers"
echo 'TODAY=сегодня' > "$mh/.claude/.continuum-statusline.conf"
echo 'old log' > "$mh/.claude/continuum-resume.log"
echo 'cache' > "$mh/.claude/.continuum-cache-mock"
echo 'echo "x 1 -"' > "$mh/.claude/providers/mine.sh"
ms="$mh/.local/state/continuum"; mkdir -p "$ms"; echo 'kept' > "$ms/.continuum-history.log"
echo 'old hist' > "$mh/.claude/.continuum-history.log"
out=$(unset CONTINUUM_STATE_DIR XDG_STATE_HOME CLAUDE_CONFIG_DIR; HOME="$mh" sh "$ROOT/bin/continuum" providers 2>&1)
check "migration copies statusline conf" "сегодня" "$(cat "$ms/.continuum-statusline.conf" 2>/dev/null)"
check "migration copies resume log" "old log" "$(cat "$ms/continuum-resume.log" 2>/dev/null)"
check "migration copies user providers" "mine" "$out"
check "migration never overwrites" "kept" "$(cat "$ms/.continuum-history.log")"
[ ! -e "$ms/.continuum-cache-mock" ] && ok "migration skips cache" || bad "migration skips cache" "copied"
[ -f "$ms/.migrated" ] && ok "migration leaves a marker" || bad "migration leaves a marker" "missing"
[ -f "$mh/.claude/continuum-resume.log" ] && ok "migration keeps originals" || bad "migration keeps originals" "deleted"
echo 'NEW=1' > "$mh/.claude/.continuum-statusline.conf"
(unset CONTINUUM_STATE_DIR XDG_STATE_HOME CLAUDE_CONFIG_DIR; HOME="$mh" sh "$ROOT/bin/continuum" providers >/dev/null 2>&1)
check "migration runs once" "сегодня" "$(cat "$ms/.continuum-statusline.conf")"

echo "root pointer:"
rp="$TMP/rp"; mkdir -p "$rp/copy"
CONTINUUM_STATE_DIR="$rp/state" sh "$ROOT/bin/continuum" providers >/dev/null
check "cli records root pointer" "$ROOT" "$(cat "$rp/state/root" 2>/dev/null)"
cp "$ROOT/adapters/claude/statusline.sh" "$rp/copy/statusline.sh"
(unset CLAUDE_PLUGIN_ROOT; CONTINUUM_STATE_DIR="$rp/state" sh "$rp/copy/statusline.sh" >/dev/null 2>&1)
i=0; while [ ! -f "$rp/state/.continuum-cache-mock" ] && [ $i -lt 20 ]; do sleep 0.2 2>/dev/null || sleep 1; i=$((i+1)); done
[ -f "$rp/state/.continuum-cache-mock" ] && ok "copied statusline finds core via pointer" || bad "copied statusline finds core via pointer" "no cache refresh"
cd_=$TMP/rp_claude; mkdir -p "$cd_/hooks"; printf '#!/bin/sh\n# continuum old\n' > "$cd_/hooks/statusline.sh"
(CLAUDE_CONFIG_DIR="$cd_" CONTINUUM_STATE_DIR="$rp/state2" sh "$ROOT/adapters/claude/setup-statusline.sh" </dev/null >/dev/null 2>&1)
cmp -s "$ROOT/adapters/claude/statusline.sh" "$cd_/hooks/statusline.sh" && ok "setup refreshes stale statusline copy" || bad "setup refreshes stale statusline copy" "not refreshed"
check "setup records root pointer" "$ROOT" "$(cat "$rp/state2/root" 2>/dev/null)"

echo "estimate:"
out=$(sh "$ROOT/bin/continuum" estimate 2>&1)
check "estimate shows time left"   "At this pace" "$out"
check "estimate shows utilization"  "Currently"   "$out"

echo "history:"
# status writes history; we already called status above
out=$(sh "$ROOT/bin/continuum" history 2>&1)
check "history shows entries" "5h:" "$out"

echo "cleanup:"
# Isolated dir: earlier revisions touched the real home here via the state dir
# (sourced from core.sh). Never write outside $TMP in tests.
cleanup_dir="$TMP/cleanup_test"; mkdir -p "$cleanup_dir"
touch -t 202501010000 "$cleanup_dir/.continuum-warned-stale" 2>/dev/null || true
out=$(CONTINUUM_STATE_DIR="$cleanup_dir" sh "$ROOT/bin/continuum" cleanup 2>&1)
check "cleanup reports count" "Cleaned" "$out"

echo "weekly tiers:"
# Weekly window crosses its tier independently of primary (primary at 50% = below 80% floor)
out=$(CONTINUUM_CACHE_MIN=0 CONTINUUM_MOCK="50.0 75.0" hook wk7 '{"session_id":"wk7"}')
check "weekly tier fires"  "weekly window" "$out"
case "$out" in *"tier), resets "[A-Z][a-z][a-z]" "[0-2][0-9]:[0-5][0-9]*) ok "weekly reset day+time" ;; *) bad "weekly reset day+time" "$out" ;; esac
out=$(CONTINUUM_CACHE_MIN=0 CONTINUUM_MOCK="50.0 75.0" hook wk7 '{"session_id":"wk7"}')
[ -z "$out" ] && ok "weekly same tier quiet" || bad "weekly same tier quiet" "$out"
out=$(CONTINUUM_CACHE_MIN=0 CONTINUUM_MOCK="50.0 90.0" hook wk7 '{"session_id":"wk7"}')
check "weekly next tier fires" "weekly window" "$out"
out=$(CONTINUUM_CACHE_MIN=0 CONTINUUM_MOCK="96.0 96.0" hook wk7b '{"session_id":"wk7b"}')
case "$out" in *"also crossed the 95% tier (96% used, resets "[A-Z][a-z][a-z]" "*) ok "weekly reset in combined warning" ;; *) bad "weekly reset in combined warning" "$out" ;; esac

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
    # SIGTERM is asynchronous: give the process up to 2s to exit before calling it alive.
    i=0; while kill -0 "$wl_pid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i+1)); done
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
out=$(printf '{"tool_name":"Agent"}' | CONTINUUM_FRUGAL=1 sh "$ROOT/adapters/claude/frugal-gate.sh" 2>/dev/null)
check "frugal blocks Agent" '"decision":"block"' "$out"
out=$(printf '{"tool_name":"Read"}' | CONTINUUM_FRUGAL=1 sh "$ROOT/adapters/claude/frugal-gate.sh" 2>/dev/null)
[ -z "$out" ] && ok "frugal allows Read" || bad "frugal allows Read" "$out"
out=$(printf '{"tool_name":"Agent"}' | sh "$ROOT/adapters/claude/frugal-gate.sh" 2>/dev/null)
[ -z "$out" ] && ok "no frugal allows Agent" || bad "no frugal allows Agent" "$out"

echo "mid-turn check:"
# PostToolUse: the same warning as Stop, as additionalContext, sharing tiers and flags.
tool() { # tool <state dir> <stdin json> -> stdout
    printf '%s' "$2" | CONTINUUM_STATE_DIR="$TMP/$1" sh "$ROOT/adapters/claude/tool-check.sh" 2>/dev/null || true
}
out=$(tool mt '{"session_id":"mt","tool_name":"Bash"}')
check "mid-turn uses PostToolUse"      '"hookEventName":"PostToolUse"' "$out"
check "mid-turn sends additionalContext" '"additionalContext":"Mid-turn usage check.' "$out"
check "mid-turn keeps claude text"     'use AskUserQuestion' "$out"
case "$out" in *'"decision"'*) bad "mid-turn never blocks" "$out" ;; *) ok "mid-turn never blocks" ;; esac
[ -z "$(tool mt '{"session_id":"mt","tool_name":"Bash"}')" ] && ok "mid-turn fires once per tier" || bad "mid-turn fires once per tier" "warned twice"
[ -z "$(hook mt '{"session_id":"mt"}')" ] && ok "Stop silent after mid-turn warned" || bad "Stop silent after mid-turn warned" "warned twice"
[ -z "$(hook mts '{"session_id":"mts"}' >/dev/null; tool mts '{"session_id":"mts"}')" ] && ok "mid-turn silent after Stop warned" || bad "mid-turn silent after Stop warned" "warned twice"
out=$(tool mta '{"session_id":"mta","agent_id":"a1","agent_type":"Explore"}')
[ -z "$out" ] && ok "mid-turn silent inside a subagent" || bad "mid-turn silent inside a subagent" "$out"
check "subagent does not use up the tier" "Mid-turn usage check" "$(tool mta '{"session_id":"mta"}')"
[ -z "$(CONTINUUM_MOCK="46.0 10.0" tool mtu '{"session_id":"mtu"}')" ] && ok "mid-turn silent under threshold" || bad "mid-turn silent under threshold" "warned"
[ -z "$(CONTINUUM_OFF=1 tool mto '{"session_id":"mto"}')" ] && ok "mid-turn respects CONTINUUM_OFF" || bad "mid-turn respects CONTINUUM_OFF" "warned"
printf '{"session_id":"mtg"}' | CONTINUUM_STATE_DIR=/proc/nonexistent sh "$ROOT/adapters/claude/tool-check.sh" >/dev/null 2>&1 \
    && ok "mid-turn exit 0 on unwritable state dir" || bad "mid-turn exit 0 on unwritable state dir" "non-zero exit"
grep -q 'adapters/claude/tool-check.sh' "$ROOT/hooks/hooks.json" && ok "hooks.json wires the mid-turn check" || bad "hooks.json wires the mid-turn check" "missing"

echo "junie (runs the Claude plugin's hooks):"
# Junie fires PreToolUse (no PostToolUse) and tags every event with project_path.
[ -z "$(tool jc '{"hook_event_name":"PreToolUse","session_id":"jc","tool_name":"Bash"}')" ] && ok "claude skips the PreToolUse duplicate" || bad "claude skips the PreToolUse duplicate" "warned"
out=$(tool jt '{"hook_event_name":"PreToolUse","session_id":"jt","project_path":"/p","tool_name":"Bash"}')
check "junie mid-turn on PreToolUse"   '"hookEventName":"PreToolUse","additionalContext":"Mid-turn usage check.' "$out"
check "junie gets its own hint"        'end your final message by asking' "$out"
case "$out" in *AskUserQuestion*) bad "junie hint has no AskUserQuestion" "$out" ;; *) ok "junie hint has no AskUserQuestion" ;; esac
check "claude stays claude with a nested project_path" 'use AskUserQuestion' "$(tool jn '{"hook_event_name":"PostToolUse","session_id":"jn","transcript_path":"/t.jsonl","tool_input":{"project_path":"/x"}}')"
out=$(hook js '{"hook_event_name":"Stop","session_id":"js","project_path":"/p","stop_hook_active":false}')
check "junie stop blocks with its hint" '{"decision":"block","reason":"[continuum]' "$out"
check "junie stop names the resume preset" 'CONTINUUM_AGENT=junie continuum resume' "$out"
[ -z "$(hook js2 '{"session_id":"js2","project_path":"/p","stop_hook_active":true}')" ] && ok "junie respects stop_hook_active" || bad "junie respects stop_hook_active" "warned"
jcd=$TMP/junie_claude; mkdir -p "$jcd"; printf '{\n  "model": "x"\n}\n' > "$jcd/settings.json"
printf '{"hook_event_name":"SessionStart","project_path":"/p"}' | CLAUDE_CONFIG_DIR="$jcd" CONTINUUM_STATE_DIR="$TMP/jss" sh "$ROOT/adapters/claude/setup-statusline.sh" >/dev/null 2>&1
grep -q statusLine "$jcd/settings.json" && bad "junie leaves Claude settings alone" "statusLine added" || ok "junie leaves Claude settings alone"
printf '{"hook_event_name":"SessionStart"}' | CLAUDE_CONFIG_DIR="$jcd" CONTINUUM_STATE_DIR="$TMP/jss" sh "$ROOT/adapters/claude/setup-statusline.sh" >/dev/null 2>&1
grep -q statusLine "$jcd/settings.json" && ok "claude SessionStart still sets the status line" || bad "claude SessionStart still sets the status line" "not added"

echo "other agents:"
# Every adapter: the reply shape its agent expects, the loop guard, the tier shared
# between its end-of-turn and mid-turn hooks, and silence on any failure.
ad() { # ad <adapter script> <state dir> <stdin json> -> stdout
    printf '%s' "$3" | CONTINUUM_STATE_DIR="$TMP/$2" sh "$ROOT/adapters/$1" 2>/dev/null || true
}
check "codex stop blocks"            '{"decision":"block","reason":"[continuum]' "$(ad codex/stop.sh cx1 '{"session_id":"c1"}')"
[ -z "$(ad codex/stop.sh cx2 '{"session_id":"c2","stop_hook_active":true}')" ] && ok "codex respects stop_hook_active" || bad "codex respects stop_hook_active" "warned"
out=$(ad codex/tool-check.sh cx3 '{"session_id":"c3","tool_name":"shell"}')
check "codex mid-turn context"       '"hookEventName":"PostToolUse","additionalContext":"Mid-turn usage check.' "$out"
[ -z "$(ad codex/stop.sh cx3 '{"session_id":"c3"}')" ] && ok "codex tier shared by both hooks" || bad "codex tier shared by both hooks" "warned twice"
check "gemini after-agent denies"    '{"decision":"deny","reason":"[continuum]' "$(ad gemini/after-agent.sh gm1 '{"session_id":"g1"}')"
[ -z "$(ad gemini/after-agent.sh gm2 '{"session_id":"g2","stop_hook_active":true}')" ] && ok "gemini respects stop_hook_active" || bad "gemini respects stop_hook_active" "warned"
check "gemini mid-turn context"      '"hookEventName":"AfterTool","additionalContext":"Mid-turn usage check.' "$(ad gemini/after-tool.sh gm3 '{"session_id":"g3"}')"
check "cursor stop follows up"       '{"followup_message":"[continuum]' "$(ad cursor/stop.sh cu1 '{"conversation_id":"u1","status":"completed","loop_count":0}')"
[ -z "$(ad cursor/stop.sh cu2 '{"conversation_id":"u2","status":"completed","loop_count":1}')" ] && ok "cursor respects loop_count" || bad "cursor respects loop_count" "warned"
[ -z "$(ad cursor/stop.sh cu3 '{"conversation_id":"u3","status":"aborted","loop_count":0}')" ] && ok "cursor silent after an aborted turn" || bad "cursor silent after an aborted turn" "warned"
check "cursor mid-turn context"      '{"additional_context":"Mid-turn usage check.' "$(ad cursor/tool-check.sh cu4 '{"conversation_id":"u4"}')"
[ -z "$(ad cursor/stop.sh cu4 '{"conversation_id":"u4","status":"completed","loop_count":0}')" ] && ok "cursor tier shared by both hooks" || bad "cursor tier shared by both hooks" "warned twice"
f=0
for a in codex/stop.sh codex/tool-check.sh gemini/after-agent.sh gemini/after-tool.sh cursor/stop.sh cursor/tool-check.sh; do
    [ -z "$(CONTINUUM_OFF=1 ad "$a" off '{"session_id":"o","conversation_id":"o"}')" ] || { bad "$a respects CONTINUUM_OFF" "warned"; f=1; }
    [ -z "$(CONTINUUM_MOCK="46.0 10.0" ad "$a" low '{"session_id":"l","conversation_id":"l"}')" ] || { bad "$a silent under threshold" "warned"; f=1; }
    printf '{"session_id":"x"}' | CONTINUUM_STATE_DIR=/proc/nonexistent sh "$ROOT/adapters/$a" >/dev/null 2>&1 || { bad "$a exit 0 on unwritable state dir" "non-zero exit"; f=1; }
done
[ "$f" = 0 ] && ok "adapters: CONTINUUM_OFF, under threshold, unwritable state dir"
if command -v python3 >/dev/null 2>&1; then
    for a in codex/stop.sh codex/tool-check.sh gemini/after-agent.sh gemini/after-tool.sh cursor/stop.sh cursor/tool-check.sh; do
        out=$(CONTINUUM_MOCK='86.5 41.0' ad "$a" "json$(echo "$a" | tr '/.' '__')" '{"session_id":"j","conversation_id":"j"}')
        printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null || { bad "$a prints valid JSON" "$out"; f=1; }
    done
    [ "$f" = 0 ] && ok "adapters print valid JSON"
fi
if command -v node >/dev/null 2>&1; then
    out=$(CONTINUUM_ROOT="$ROOT" CONTINUUM_STATE_DIR="$TMP/oc" node "$ROOT/tests/opencode.mjs" "$ROOT/adapters/opencode/continuum.js" 2>&1)
    for want in "idle prompts the session" "idle fires once per tier" "child session is skipped" "mid-turn appends to tool output" "off is silent"; do
        check "opencode: $want" "ok $want" "$out"
    done
else
    printf '  skip opencode plugin (no node)\n'
fi

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

sl_out=$(CONTINUUM_STATE_DIR="$sl_dir" sh "$ROOT/adapters/claude/statusline.sh" 2>/dev/null)
check "statusline shows daily percent" "46%" "$sl_out"
check "statusline shows weekly percent" "94%" "$sl_out"
check "statusline shows today for daily" "today" "$sl_out"
esc_=$(printf '\033')
case "$sl_out" in *"${esc_}[0m%"*) bad "statusline no double percent" "got: $sl_out" ;; *) ok "statusline no double percent" ;; esac
CONTINUUM_STATE_DIR="$sl_dir" sh "$ROOT/bin/continuum" statusline format '{d%}% d {dr} | {w%}% w {wr}' >/dev/null
sl_out=$(CONTINUUM_STATE_DIR="$sl_dir" sh "$ROOT/adapters/claude/statusline.sh" 2>/dev/null)
case "$sl_out" in *"${esc_}[0m%"*) bad "statusline legacy format no double percent" "got: $sl_out" ;; *) ok "statusline legacy format no double percent" ;; esac

# A cache past its window's reset (or long untouched) is refreshed in the
# foreground: the very first render already shows current numbers.
sf_dir="$TMP/sl_stale"; mkdir -p "$sf_dir"
printf '5h 12.0 %s\n7d 20.0 %s\n' "$(( now - 60 ))" "$w_reset" > "$sf_dir/.continuum-cache-mock"
sl_out=$(CONTINUUM_STATE_DIR="$sf_dir" CONTINUUM_MOCK="77.0 33.0" sh "$ROOT/adapters/claude/statusline.sh" 2>/dev/null)
check "statusline refreshes past-reset cache before render" "77%" "$sl_out"
printf '5h 12.0 %s\n7d 20.0 %s\n' "$d_reset" "$w_reset" > "$sf_dir/.continuum-cache-mock"
touch -t 202001010000 "$sf_dir/.continuum-cache-mock"
sl_out=$(CONTINUUM_STATE_DIR="$sf_dir" CONTINUUM_MOCK="78.0 33.0" sh "$ROOT/adapters/claude/statusline.sh" 2>/dev/null)
check "statusline refreshes old cache before render" "78%" "$sl_out"
printf '5h 12.0 %s\n7d 20.0 %s\n' "$d_reset" "$w_reset" > "$sf_dir/.continuum-cache-mock"
sl_out=$(CONTINUUM_STATE_DIR="$sf_dir" CONTINUUM_MOCK="79.0 33.0" sh "$ROOT/adapters/claude/statusline.sh" 2>/dev/null)
check "statusline shows fresh cache as-is" "12%" "$sl_out"
# Provider down: keep showing the old cache, leave a .retry marker (backoff),
# and clear it on the next successful refresh.
printf '5h 12.0 %s\n7d 20.0 %s\n' "$(( now - 60 ))" "$w_reset" > "$sf_dir/.continuum-cache-mock"
sl_out=$(CONTINUUM_STATE_DIR="$sf_dir" CONTINUUM_MOCK_FAIL=1 sh "$ROOT/adapters/claude/statusline.sh" 2>/dev/null)
check "statusline keeps old cache when provider fails" "12%" "$sl_out"
[ -f "$sf_dir/.continuum-cache-mock.retry" ] && ok "statusline failed refresh leaves retry marker" || bad "statusline failed refresh leaves retry marker" "missing"
touch -t 202001010000 "$sf_dir/.continuum-cache-mock.retry"
sl_out=$(CONTINUUM_STATE_DIR="$sf_dir" CONTINUUM_MOCK="81.0 33.0" sh "$ROOT/adapters/claude/statusline.sh" 2>/dev/null)
check "statusline retries after backoff" "81%" "$sl_out"
[ ! -f "$sf_dir/.continuum-cache-mock.retry" ] && ok "statusline success clears retry marker" || bad "statusline success clears retry marker" "still there"
printf '5h 12.0 %s\n' "99999999999999999999999" > "$sf_dir/.continuum-cache-mock"
sl_out=$(CONTINUUM_STATE_DIR="$sf_dir" CONTINUUM_MOCK_FAIL=1 sh "$ROOT/adapters/claude/statusline.sh" 2>/dev/null)
check "statusline survives garbage epoch" "12%" "$sl_out"
# 30s gate: a background refresh started seconds ago is not started again.
sg_dir="$TMP/sl_gate"; mkdir -p "$sg_dir"; sg="$sg_dir/.continuum-cache-mock"
printf '5h 12.0 %s\n7d 20.0 %s\n' "$d_reset" "$w_reset" > "$sg"; date +%s > "$sg.at"
CONTINUUM_STATE_DIR="$sg_dir" CONTINUUM_MOCK="55.0 33.0" sh "$ROOT/adapters/claude/statusline.sh" >/dev/null 2>&1
sleep 1; grep -q '^5h 12.0' "$sg" && ok "statusline gate holds within 30s" || bad "statusline gate holds within 30s" "refreshed: $(head -1 "$sg")"
printf '%s' "$(( $(date +%s) - 60 ))" > "$sg.at"
CONTINUUM_STATE_DIR="$sg_dir" CONTINUUM_MOCK="56.0 33.0" sh "$ROOT/adapters/claude/statusline.sh" >/dev/null 2>&1
i=0; while ! grep -q '^5h 56.0' "$sg" && [ $i -lt 20 ]; do sleep 0.2 2>/dev/null || sleep 1; i=$((i+1)); done
grep -q '^5h 56.0' "$sg" && ok "statusline refreshes after the gate" || bad "statusline refreshes after the gate" "$(head -1 "$sg")"
# Leftover tmp files from a killed refresh are swept once old.
: > "$sg.111.tmp"; touch -t 202001010000 "$sg.111.tmp"; : > "$sg.222.tmp"
CONTINUUM_STATE_DIR="$sg_dir" sh "$ROOT/adapters/claude/statusline.sh" >/dev/null 2>&1
[ ! -f "$sg.111.tmp" ] && ok "statusline sweeps old tmp files" || bad "statusline sweeps old tmp files" "left"
[ -f "$sg.222.tmp" ] && ok "statusline keeps fresh tmp files" || bad "statusline keeps fresh tmp files" "removed"

# Test config commands
out=$(CONTINUUM_STATE_DIR="$sl_dir" sh "$ROOT/bin/continuum" statusline)
check "statusline cmd shows format" "format" "$out"

CONTINUUM_STATE_DIR="$sl_dir" sh "$ROOT/bin/continuum" statusline today "сегодня" >/dev/null
sl_out=$(CONTINUUM_STATE_DIR="$sl_dir" sh "$ROOT/adapters/claude/statusline.sh" 2>/dev/null)
check "statusline respects today config" "сегодня" "$sl_out"

CONTINUUM_STATE_DIR="$sl_dir" sh "$ROOT/bin/continuum" statusline reset >/dev/null
sl_out=$(CONTINUUM_STATE_DIR="$sl_dir" sh "$ROOT/adapters/claude/statusline.sh" 2>/dev/null)
check "statusline reset restores defaults" "today" "$sl_out"

# Test format-single (no weekly data)
printf '5h 46.0 %s\n' "$d_reset" > "$sl_dir/.continuum-cache-mock"
sl_out=$(CONTINUUM_STATE_DIR="$sl_dir" sh "$ROOT/adapters/claude/statusline.sh" 2>/dev/null)
check "statusline single shows daily" "46%" "$sl_out"
case "$sl_out" in *94%*) bad "statusline single hides weekly" "found 94% in: $sl_out" ;; *) ok "statusline single hides weekly" ;; esac

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
