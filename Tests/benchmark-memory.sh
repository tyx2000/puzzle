#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Optional snapshot of Sources enables identical before/after workloads.
SOURCE_DIR="${1:-$ROOT/Sources}"
OUTPUT="${2:-$ROOT/.obj/memory-benchmarks}"
SDK="$(xcrun --show-sdk-path)"
SOURCES=()
for source in "$SOURCE_DIR"/*.swift; do
  if [[ "$(basename "$source")" != main.swift ]]; then SOURCES+=("$source"); fi
done
swiftc -O -sdk "$SDK" -target arm64-apple-macos13.0 \
  -framework AppKit -framework CoreServices -framework AVKit \
  -framework AVFoundation -framework PDFKit \
  -import-objc-header "$SOURCE_DIR/ts_bridge.h" \
  -Xcc -I"$ROOT/vendor/tree-sitter/lib/include" \
  -o "$OUTPUT" "${SOURCES[@]}" "$ROOT/Tests/MemoryBenchmarks.swift" "$ROOT"/.obj/*.o
"$OUTPUT" fixtures
for scenario in audio image lifecycle parser; do "$OUTPUT" "$scenario"; done
