#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Puzzle"
BUNDLE_ID="com.example.puzzle"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

case "$MODE" in
  run|--logs|logs|--telemetry|telemetry|--verify|verify)
    BUILD_MODE="release"
    ;;
  --debug|debug)
    BUILD_MODE="fast"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
"$ROOT_DIR/build.sh" "$BUILD_MODE"

open_app() {
  local launch_bundle="$APP_BUNDLE"
  local installed_bundle="/Applications/$APP_NAME.app"
  # Finder's default file associations point to the installed copy. Keep that
  # copy current and launch it too, so development and Finder opens share one
  # running application and its project-window registry.
  if [[ -d "$installed_bundle" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_bundle/Contents/Info.plist" 2>/dev/null)" == "$BUNDLE_ID" ]]; then
    /usr/bin/ditto "$APP_BUNDLE" "$installed_bundle"
    launch_bundle="$installed_bundle"
  fi
  /usr/bin/open "$launch_bundle"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
esac
