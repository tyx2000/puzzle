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

mkdir -p "$ROOT/.obj"
swiftc -Onone \
  -sdk "$SDK" \
  -target "$TARGET" \
  -framework AppKit \
  -framework CoreServices \
  -o "$ROOT/.obj/regression-tests" \
  "${SOURCES[@]}" \
  "$ROOT/Tests/RegressionTests.swift"

"$ROOT/.obj/regression-tests"
