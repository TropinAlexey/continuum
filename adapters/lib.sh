# Shared by the adapters for agents whose hooks are commands speaking JSON on
# stdin/stdout (codex, gemini, cursor). Sourced, not run. An adapter only picks the
# fields of its agent's event and the shape of its agent's reply; everything else
# (tiers, cache, flags, wording) lives in `continuum check`.
#
# Every function fails quietly: an adapter that errors spams the user's transcript,
# so a failure anywhere means the adapter prints nothing and exits 0.

# Prepended to a warning that reaches the agent in the middle of a turn.
# shellcheck disable=SC2034  # used by the adapters that source this file
CNT_MIDTURN_PREFIX="Mid-turn usage check. Finish the step you are on and leave the work in a consistent state (commit or a note), then act on this: "

# Find the code: explicit env, this checkout, or the pointer the CLI leaves in the
# state dir (for copies living in an agent's config dir).
cnt_adapter_root() {
    for r in "${CONTINUUM_ROOT:-}" "$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)"; do
        [ -n "$r" ] && [ -f "$r/bin/continuum" ] && { printf '%s' "$r"; return 0; }
    done
    if [ -n "${CONTINUUM_STATE_DIR:-}" ]; then s="$CONTINUUM_STATE_DIR"
    elif [ -n "${XDG_STATE_HOME:-}" ]; then s="$XDG_STATE_HOME/continuum"
    else s="$HOME/.local/state/continuum"; fi
    r=$(cat "$s/root" 2>/dev/null) && [ -f "$r/bin/continuum" ] && { printf '%s' "$r"; return 0; }
    return 1
}

# cnt_adapter_str <json> <key> -> the first string value of "key", or nothing.
cnt_adapter_str() {
    printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'
}

# cnt_adapter_num <json> <key> -> the first number value of "key", or nothing.
cnt_adapter_num() {
    printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9][0-9]*" | head -1 | sed 's/.*:[[:space:]]*//'
}

# cnt_adapter_true <json> <key> -> success when "key" is true.
cnt_adapter_true() {
    printf '%s' "$1" | grep -q "\"$2\"[[:space:]]*:[[:space:]]*true"
}

# cnt_adapter_warn <root> <session id> <agent> -> the warning text; fails when
# there is nothing to say (no new tier, provider down, anything else).
cnt_adapter_warn() {
    _w=$(sh "$1/bin/continuum" check --session "${2:-unknown}" --agent "$3" 2>/dev/null) || return 1
    [ -n "$_w" ] || return 1
    printf '%s' "$_w"
}

# The provider controls window labels, which end up inside a JSON string. Escape it.
cnt_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r'
}
