#!/bin/bash
set -euo pipefail

BUILD_DIR="$(pwd)/.build"
CLEAN_RESTART=0

usage() {
  echo "Usage: $0 [--clean-restart]"
  echo "  --clean-restart    Remove local build cache before rebuilding"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean-restart)
      CLEAN_RESTART=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$CLEAN_RESTART" -eq 1 ]]; then
  echo "==> Performing clean restart (clearing .build)..."
  rm -rf "$BUILD_DIR"
fi

echo "==> Building Seahelm..."
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -derivedDataPath "$BUILD_DIR" \
  -skipPackagePluginValidation \
  build

# PRODUCT_NAME is Seahelm; on case-insensitive APFS seahelm.app resolves to the same bundle.
APP="$BUILD_DIR/Build/Products/Debug/Seahelm.app"
if [[ ! -d "$APP" ]]; then
  APP="$BUILD_DIR/Build/Products/Debug/seahelm.app"
fi

echo "==> Killing existing Seahelm..."
# PRODUCT_NAME is Seahelm; kill both casings.
# Do NOT pkill `zmx attach` processes here: SIGTERM to an attach client kills
# its session daemon (and the agent running inside) — that was the "restart
# loses all pane content" bug. Orphaned attach clients are harmless; the app
# re-attaches alongside them.
killall Seahelm seahelm 2>/dev/null || true
sleep 1

echo "==> Launching Seahelm (Ctrl+C to quit)..."
# Executable follows PRODUCT_NAME (Seahelm); keep the historical `seahelm`
# path working on case-insensitive APFS via the same bundle.
if [[ -x "$APP/Contents/MacOS/Seahelm" ]]; then
  "$APP/Contents/MacOS/Seahelm"
else
  "$APP/Contents/MacOS/seahelm"
fi
