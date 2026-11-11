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
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-Jfw9OUu27+LJNKOa9RxZJf70cGSyQXCetbWKF9bBxds=}"

APP_NAME="Seahelm GPUI"
BUNDLE_ID="com.seahelm.gpui"
COMPANIONS=(seahelmd seahelm-core seahelm-gateway seahelm seahelm-hook)

# The version: the tag being released, else the AppKit app's in project.yml.
version="${RELEASE_VERSION#v}"
if [[ -z "$version" ]]; then
  version="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' "$PROJECT_DIR/project.yml" | head -1)"
fi
short_version="${version%%-*}"
UPDATER_PACKAGE="$PROJECT_DIR/clients/gpui/updater"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
APP_PATH="$work/$APP_NAME.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks" "$(dirname "$OUTPUT_PATH")"
OUTPUT_PATH="$(cd "$(dirname "$OUTPUT_PATH")" && pwd)/$(basename "$OUTPUT_PATH")"

echo "==> Assembling $APP_NAME.app ($version)"
cp "$GPUI_BIN" "$APP_PATH/Contents/MacOS/seahelm-gpui"
for bin in "${COMPANIONS[@]}"; do
  cp "$DAEMON_DIR/$bin" "$APP_PATH/Contents/MacOS/$bin"
done

echo "==> Building Sparkle updater bridge"
swift build --package-path "$UPDATER_PACKAGE" --configuration release
updater_lib="$(find "$UPDATER_PACKAGE/.build" -path '*/release/libSeahelmGPUIUpdater.dylib' -type f -print -quit)"
sparkle_framework="$(find "$UPDATER_PACKAGE/.build/artifacts" -name Sparkle.framework -type d -print -quit 2>/dev/null)"
[[ -f "$updater_lib" ]] || { echo "Sparkle updater dylib not found under $UPDATER_PACKAGE/.build" >&2; exit 1; }
[[ -d "$sparkle_framework" ]] || { echo "Sparkle.framework not found under $UPDATER_PACKAGE/.build/artifacts" >&2; exit 1; }
cp "$updater_lib" "$APP_PATH/Contents/Frameworks/"
ditto "$sparkle_framework" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
# SwiftPM's dylib refers to Sparkle through @rpath. Resolve it beside the dylib
# when the GPUI executable loads the updater bridge from Contents/Frameworks.
updater_dylib="$APP_PATH/Contents/Frameworks/libSeahelmGPUIUpdater.dylib"
if ! otool -l "$updater_dylib" | grep -Fq 'path @loader_path'; then
  install_name_tool -add_rpath @loader_path "$updater_dylib"
fi

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
  <key>CFBundleVersion</key><string>$short_version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>SUFeedURL</key><string>https://github.com/BetaYao/seahelm/releases/latest/download/appcast-gpui-arm64.xml</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_ED_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><false/>
</dict>
</plist>
EOF

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> Signing with $SIGN_IDENTITY"
  # Inside-out: the helpers first, then the bundle (whose executable is the client).
  for bin in "${COMPANIONS[@]}"; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH/Contents/MacOS/$bin"
  done
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    "$APP_PATH/Contents/Frameworks/libSeahelmGPUIUpdater.dylib"
  sparkle="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  sparkle_nested=(
    "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    "$sparkle/Versions/B/XPCServices/Installer.xpc"
    "$sparkle/Versions/B/Autoupdate"
    "$sparkle/Versions/B/Updater.app"
  )
  for item in "${sparkle_nested[@]}"; do
    if [[ -e "$item" ]]; then
      codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$item"
    fi
  done
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$sparkle"
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
  # The ticket is fetched from Apple's CDN, which drops connections now and
  # then ("The network connection was lost", error 68) after notarization
  # has already been accepted: try a few times before giving up.
  for attempt in 1 2 3 4; do
    if xcrun stapler staple "$APP_PATH"; then
      break
    fi
    [[ $attempt -lt 4 ]] || exit 1
    echo "==> Stapling failed (attempt $attempt); retrying in $((attempt * 15))s" >&2
    sleep $((attempt * 15))
  done
  rm -f "$OUTPUT_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_PATH"
fi

generate_appcast() {
  if [[ -z "$SPARKLE_PRIVATE_KEY" || -z "$RELEASE_VERSION" ]]; then
    echo "==> Missing Sparkle private key or release tag; skipping GPUI appcast"
    return
  fi

  local sign_update
  sign_update="$(find "$UPDATER_PACKAGE/.build/artifacts" -name sign_update -type f -perm -u+x -print -quit 2>/dev/null)"
  [[ -n "$sign_update" ]] || { echo "Sparkle sign_update not found" >&2; exit 1; }
  local attrs
  attrs="$("$sign_update" "$OUTPUT_PATH" --ed-key-file - <<<"$SPARKLE_PRIVATE_KEY")"
  [[ -n "$attrs" ]] || { echo "sign_update produced no GPUI signature" >&2; exit 1; }

  local appcast="$PROJECT_DIR/dist/appcast-gpui-arm64.xml"
  local url="https://github.com/BetaYao/seahelm/releases/download/${RELEASE_VERSION}/seahelm-gpui-macos-arm64.zip"
  local pubdate
  pubdate="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
  cat >"$appcast" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Seahelm GPUI (arm64)</title>
    <link>https://github.com/BetaYao/seahelm</link>
    <description>Seahelm GPUI updates for Apple Silicon</description>
    <language>en</language>
    <item>
      <title>$short_version</title>
      <link>https://github.com/BetaYao/seahelm/releases/tag/$RELEASE_VERSION</link>
      <sparkle:version>$short_version</sparkle:version>
      <sparkle:shortVersionString>$short_version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>$pubdate</pubDate>
      <enclosure url="$url" type="application/octet-stream" $attrs />
    </item>
  </channel>
</rss>
XML
  echo "==> Wrote ${appcast##*/}"
}

generate_appcast

echo "==> $OUTPUT_PATH"
