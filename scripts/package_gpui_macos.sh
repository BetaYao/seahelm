#!/bin/bash
# Package the GPUI client for macOS as "Seahelm GPUI.app": the client and the
# daemons it starts (seahelmd, seahelm-core, seahelm-gateway, seahelm,
# seahelm-hook) all in Contents/MacOS, where the client looks for them beside
# itself. Signed inside-out and notarized when the credentials are set, the
# same way scripts/package_release.sh does the AppKit app.
#
#   DAEMON_DIR=seahelmd/target/release GPUI_BIN=clients/gpui/target/release/seahelm-gpui \
#   OUTPUT_PATH=dist/seahelm-gpui-macos-arm64.zip scripts/package_gpui_macos.sh
#
# Optional: RELEASE_VERSION (a tag, v-prefix dropped), SIGN_IDENTITY,
# ENABLE_NOTARIZATION=1 with NOTARYTOOL_PROFILE (or APPLE_ID /
# APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID).
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON_DIR="${DAEMON_DIR:?DAEMON_DIR is required}"
GPUI_BIN="${GPUI_BIN:?GPUI_BIN is required}"
OUTPUT_PATH="${OUTPUT_PATH:?OUTPUT_PATH is required}"
RELEASE_VERSION="${RELEASE_VERSION:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
ENABLE_NOTARIZATION="${ENABLE_NOTARIZATION:-0}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"

APP_NAME="Seahelm GPUI"
BUNDLE_ID="com.seahelm.gpui"
COMPANIONS=(seahelmd seahelm-core seahelm-gateway seahelm seahelm-hook)

# The version: the tag being released, else the AppKit app's in project.yml.
version="${RELEASE_VERSION#v}"
if [[ -z "$version" ]]; then
  version="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' "$PROJECT_DIR/project.yml" | head -1)"
fi
short_version="${version%%-*}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
APP_PATH="$work/$APP_NAME.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$(dirname "$OUTPUT_PATH")"
OUTPUT_PATH="$(cd "$(dirname "$OUTPUT_PATH")" && pwd)/$(basename "$OUTPUT_PATH")"

echo "==> Assembling $APP_NAME.app ($version)"
cp "$GPUI_BIN" "$APP_PATH/Contents/MacOS/seahelm-gpui"
for bin in "${COMPANIONS[@]}"; do
  cp "$DAEMON_DIR/$bin" "$APP_PATH/Contents/MacOS/$bin"
done

# The AppKit app's icon, as an .icns.
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
src="$PROJECT_DIR/Assets.xcassets/AppIcon.appiconset"
for pair in 16:16 16@2x:32 32:32 32@2x:64 128:128 128@2x:256 256:256 256@2x:512 512:512 512@2x:1024; do
  name="${pair%%:*}"; px="${pair##*:}"
  base="${name%@2x}"
  suffix=""; [[ "$name" == *@2x ]] && suffix="@2x"
  cp "$src/icon_${px}x${px}.png" "$iconset/icon_${base}x${base}${suffix}.png"
done
iconutil -c icns "$iconset" -o "$APP_PATH/Contents/Resources/AppIcon.icns"

cat > "$APP_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>seahelm-gpui</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$short_version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
EOF

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> Signing with $SIGN_IDENTITY"
  # Inside-out: the helpers first, then the bundle (whose executable is the client).
  for bin in "${COMPANIONS[@]}"; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH/Contents/MacOS/$bin"
  done
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
else
  echo "==> No SIGN_IDENTITY: ad-hoc signature only"
  codesign --force --deep --sign - "$APP_PATH"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_PATH"

if [[ "$ENABLE_NOTARIZATION" == "1" ]]; then
  [[ -n "$SIGN_IDENTITY" ]] || { echo "ENABLE_NOTARIZATION=1 requires SIGN_IDENTITY" >&2; exit 1; }
  auth=()
  if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
    auth=(--keychain-profile "$NOTARYTOOL_PROFILE")
  else
    [[ -n "$APPLE_ID" && -n "$APPLE_APP_SPECIFIC_PASSWORD" && -n "$APPLE_TEAM_ID" ]] \
      || { echo "Missing notarization credentials" >&2; exit 1; }
    auth=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
  fi
  echo "==> Notarizing"
  # notarytool exits 0 on a rejection; read the status, and fetch the log if not accepted.
  out="$(xcrun notarytool submit "$OUTPUT_PATH" "${auth[@]}" --wait 2>&1)"
  echo "$out"
  id="$(printf '%s\n' "$out" | awk '/^ *id: /{print $2; exit}')"
  if ! printf '%s\n' "$out" | grep -q "status: Accepted"; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${auth[@]}" >&2 || true
    exit 1
  fi
  echo "==> Stapling"
  xcrun stapler staple "$APP_PATH"
  rm -f "$OUTPUT_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_PATH"
fi

echo "==> $OUTPUT_PATH"
