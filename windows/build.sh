#!/bin/bash
# Builds Puzzle for Windows with the mingw-w64 cross compiler, and its installer.
#
#   windows/build.sh            optimised build + installer
#   windows/build.sh debug      unoptimised, with symbols, no installer
#
# Needs x86_64-w64-mingw32-gcc/g++ (brew install mingw-w64, or MSYS2's
# mingw-w64-x86_64-gcc on Windows), python3, curl, git, and makensis for the
# installer. tree-sitter, its grammars, the Material Icon Theme and Scintilla
# are fetched into vendor/ by vendor/fetch.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
V="$REPO/vendor"
MODE="${1:-release}"
CC="${CC:-x86_64-w64-mingw32-gcc}"
CXX="${CXX:-x86_64-w64-mingw32-g++}"
WINDRES="${WINDRES:-x86_64-w64-mingw32-windres}"
OBJ="$ROOT/.obj/$MODE"
OUT="$ROOT/build"
APP="$OUT/Puzzle"
DIST="$ROOT/dist"
VERSION="1.0.0"
JOBS="${JOBS:-8}"

TS_INC="$V/tree-sitter/lib/include"
SCI="$V/scintilla"

CFLAGS=(-std=c11 -I "$TS_INC")
SCIFLAGS=(-std=c++17 -DUNICODE -D_UNICODE -DNOMINMAX -D_WIN32_WINNT=0x0A00
          -I "$SCI/include" -I "$SCI/src" -I "$SCI/win32" -Wno-deprecated-declarations)
CXXFLAGS=(-std=c++20 -municode -DUNICODE -D_UNICODE -DNOMINMAX
          -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -Wall -Wextra -Wno-unused-parameter
          -Wno-missing-field-initializers -Wno-cast-function-type
          -I "$SCI/include" -I "$SCI/src" -I "$TS_INC")
if [ "$MODE" = "release" ]; then
  CFLAGS+=(-O2 -DNDEBUG)
  SCIFLAGS+=(-O2 -DNDEBUG)
  CXXFLAGS+=(-O2 -DNDEBUG)
  LDSTRIP=(-s)
else
  CFLAGS+=(-O0 -g)
  SCIFLAGS+=(-O0 -g)
  CXXFLAGS+=(-O0 -g)
  LDSTRIP=()
fi
LIBS=(-ld2d1 -ldwrite -ld3d11 -ldxgi -ldwmapi -luxtheme -lcomctl32 -lshlwapi -lshell32
      -lole32 -loleaut32 -luuid -lwindowscodecs -lpropsys -lgdi32 -lmsimg32 -limm32
      -luser32 -lkernel32 -ladvapi32 -lpsapi -lmfplat -lmfplay -lmfuuid -lruntimeobject
      -lshcore -lversion)

echo "==> Mode: $MODE ($CXX)"
mkdir -p "$OBJ/ts" "$OBJ/sci" "$OBJ/app" "$APP"

if [ ! -d "$V/tree-sitter" ] || [ ! -d "$V/material-icon-theme" ] || [ ! -d "$SCI" ]; then
  echo "==> Fetching tree-sitter, grammars, icons and Scintilla"
  "$V/fetch.sh"
fi

# Runs up to $JOBS compiles at once; `wait_all` collects them and fails the
# build if any failed.
pids=()
run_job() {
  "$@" &
  pids+=($!)
  if [ "${#pids[@]}" -ge "$JOBS" ]; then wait_all; fi
}
wait_all() {
  local failed=0
  for pid in "${pids[@]:-}"; do
    if [ -n "$pid" ] && ! wait "$pid"; then failed=1; fi
  done
  pids=()
  if [ "$failed" -ne 0 ]; then echo "error: compilation failed" >&2; exit 1; fi
}

# ── tree-sitter runtime and grammars (C) ───────────────────────────────────
echo "==> Compiling tree-sitter runtime + grammars"
ts_objects=()
cc_obj() { # object, source, include dir
  local object="$OBJ/ts/$1"
  ts_objects+=("$object")
  if [ ! -f "$object" ] || [ "$2" -nt "$object" ]; then
    run_job "$CC" "${CFLAGS[@]}" -I "$3" -c "$2" -o "$object"
  fi
}
cc_obj ts_lib.o   "$V/tree-sitter/lib/src/lib.c"                                     "$V/tree-sitter/lib/src"
cc_obj json.o     "$V/tree-sitter-json/src/parser.c"                                 "$V/tree-sitter-json/src"
cc_obj bash_p.o   "$V/tree-sitter-bash/src/parser.c"                                 "$V/tree-sitter-bash/src"
cc_obj bash_s.o   "$V/tree-sitter-bash/src/scanner.c"                                "$V/tree-sitter-bash/src"
cc_obj yaml_p.o   "$V/tree-sitter-yaml/src/parser.c"                                 "$V/tree-sitter-yaml/src"
cc_obj yaml_s.o   "$V/tree-sitter-yaml/src/scanner.c"                                "$V/tree-sitter-yaml/src"
cc_obj ts_p.o     "$V/tree-sitter-typescript/typescript/src/parser.c"               "$V/tree-sitter-typescript/typescript/src"
cc_obj ts_s.o     "$V/tree-sitter-typescript/typescript/src/scanner.c"              "$V/tree-sitter-typescript/typescript/src"
cc_obj tsx_p.o    "$V/tree-sitter-typescript/tsx/src/parser.c"                      "$V/tree-sitter-typescript/tsx/src"
cc_obj tsx_s.o    "$V/tree-sitter-typescript/tsx/src/scanner.c"                     "$V/tree-sitter-typescript/tsx/src"
cc_obj md_p.o     "$V/tree-sitter-markdown/tree-sitter-markdown/src/parser.c"       "$V/tree-sitter-markdown/tree-sitter-markdown/src"
cc_obj md_s.o     "$V/tree-sitter-markdown/tree-sitter-markdown/src/scanner.c"      "$V/tree-sitter-markdown/tree-sitter-markdown/src"
# The inline grammar parses emphasis, links and code spans inside the block
# grammar's `inline` nodes.
cc_obj mdi_p.o    "$V/tree-sitter-markdown/tree-sitter-markdown-inline/src/parser.c"  "$V/tree-sitter-markdown/tree-sitter-markdown-inline/src"
cc_obj mdi_s.o    "$V/tree-sitter-markdown/tree-sitter-markdown-inline/src/scanner.c" "$V/tree-sitter-markdown/tree-sitter-markdown-inline/src"
cc_obj swift_p.o  "$V/tree-sitter-swift/src/parser.c"                               "$V/tree-sitter-swift/src"
cc_obj swift_s.o  "$V/tree-sitter-swift/src/scanner.c"                              "$V/tree-sitter-swift/src"
cc_obj html_p.o   "$V/tree-sitter-html/src/parser.c"                                "$V/tree-sitter-html/src"
cc_obj html_s.o   "$V/tree-sitter-html/src/scanner.c"                               "$V/tree-sitter-html/src"
cc_obj css_p.o    "$V/tree-sitter-css/src/parser.c"                                 "$V/tree-sitter-css/src"
cc_obj css_s.o    "$V/tree-sitter-css/src/scanner.c"                                "$V/tree-sitter-css/src"
cc_obj py_p.o     "$V/tree-sitter-python/src/parser.c"                              "$V/tree-sitter-python/src"
cc_obj py_s.o     "$V/tree-sitter-python/src/scanner.c"                             "$V/tree-sitter-python/src"
cc_obj rust_p.o   "$V/tree-sitter-rust/src/parser.c"                                "$V/tree-sitter-rust/src"
cc_obj rust_s.o   "$V/tree-sitter-rust/src/scanner.c"                               "$V/tree-sitter-rust/src"
cc_obj go_p.o     "$V/tree-sitter-go/src/parser.c"                                  "$V/tree-sitter-go/src"
cc_obj c_p.o      "$V/tree-sitter-c/src/parser.c"                                   "$V/tree-sitter-c/src"
cc_obj toml_p.o   "$V/tree-sitter-toml/src/parser.c"                                "$V/tree-sitter-toml/src"
cc_obj toml_s.o   "$V/tree-sitter-toml/src/scanner.c"                               "$V/tree-sitter-toml/src"
cc_obj xml_p.o    "$V/tree-sitter-xml/xml/src/parser.c"                             "$V/tree-sitter-xml/xml/src"
cc_obj xml_s.o    "$V/tree-sitter-xml/xml/src/scanner.c"                            "$V/tree-sitter-xml/xml/src"
cc_obj sql_p.o    "$V/tree-sitter-sql/src/parser.c"                                 "$V/tree-sitter-sql/src"
cc_obj sql_s.o    "$V/tree-sitter-sql/src/scanner.c"                                "$V/tree-sitter-sql/src"
cc_obj dock_p.o   "$V/tree-sitter-dockerfile/src/parser.c"                          "$V/tree-sitter-dockerfile/src"
cc_obj dock_s.o   "$V/tree-sitter-dockerfile/src/scanner.c"                         "$V/tree-sitter-dockerfile/src"
cc_obj gi_p.o     "$V/tree-sitter-gitignore/src/parser.c"                           "$V/tree-sitter-gitignore/src"
wait_all

# ── Scintilla (the editing component, statically linked) ──────────────────
echo "==> Compiling Scintilla"
sci_objects=()
for source in "$SCI"/src/*.cxx "$SCI"/win32/PlatWin.cxx "$SCI"/win32/ScintillaWin.cxx \
              "$SCI"/win32/HanjaDic.cxx "$SCI"/win32/ListBox.cxx "$SCI"/win32/SurfaceD2D.cxx \
              "$SCI"/win32/SurfaceGDI.cxx; do
  object="$OBJ/sci/$(basename "$source" .cxx).o"
  sci_objects+=("$object")
  if [ ! -f "$object" ] || [ "$source" -nt "$object" ]; then
    run_job "$CXX" "${SCIFLAGS[@]}" -c "$source" -o "$object"
  fi
done
wait_all

# ── Puzzle ─────────────────────────────────────────────────────────────────
echo "==> Compiling Puzzle"
app_objects=()
newest_header="$(ls -t "$ROOT"/src/*.h | head -1)"
for source in "$ROOT"/src/*.cpp; do
  object="$OBJ/app/$(basename "$source" .cpp).o"
  app_objects+=("$object")
  # Rebuilt when the source or any header is newer than the object.
  if [ ! -f "$object" ] || [ "$source" -nt "$object" ] || [ "$newest_header" -nt "$object" ]; then
    run_job "$CXX" "${CXXFLAGS[@]}" -c "$source" -o "$object"
  fi
done
wait_all

echo "==> Compiling resources"
"$WINDRES" -O coff -I "$ROOT/res" "$ROOT/res/puzzle.rc" -o "$OBJ/puzzle.res.o"

echo "==> Linking Puzzle.exe"
"$CXX" -municode -mwindows -static -static-libgcc -static-libstdc++ ${LDSTRIP[@]+"${LDSTRIP[@]}"} \
  -o "$APP/Puzzle.exe" "${app_objects[@]}" "${sci_objects[@]}" "${ts_objects[@]}" "$OBJ/puzzle.res.o" \
  "${LIBS[@]}"

# ── Resources ──────────────────────────────────────────────────────────────
echo "==> Bundling highlight queries"
Q="$APP/resources/queries"
rm -rf "$APP/resources"
mkdir -p "$Q"
cp "$V/tree-sitter-json/queries/highlights.scm"                          "$Q/json.scm"
cp "$V/tree-sitter-bash/queries/highlights.scm"                          "$Q/bash.scm"
cp "$V/tree-sitter-yaml/queries/highlights.scm"                          "$Q/yaml.scm"
cp "$V/tree-sitter-typescript/queries/highlights.scm"                    "$Q/typescript.scm"
cp "$REPO/Queries/typescript_ecma.scm"                                   "$Q/typescript_ecma.scm"
cp "$V/tree-sitter-markdown/tree-sitter-markdown/queries/highlights.scm" "$Q/markdown.scm"
cp "$V/tree-sitter-swift/queries/highlights.scm"                         "$Q/swift.scm"
cp "$V/tree-sitter-html/queries/highlights.scm"                          "$Q/html.scm"
cp "$V/tree-sitter-css/queries/highlights.scm"                           "$Q/css.scm"
cp "$V/tree-sitter-python/queries/highlights.scm"                        "$Q/python.scm"
cp "$V/tree-sitter-rust/queries/highlights.scm"                          "$Q/rust.scm"
cp "$V/tree-sitter-go/queries/highlights.scm"                            "$Q/go.scm"
cp "$V/tree-sitter-c/queries/highlights.scm"                             "$Q/c.scm"
cp "$V/tree-sitter-toml/queries/highlights.scm"                          "$Q/toml.scm"
cp "$V/tree-sitter-xml/queries/xml/highlights.scm"                       "$Q/xml.scm"
cp "$V/tree-sitter-sql/queries/highlights.scm"                           "$Q/sql.scm"
cp "$V/tree-sitter-dockerfile/queries/highlights.scm"                    "$Q/dockerfile.scm"
# gitignore ships no highlight query upstream; ours lives in Queries/.
cp "$REPO/Queries/gitignore.scm"                                         "$Q/gitignore.scm"

echo "==> Bundling file-tree icons"
python3 "$REPO/Tools/generate-file-icons.py" "$APP/resources"

echo "==> Bundling the pz command-line launcher"
mkdir -p "$APP/bin"
# Windows line endings: cmd.exe reads labels and blocks by line.
sed 's/$/\r/' "$ROOT/tools/pz.cmd" > "$APP/bin/pz.cmd"

echo "==> Built: $APP"
du -sh "$APP"

# ── Installer ──────────────────────────────────────────────────────────────
if [ "$MODE" = "release" ]; then
  if command -v makensis >/dev/null 2>&1; then
    echo "==> Building the installer"
    mkdir -p "$DIST"
    LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 makensis -V2 -DVERSION="$VERSION" -DAPPDIR="$APP" \
      -DOUTFILE="$DIST/Puzzle-Setup-$VERSION-x64.exe" -DICON="$ROOT/res/Puzzle.ico" \
      "$ROOT/installer/puzzle.nsi"
    echo "==> Installer: $DIST/Puzzle-Setup-$VERSION-x64.exe"
    du -sh "$DIST/Puzzle-Setup-$VERSION-x64.exe"
  else
    echo "   (makensis not found: no installer)"
  fi
fi
