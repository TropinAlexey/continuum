#!/bin/sh
# continuum installer for macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.sh | sh
#
# What it does, and nothing else:
#   1. copies continuum into ~/.continuum
#   2. links the `continuum` command into a directory on your PATH
#   3. tells you the one line to turn on the Claude Code warning (optional)
#
# No sudo unless your PATH dir needs it. No daemon. Re-run any time to update.
set -eu

REPO="https://github.com/TropinAlexey/continuum"
DEST="${CONTINUUM_HOME:-$HOME/.continuum}"

say()  { printf '  %s\n' "$1"; }
die()  { printf 'continuum install: %s\n' "$1" >&2; exit 1; }

printf '\ncontinuum installer\n\n'

# --- 1. get the files -------------------------------------------------
# Prefer running from a clone; otherwise download.
# Piped from curl, $0 is "sh" and dirname is "." - the current directory, which is
# not a source of anything. Only trust $0 when it is the script we are running.
here=""
[ -f "$0" ] && here=$(unset CDPATH; cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
if [ -n "$here" ] && [ -f "$here/bin/continuum" ]; then
    say "copying from $here"
    mkdir -p "$DEST"
    for d in bin lib providers hooks skills; do
        [ -d "$here/$d" ] && cp -R "$here/$d" "$DEST/"
    done
elif command -v git >/dev/null 2>&1; then
    if [ -d "$DEST/.git" ]; then
        say "updating $DEST"
        git -C "$DEST" pull --quiet --ff-only || die "could not update $DEST"
    else
        say "cloning into $DEST"
        rm -rf "$DEST"
        git clone --quiet --depth 1 "$REPO" "$DEST" || die "git clone failed"
    fi
else
    die "need either a local checkout or git installed"
fi

chmod +x "$DEST/bin/continuum" "$DEST/hooks/"*.sh "$DEST/providers/"*.sh 2>/dev/null || true

# --- 2. put `continuum` on the PATH -----------------------------------
# First writable directory already on PATH wins; else fall back to ~/.local/bin.
target=""
for d in "$HOME/.local/bin" /usr/local/bin "$HOME/bin"; do
    case ":$PATH:" in *":$d:"*) [ -d "$d" ] && [ -w "$d" ] && { target="$d"; break; } ;; esac
done
if [ -z "$target" ]; then
    target="$HOME/.local/bin"
    mkdir -p "$target"
fi

ln -sf "$DEST/bin/continuum" "$target/continuum"
say "linked: $target/continuum"

case ":$PATH:" in
    *":$target:"*) ;;
    *) printf '\n  Add this to your shell profile, then reopen the terminal:\n    export PATH="%s:$PATH"\n' "$target" ;;
esac

# --- 3. done ----------------------------------------------------------
printf '\nDone. Try it:\n\n  continuum status\n  continuum watch\n\n'
printf 'Using Claude Code and want the automatic warning? Add this once,\n'
printf 'inside Claude Code:\n\n  /plugin marketplace add TropinAlexey/continuum\n  /plugin install continuum\n\n'
