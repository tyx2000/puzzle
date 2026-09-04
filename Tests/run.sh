#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos13.0"
SOURCES=()
for source in "$ROOT"/Sources/*.swift; do
  if [ "$(basename "$source")" != "main.swift" ]; then
    SOURCES+=("$source")
  fi
done

swiftc -Onone \
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

"$ROOT/.obj/regression-tests"
