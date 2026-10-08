#!/bin/bash
# Builds Gift for Windows with the mingw-w64 cross compiler, and its installer.
#
#   windows/build.sh            optimised build + installer
#   windows/build.sh debug      unoptimised, with symbols, no installer
#
# Needs x86_64-w64-mingw32-g++ (brew install mingw-w64, or MSYS2's
# mingw-w64-x86_64-gcc on Windows), python3, and makensis for the installer.
# The Material Icon Theme is read from vendor/material-icon-theme
# (vendor/fetch.sh fetches it).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
MODE="${1:-release}"
CXX="${CXX:-x86_64-w64-mingw32-g++}"
WINDRES="${WINDRES:-x86_64-w64-mingw32-windres}"
OBJ="$ROOT/.obj/$MODE"
OUT="$ROOT/build"
APP="$OUT/Gift"
DIST="$ROOT/dist"
VERSION="1.0.0"

CXXFLAGS=(-std=c++20 -municode -DUNICODE -D_UNICODE -DNOMINMAX
          -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -Wall -Wextra -Wno-unused-parameter
          -Wno-missing-field-initializers -Wno-cast-function-type)
if [ "$MODE" = "release" ]; then
  CXXFLAGS+=(-O2 -DNDEBUG)
  LDSTRIP=(-s)
else
  CXXFLAGS+=(-O0 -g)
  LDSTRIP=()
fi
LIBS=(-ld2d1 -ldwrite -ld3d11 -ldxgi -ldwmapi -luxtheme -lcomctl32 -lshlwapi -lshell32
      -lole32 -loleaut32 -luuid -lwindowscodecs -lpropsys -lgdi32 -luser32 -lkernel32
      -ladvapi32 -lpsapi)

echo "==> Mode: $MODE ($CXX)"
mkdir -p "$OBJ" "$APP"

if [ ! -d "$REPO/vendor/material-icon-theme" ]; then
  echo "==> Fetching file icons"
  "$REPO/vendor/fetch.sh"
fi

# ── Compile ────────────────────────────────────────────────────────────────
echo "==> Compiling C++"
objects=()
pids=()
for source in "$ROOT"/src/*.cpp; do
  name="$(basename "$source" .cpp)"
  object="$OBJ/$name.o"
  objects+=("$object")
  # Rebuilt when the source or any header is newer than the object.
  newest_header="$(ls -t "$ROOT"/src/*.h | head -1)"
  if [ ! -f "$object" ] || [ "$source" -nt "$object" ] || [ "$newest_header" -nt "$object" ]; then
    "$CXX" "${CXXFLAGS[@]}" -c "$source" -o "$object" &
    pids+=($!)
    # A few at a time.
    if [ "${#pids[@]}" -ge 8 ]; then
      for pid in "${pids[@]}"; do wait "$pid"; done
      pids=()
    fi
  fi
done
for pid in "${pids[@]:-}"; do [ -n "$pid" ] && wait "$pid"; done

echo "==> Compiling resources"
"$WINDRES" -O coff -I "$ROOT/res" "$ROOT/res/gift.rc" -o "$OBJ/gift.res.o"

echo "==> Linking Gift.exe"
"$CXX" -municode -mwindows -static -static-libgcc -static-libstdc++ ${LDSTRIP[@]+"${LDSTRIP[@]}"} \
  -o "$APP/Gift.exe" "${objects[@]}" "$OBJ/gift.res.o" "${LIBS[@]}"

# ── Resources ──────────────────────────────────────────────────────────────
echo "==> Bundling file icons"
rm -rf "$APP/resources"
mkdir -p "$APP/resources"
python3 "$REPO/Tools/generate-file-icons.py" "$APP/resources"

echo "==> Bundling the gift command-line launcher"
mkdir -p "$APP/bin"
# Windows line endings: cmd.exe reads labels and blocks by line.
sed 's/$/\r/' "$ROOT/tools/gift.cmd" > "$APP/bin/gift.cmd"

echo "==> Built: $APP"
du -sh "$APP"

# ── Installer ──────────────────────────────────────────────────────────────
if [ "$MODE" = "release" ]; then
  if command -v makensis >/dev/null 2>&1; then
    echo "==> Building the installer"
    mkdir -p "$DIST"
    LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 makensis -V2 -DVERSION="$VERSION" -DAPPDIR="$APP" -DOUTFILE="$DIST/Gift-Setup-$VERSION-x64.exe" \
      -DICON="$ROOT/res/Gift.ico" "$ROOT/installer/gift.nsi"
    echo "==> Installer: $DIST/Gift-Setup-$VERSION-x64.exe"
    du -sh "$DIST/Gift-Setup-$VERSION-x64.exe"
  else
    echo "   (makensis not found: no installer)"
  fi
fi
