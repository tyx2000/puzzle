#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QUERIES="$ROOT/build.noindex/Puzzle.app/Contents/Resources/queries"
if [ ! -d "$QUERIES" ]; then
  echo "Build the app first so integration tests have its syntax queries." >&2
  exit 1
fi
mkdir -p "$ROOT/.obj/queries"
cp "$QUERIES"/*.scm "$ROOT/.obj/queries/"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos13.0"
SOURCES=()
for source in "$ROOT"/Sources/*.swift; do
  if [ "$(basename "$source")" != "main.swift" ]; then
    SOURCES+=("$source")
  fi
done

swiftc -Onone \
  -module-cache-path "$ROOT/.obj/module-cache" \
  -sdk "$SDK" \
  -target "$TARGET" \
  -framework AppKit \
  -framework CoreServices \
  -framework AVKit \
  -framework AVFoundation \
  -framework PDFKit \
  -import-objc-header "$ROOT/Sources/ts_bridge.h" \
  -Xcc -I"$ROOT/vendor/tree-sitter/lib/include" \
  -o "$ROOT/.obj/regression-tests" \
  "${SOURCES[@]}" \
  "$ROOT/Tests/RegressionTests.swift" \
  "$ROOT"/.obj/*.o

"$ROOT/.obj/regression-tests" "$@"
