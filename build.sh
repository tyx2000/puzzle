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

if [ ! -d "$V/tree-sitter" ] || [ ! -d "$V/material-icon-theme" ]; then
  echo "==> Fetching tree-sitter + grammars + icons"
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

# App icon: generated once from Tools/makeicon.swift + Tools/appicon.jpg,
# then cached.
ICNS="$OBJ/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ "$ROOT/Tools/makeicon.swift" -nt "$ICNS" ] \
   || [ "$ROOT/Tools/appicon.jpg" -nt "$ICNS" ]; then
  echo "==> Generating app icon"
  swiftc -Onone -sdk "$SDK" -target "$TARGET" -framework AppKit \
    "$ROOT/Tools/makeicon.swift" -o "$OBJ/makeicon" 2>/dev/null
  rm -rf "$OBJ/AppIcon.iconset"
  "$OBJ/makeicon" "$OBJ/AppIcon.iconset" "$ROOT/Tools/appicon.jpg" >/dev/null
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

echo "==> Bundling file-tree icons"
python3 "$ROOT/Tools/generate-file-icons.py" "$APP/Contents/Resources"

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
    <key>NSAppleEventsUsageDescription</key>
    <string>Puzzle asks iTerm to open a terminal window for the current project.</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>

    <!-- Without this, Finder's Open With never lists Puzzle: Launch Services
         only offers apps that say which documents they handle.

         `LSHandlerRank` is Alternate throughout on purpose. Owner would put
         Puzzle forward as the default application for every source file on the
         machine, which is not a text editor's call to make; Alternate offers
         it in the list and leaves the default alone. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>    <string>Text Document</string>
            <key>CFBundleTypeRole</key>    <string>Editor</string>
            <key>LSHandlerRank</key>       <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.text</string>
                <string>public.plain-text</string>
                <string>public.source-code</string>
                <string>public.script</string>
                <string>public.json</string>
                <string>public.xml</string>
                <string>public.yaml</string>
                <string>net.daringfireball.markdown</string>
            </array>
        </dict>
        <!-- The languages Puzzle highlights, named outright. Most of these
             conform to public.text and would match the entry above anyway;
             naming them is what makes Puzzle a *recommended* application for
             them in Finder rather than a generic fallback. -->
        <dict>
            <key>CFBundleTypeName</key>    <string>Source Code</string>
            <key>CFBundleTypeRole</key>    <string>Editor</string>
            <key>LSHandlerRank</key>       <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.swift-source</string>
                <string>public.python-script</string>
                <string>public.c-source</string>
                <string>public.c-header</string>
                <string>com.microsoft.typescript</string>
                <string>com.netscape.javascript-source</string>
                <string>public.shell-script</string>
                <string>public.bash-script</string>
                <string>public.zsh-script</string>
                <string>org.iso.sql</string>
                <string>public.toml</string>
                <string>public.css</string>
                <string>public.html</string>
                <string>public.geojson</string>
                <string>public.svg-image</string>
                <string>com.apple.property-list</string>
            </array>
        </dict>
        <!-- Extensions macOS has no type for (.rs, .go, .jsx get an anonymous
             `dyn.` type that conforms to nothing, so even the public.data claim
             below misses them) or types wrongly: a .ts file is
             public.mpeg-2-transport-stream, a video format.
             This entry deliberately carries no LSItemContentTypes — a dict with
             both is matched by its UTI list alone and the extensions are
             ignored, which is why they had no effect when they were listed
             beside one. -->
        <dict>
            <key>CFBundleTypeName</key>    <string>Source File</string>
            <key>CFBundleTypeRole</key>    <string>Editor</string>
            <key>LSHandlerRank</key>       <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>ts</string>   <string>mts</string>  <string>cts</string>
                <string>jsx</string>  <string>cjs</string>  <string>mjs</string>
                <string>rs</string>   <string>go</string>
                <string>jsonc</string><string>scss</string>
                <string>xsl</string>  <string>xslt</string> <string>xsd</string>
                <string>ddl</string>  <string>mysql</string><string>psql</string>
                <string>pyi</string>  <string>pyw</string>
                <string>bashrc</string><string>zshrc</string><string>profile</string>
                <string>csproj</string><string>resx</string>
                <string>dockerfile</string><string>gitignore</string>
                <string>dockerignore</string><string>npmignore</string>
                <string>eslintignore</string><string>prettierignore</string>
                <string>rgignore</string><string>mdx</string>
            </array>
        </dict>
        <!-- Images open in the preview pane, which cannot edit them — so this
             one is a Viewer, not an Editor. -->
        <dict>
            <key>CFBundleTypeName</key>    <string>Image</string>
            <key>CFBundleTypeRole</key>    <string>Viewer</string>
            <key>LSHandlerRank</key>       <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
            </array>
        </dict>
        <!-- Files Launch Services cannot type at all — a Dockerfile, a
             .gitignore, an extensionless script — arrive as public.data. An
             editor should still be offered for them. -->
        <dict>
            <key>CFBundleTypeName</key>    <string>Any Document</string>
            <key>CFBundleTypeRole</key>    <string>Editor</string>
            <key>LSHandlerRank</key>       <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.data</string>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
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
