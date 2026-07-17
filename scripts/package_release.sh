#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/.build/release}"
SCHEME="${SCHEME:-seahelm}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCH="${ARCH:-$(uname -m)}"
# The git tag being released ("v2.0.3", "v2.0.3-rc1"). CI passes github.ref_name;
# empty for local builds, which keep whatever project.yml declares.
RELEASE_VERSION="${RELEASE_VERSION:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
ENABLE_NOTARIZATION="${ENABLE_NOTARIZATION:-0}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"

case "$ARCH" in
  arm64|x86_64)
    ;;
  *)
    echo "Unsupported ARCH: $ARCH" >&2
    exit 1
    ;;
esac

# Derive the shipped version from the tag so the app can't claim a stale one.
# It used to be pinned in project.yml and updated by hand, so v2.0.1 and v2.0.2
# both shipped identifying themselves as 2.0.0.
#
# CFBundleShortVersionString must be 1-3 dot-separated integers: a prerelease tag
# ("v2.0.3-rc1") ships as its base version ("2.0.3"). Nothing is lost — the tag
# name is what marks the GitHub release as a prerelease.
VERSION_ARGS=()
if [[ -n "$RELEASE_VERSION" ]]; then
  MARKETING_VERSION="${RELEASE_VERSION#v}"
  MARKETING_VERSION="${MARKETING_VERSION%%-*}"
  if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "RELEASE_VERSION='$RELEASE_VERSION' yields '$MARKETING_VERSION', which is not a valid CFBundleShortVersionString" >&2
    exit 1
  fi
  echo "==> Version $MARKETING_VERSION (from tag $RELEASE_VERSION)"
  VERSION_ARGS+=("MARKETING_VERSION=$MARKETING_VERSION")
fi

APP_NAME="seahelm"
ARTIFACT_NAME="${APP_NAME}-macos-${ARCH}.zip"
ARCHIVE_ROOT="$BUILD_DIR/$ARCH"
PRODUCTS_DIR="$ARCHIVE_ROOT/Build/Products/$CONFIGURATION"
APP_PATH="$PRODUCTS_DIR/$APP_NAME.app"
OUTPUT_PATH="${OUTPUT_PATH:-$PROJECT_DIR/dist/$ARTIFACT_NAME}"

sign_app() {
  if [[ -z "$SIGN_IDENTITY" ]]; then
    return
  fi

  echo "==> Signing $APP_NAME.app with identity: $SIGN_IDENTITY"
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"

  codesign --verify --deep --strict "$APP_PATH"
}

notarize_artifact() {
  if [[ "$ENABLE_NOTARIZATION" != "1" ]]; then
    return
  fi

  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "ENABLE_NOTARIZATION=1 requires SIGN_IDENTITY" >&2
    exit 1
  fi

  echo "==> Notarizing $ARTIFACT_NAME"

  if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
    xcrun notarytool submit "$OUTPUT_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  else
    if [[ -z "$APPLE_ID" || -z "$APPLE_APP_SPECIFIC_PASSWORD" || -z "$APPLE_TEAM_ID" ]]; then
      echo "Missing notarization credentials. Set NOTARYTOOL_PROFILE or APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID." >&2
      exit 1
    fi

    xcrun notarytool submit \
      "$OUTPUT_PATH" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --wait
  fi

  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$APP_PATH"

  echo "==> Repackaging stapled app"
  rm -f "$OUTPUT_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_PATH"
}

mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -rf "$ARCHIVE_ROOT" "$OUTPUT_PATH"

echo "==> Building $APP_NAME for $ARCH"
xcodebuild \
  -project "$PROJECT_DIR/seahelm.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$ARCHIVE_ROOT" \
  -destination "generic/platform=macOS" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  ARCHS="$ARCH" \
  ONLY_ACTIVE_ARCH=NO \
  ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found at $APP_PATH" >&2
  exit 1
fi

# The x86_64 slice is cross-compiled on Apple Silicon, where a stray
# ONLY_ACTIVE_ARCH=YES would silently yield an arm64 binary in a zip labelled
# x86_64. Fail loudly instead of shipping the wrong architecture.
echo "==> Verifying $APP_NAME.app is $ARCH"
if ! lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME" | tr ' ' '\n' | grep -qx "$ARCH"; then
  echo "Built binary is $(lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME"), expected $ARCH" >&2
  exit 1
fi

# Same reasoning as the arch check: a version that silently failed to apply looks
# exactly like a successful build until someone opens the About box.
if [[ -n "$RELEASE_VERSION" ]]; then
  echo "==> Verifying $APP_NAME.app reports $MARKETING_VERSION"
  BUILT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$BUILT_VERSION" != "$MARKETING_VERSION" ]]; then
    echo "Built app reports '$BUILT_VERSION', expected '$MARKETING_VERSION' (from tag $RELEASE_VERSION)" >&2
    exit 1
  fi
fi

sign_app

echo "==> Packaging $ARTIFACT_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_PATH"

notarize_artifact

echo "==> Created $OUTPUT_PATH"
