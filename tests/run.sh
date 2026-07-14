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
check "default agent is claude"   'claude --continue -p "finish it"' "$(dry '' 'finish it')"
check "swappable agent"           'sh exec "run it"'                 "$(dry 'sh exec "{prompt}"' 'run it')"
check "template without {prompt}" 'sh --continue'                    "$(dry 'sh --continue' 'ignored')"
check "hostile prompt escaped"    '\"the\"'                        "$(dry 'sh run "{prompt}"' 'fix "the" bug')"
# No dry run here: the PATH check only runs on the real scheduling path.
if CONTINUUM_RESUME_CMD='nosuchagent {prompt}' sh "$ROOT/bin/continuum" resume 23:59 "$ROOT" x >/dev/null 2>&1
then bad "missing agent fails" "exit 0"
else ok  "missing agent fails"; fi

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

# The "fires once per tier (...)" line reflects the configured tiers, not a hardcoded list.
out=$(CONTINUUM_TIERS="50 75" CONTINUUM_THRESHOLD=50 CONTINUUM_MOCK="80.0" hook cti '{"session_id":"cti"}')
check "message lists configured tiers"   "once per tier (50/75)" "$out"
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

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
