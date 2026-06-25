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

APP="$BUILD_DIR/Build/Products/Debug/seahelm.app"

echo "==> Killing existing Seahelm..."
killall seahelm 2>/dev/null || true
sleep 1

echo "==> Launching Seahelm (Ctrl+C to quit)..."
"$APP/Contents/MacOS/seahelm"
