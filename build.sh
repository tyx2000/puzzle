#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Puzzle.app"
SDK="$(xcrun --show-sdk-path)"
V="$ROOT/vendor"
TS_INC="$V/tree-sitter/lib/include"
OBJ="$ROOT/.obj"
TARGET="arm64-apple-macos13.0"

# Build mode: "fast" (default, -Onone, ~3.5s) for iteration, "release" (-O).
MODE="${1:-fast}"
if [ "$MODE" = "release" ]; then SWIFT_OPT="-O"; else SWIFT_OPT="-Onone"; fi
echo "==> Mode: $MODE ($SWIFT_OPT)"

if [ ! -d "$V/tree-sitter" ]; then
  echo "==> Fetching tree-sitter + grammars"
  "$V/fetch.sh"
fi

mkdir -p "$OBJ"

# Compile a C source to a cached object only if missing/outdated.
cc_obj() { # out, src, extra-include-dir
  local out="$OBJ/$1"; local src="$2"; local inc="${3:-}"
  if [ ! -f "$out" ] || [ "$src" -nt "$out" ] || [ ! -f "$OBJ/.target" ] || [ "$(cat "$OBJ/.target" 2>/dev/null)" != "$TARGET" ]; then
    echo "   cc $1"
    cc -std=c11 -O2 -fPIC -target "$TARGET" -I "$TS_INC" ${inc:+-I "$inc"} -c "$src" -o "$out"
  fi
}

echo "==> Compiling tree-sitter runtime + grammars"
cc_obj ts_lib.o     "$V/tree-sitter/lib/src/lib.c"                                  "$V/tree-sitter/lib/src"
cc_obj json.o       "$V/tree-sitter-json/src/parser.c"                              "$V/tree-sitter-json/src"
cc_obj bash_p.o     "$V/tree-sitter-bash/src/parser.c"                              "$V/tree-sitter-bash/src"
cc_obj bash_s.o     "$V/tree-sitter-bash/src/scanner.c"                             "$V/tree-sitter-bash/src"
cc_obj yaml_p.o     "$V/tree-sitter-yaml/src/parser.c"                              "$V/tree-sitter-yaml/src"
cc_obj yaml_s.o     "$V/tree-sitter-yaml/src/scanner.c"                             "$V/tree-sitter-yaml/src"
cc_obj ts_p.o       "$V/tree-sitter-typescript/typescript/src/parser.c"            "$V/tree-sitter-typescript/typescript/src"
cc_obj ts_s.o       "$V/tree-sitter-typescript/typescript/src/scanner.c"           "$V/tree-sitter-typescript/typescript/src"
cc_obj tsx_p.o      "$V/tree-sitter-typescript/tsx/src/parser.c"                   "$V/tree-sitter-typescript/tsx/src"
cc_obj tsx_s.o      "$V/tree-sitter-typescript/tsx/src/scanner.c"                  "$V/tree-sitter-typescript/tsx/src"
cc_obj md_p.o       "$V/tree-sitter-markdown/tree-sitter-markdown/src/parser.c"    "$V/tree-sitter-markdown/tree-sitter-markdown/src"
cc_obj md_s.o       "$V/tree-sitter-markdown/tree-sitter-markdown/src/scanner.c"   "$V/tree-sitter-markdown/tree-sitter-markdown/src"
# The inline grammar is a separate parser: the block grammar emits `inline`
# nodes with raw text, and this one parses emphasis/links/code spans inside
# them. Needed by the markdown preview renderer.
cc_obj mdi_p.o      "$V/tree-sitter-markdown/tree-sitter-markdown-inline/src/parser.c"  "$V/tree-sitter-markdown/tree-sitter-markdown-inline/src"
cc_obj mdi_s.o      "$V/tree-sitter-markdown/tree-sitter-markdown-inline/src/scanner.c" "$V/tree-sitter-markdown/tree-sitter-markdown-inline/src"
cc_obj swift_p.o    "$V/tree-sitter-swift/src/parser.c"                            "$V/tree-sitter-swift/src"
cc_obj swift_s.o    "$V/tree-sitter-swift/src/scanner.c"                           "$V/tree-sitter-swift/src"
cc_obj html_p.o     "$V/tree-sitter-html/src/parser.c"                             "$V/tree-sitter-html/src"
cc_obj html_s.o     "$V/tree-sitter-html/src/scanner.c"                            "$V/tree-sitter-html/src"
cc_obj css_p.o      "$V/tree-sitter-css/src/parser.c"                              "$V/tree-sitter-css/src"
cc_obj css_s.o      "$V/tree-sitter-css/src/scanner.c"                             "$V/tree-sitter-css/src"
cc_obj py_p.o       "$V/tree-sitter-python/src/parser.c"                           "$V/tree-sitter-python/src"
cc_obj py_s.o       "$V/tree-sitter-python/src/scanner.c"                          "$V/tree-sitter-python/src"
cc_obj rust_p.o     "$V/tree-sitter-rust/src/parser.c"                             "$V/tree-sitter-rust/src"
cc_obj rust_s.o     "$V/tree-sitter-rust/src/scanner.c"                            "$V/tree-sitter-rust/src"
cc_obj go_p.o       "$V/tree-sitter-go/src/parser.c"                               "$V/tree-sitter-go/src"
cc_obj c_p.o        "$V/tree-sitter-c/src/parser.c"                                "$V/tree-sitter-c/src"
cc_obj toml_p.o     "$V/tree-sitter-toml/src/parser.c"                             "$V/tree-sitter-toml/src"
cc_obj toml_s.o     "$V/tree-sitter-toml/src/scanner.c"                            "$V/tree-sitter-toml/src"
cc_obj xml_p.o      "$V/tree-sitter-xml/xml/src/parser.c"                          "$V/tree-sitter-xml/xml/src"
cc_obj xml_s.o      "$V/tree-sitter-xml/xml/src/scanner.c"                         "$V/tree-sitter-xml/xml/src"
cc_obj sql_p.o      "$V/tree-sitter-sql/src/parser.c"                              "$V/tree-sitter-sql/src"
cc_obj sql_s.o      "$V/tree-sitter-sql/src/scanner.c"                             "$V/tree-sitter-sql/src"
cc_obj dock_p.o     "$V/tree-sitter-dockerfile/src/parser.c"                       "$V/tree-sitter-dockerfile/src"
cc_obj dock_s.o     "$V/tree-sitter-dockerfile/src/scanner.c"                      "$V/tree-sitter-dockerfile/src"
cc_obj gi_p.o       "$V/tree-sitter-gitignore/src/parser.c"                        "$V/tree-sitter-gitignore/src"
echo "$TARGET" > "$OBJ/.target"

echo "==> Cleaning app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/queries"

# App icon: generated once from Tools/makeicon.swift, then cached.
ICNS="$OBJ/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ "$ROOT/Tools/makeicon.swift" -nt "$ICNS" ]; then
  echo "==> Generating app icon"
  swiftc -Onone -sdk "$SDK" -target "$TARGET" -framework AppKit \
    "$ROOT/Tools/makeicon.swift" -o "$OBJ/makeicon" 2>/dev/null
  rm -rf "$OBJ/AppIcon.iconset"
  "$OBJ/makeicon" "$OBJ/AppIcon.iconset" >/dev/null
  iconutil -c icns "$OBJ/AppIcon.iconset" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Compiling Swift (arm64, $MODE)"
swiftc \
  $SWIFT_OPT \
  -sdk "$SDK" \
  -target "$TARGET" \
  -framework AppKit \
  -framework CoreServices \
  -import-objc-header "$ROOT/Sources/ts_bridge.h" \
  -Xcc -I"$TS_INC" \
  -o "$APP/Contents/MacOS/Puzzle" \
  "$ROOT"/Sources/*.swift \
  "$OBJ"/*.o

echo "==> Bundling highlight queries"
cp "$V/tree-sitter-json/queries/highlights.scm"                             "$APP/Contents/Resources/queries/json.scm"
cp "$V/tree-sitter-bash/queries/highlights.scm"                             "$APP/Contents/Resources/queries/bash.scm"
cp "$V/tree-sitter-yaml/queries/highlights.scm"                             "$APP/Contents/Resources/queries/yaml.scm"
cp "$V/tree-sitter-typescript/queries/highlights.scm"                       "$APP/Contents/Resources/queries/typescript.scm"
cp "$ROOT/Queries/typescript_ecma.scm"                                      "$APP/Contents/Resources/queries/typescript_ecma.scm"
cp "$V/tree-sitter-markdown/tree-sitter-markdown/queries/highlights.scm"    "$APP/Contents/Resources/queries/markdown.scm"
cp "$V/tree-sitter-swift/queries/highlights.scm"                            "$APP/Contents/Resources/queries/swift.scm"
cp "$V/tree-sitter-html/queries/highlights.scm"                             "$APP/Contents/Resources/queries/html.scm"
cp "$V/tree-sitter-css/queries/highlights.scm"                              "$APP/Contents/Resources/queries/css.scm"
cp "$V/tree-sitter-python/queries/highlights.scm"                           "$APP/Contents/Resources/queries/python.scm"
cp "$V/tree-sitter-rust/queries/highlights.scm"                             "$APP/Contents/Resources/queries/rust.scm"
cp "$V/tree-sitter-go/queries/highlights.scm"                               "$APP/Contents/Resources/queries/go.scm"
cp "$V/tree-sitter-c/queries/highlights.scm"                                "$APP/Contents/Resources/queries/c.scm"
cp "$V/tree-sitter-toml/queries/highlights.scm"                             "$APP/Contents/Resources/queries/toml.scm"
cp "$V/tree-sitter-xml/queries/xml/highlights.scm"                          "$APP/Contents/Resources/queries/xml.scm"
cp "$V/tree-sitter-sql/queries/highlights.scm"                              "$APP/Contents/Resources/queries/sql.scm"
cp "$V/tree-sitter-dockerfile/queries/highlights.scm"                       "$APP/Contents/Resources/queries/dockerfile.scm"
# gitignore ships no highlight query upstream; ours lives in Queries/.
cp "$ROOT/Queries/gitignore.scm"                                            "$APP/Contents/Resources/queries/gitignore.scm"

echo "==> Bundling the pz command-line launcher"
mkdir -p "$APP/Contents/Resources/bin"
cp "$ROOT/Tools/pz" "$APP/Contents/Resources/bin/pz"
chmod +x "$APP/Contents/Resources/bin/pz"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Puzzle</string>
    <key>CFBundleDisplayName</key>     <string>Puzzle</string>
    <key>CFBundleExecutable</key>      <string>Puzzle</string>
    <key>CFBundleIdentifier</key>      <string>com.example.puzzle</string>
    <key>CFBundleVersion</key>         <string>2.0</string>
    <key>CFBundleShortVersionString</key> <string>2.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
if [ "$MODE" = "release" ]; then
  codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign skipped)"
else
  codesign --force --sign - "$APP/Contents/MacOS/Puzzle" 2>/dev/null || echo "   (codesign skipped)"
fi

echo "==> Built: $APP"
du -sh "$APP"
