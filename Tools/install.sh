#!/bin/bash
# Install Puzzle.app and the `pz` command.
#
#   ./Tools/install.sh
#
# Copies build/Puzzle.app to /Applications (falling back to ~/Applications if
# that isn't writable) and installs `pz` into a directory that is on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/Puzzle.app"

if [ ! -d "$BUILD" ]; then
  echo "install: $BUILD not found — run ./build.sh release first" >&2
  exit 1
fi

# ── 1. The app ──────────────────────────────────────────────────────────────
if [ -w /Applications ]; then
  APPDIR="/Applications"
else
  APPDIR="$HOME/Applications"
  mkdir -p "$APPDIR"
fi
rm -rf "$APPDIR/Puzzle.app"
cp -R "$BUILD" "$APPDIR/Puzzle.app"
echo "installed $APPDIR/Puzzle.app"

# Launch Services caches what each app claims to open. Replacing the bundle in
# place does not always invalidate that cache, so a freshly declared document
# type can take a logout to show up in Finder's Open With. Registering the new
# bundle explicitly makes it immediate.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APPDIR/Puzzle.app" >/dev/null 2>&1

# ── 2. The pz command ───────────────────────────────────────────────────────
# Pick a directory on the *user's real login PATH* that we can write to.
#
# IMPORTANT: do NOT test against this script's own $PATH. When run from a tool
# or IDE the inherited PATH can contain entries (e.g. ~/.local/bin) that the
# user's Terminal never sees, which silently installs `pz` somewhere their
# shell can't find it. Ask a clean login shell what the real PATH is.
REAL_PATH="$(env -i HOME="$HOME" TERM=xterm /bin/zsh -lic 'printf %s "$PATH"' 2>/dev/null | tr -d '\r')"
[ -z "$REAL_PATH" ] && REAL_PATH="$PATH"

BINDIR=""
for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin" "$HOME/go/bin"; do
  case ":$REAL_PATH:" in
    *":$d:"*) [ -d "$d" ] && [ -w "$d" ] && { BINDIR="$d"; break; } ;;
  esac
done
if [ -z "$BINDIR" ]; then
  BINDIR="$HOME/.local/bin"
  mkdir -p "$BINDIR"
  echo "note: $BINDIR is not on your PATH yet — add this to ~/.zshrc:"
  echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# Bake the build location in as a last-resort fallback.
sed "s|^DEV_BUILD=\"\"|DEV_BUILD=\"$BUILD\"|" "$ROOT/Tools/pz" > "$BINDIR/pz"
chmod +x "$BINDIR/pz"
echo "installed $BINDIR/pz"

# zsh caches command lookups; without this a new binary in an existing PATH
# directory stays "command not found" in shells that are already open.
echo
echo "Done. In shells that are already open, run:  hash -r    (or: rehash)"
