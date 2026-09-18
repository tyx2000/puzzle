#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Gift.app"
ICON_BASENAME="Gift-AppIcon"
SDK="$(xcrun --show-sdk-path)"
V="$ROOT/vendor"
OBJ="$ROOT/.obj"
TARGET="arm64-apple-macos13.0"

# Build mode: "fast" (default, -Onone) for iteration, "release" (-O).
MODE="${1:-fast}"
if [ "$MODE" = "release" ]; then SWIFT_OPT="-O"; else SWIFT_OPT="-Onone"; fi
echo "==> Mode: $MODE ($SWIFT_OPT)"

if [ ! -d "$V/material-icon-theme" ]; then
  echo "==> Fetching file icons"
  "$V/fetch.sh"
fi

mkdir -p "$OBJ"

echo "==> Cleaning app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon: generated once from Tools/makeicon.swift + Tools/appicon.jpg,
# then cached.
ICONSET="$OBJ/$ICON_BASENAME.iconset"
ICNS="$OBJ/$ICON_BASENAME.icns"
if [ ! -f "$ICNS" ] || [ "$ROOT/Tools/makeicon.swift" -nt "$ICNS" ] \
   || [ "$ROOT/Tools/appicon.jpg" -nt "$ICNS" ]; then
  echo "==> Generating app icon"
  swiftc -Onone -sdk "$SDK" -target "$TARGET" -framework AppKit \
    "$ROOT/Tools/makeicon.swift" -o "$OBJ/makeicon" 2>/dev/null
  rm -rf "$ICONSET"
  "$OBJ/makeicon" "$ICONSET" "$ROOT/Tools/appicon.jpg" >/dev/null
  iconutil -c icns "$ICONSET" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/$ICON_BASENAME.icns"

echo "==> Compiling Swift (arm64, $MODE)"
swiftc \
  $SWIFT_OPT \
  -sdk "$SDK" \
  -target "$TARGET" \
  -framework AppKit \
  -framework CoreServices \
  -o "$APP/Contents/MacOS/Gift" \
  "$ROOT"/Sources/*.swift

echo "==> Bundling file icons"
python3 "$ROOT/Tools/generate-file-icons.py" "$APP/Contents/Resources"

echo "==> Bundling the gift command-line launcher"
mkdir -p "$APP/Contents/Resources/bin"
cp "$ROOT/Tools/gift" "$APP/Contents/Resources/bin/gift"
chmod +x "$APP/Contents/Resources/bin/gift"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Gift</string>
    <key>CFBundleDisplayName</key>     <string>Gift</string>
    <key>CFBundleExecutable</key>      <string>Gift</string>
    <key>CFBundleIdentifier</key>      <string>com.example.gift</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>Gift-AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Gift asks iTerm to open a terminal window for the current project.</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>

    <!-- A repository is a folder: that is the one thing Gift opens, so it is
         the one thing it offers to open from Finder. Alternate, so it never
         becomes the default application for folders. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>    <string>Folder</string>
            <key>CFBundleTypeRole</key>    <string>Viewer</string>
            <key>LSHandlerRank</key>       <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
if [ "$MODE" = "release" ]; then
  codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign skipped)"
else
  codesign --force --sign - "$APP/Contents/MacOS/Gift" 2>/dev/null || echo "   (codesign skipped)"
fi

echo "==> Built: $APP"
du -sh "$APP"
