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
