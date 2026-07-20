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
# EdDSA public key baked into Info.plist as SUPublicEDKey. Sparkle refuses to
# start without it, so a build with this empty ships an app whose updater is
# inert — deliberate: an unverified feed is worse than no auto-update.
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"

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

# The bundle is capitalised (PRODUCT_NAME) because it is what users read; the
# release assets stay lowercase so existing download URLs and the workflow's
# hardcoded dist/ paths keep resolving. Two names, deliberately.
APP_NAME="Seahelm"
ARTIFACT_NAME="seahelm-macos-${ARCH}.zip"
ARCHIVE_ROOT="$BUILD_DIR/$ARCH"
PRODUCTS_DIR="$ARCHIVE_ROOT/Build/Products/$CONFIGURATION"
APP_PATH="$PRODUCTS_DIR/$APP_NAME.app"
OUTPUT_PATH="${OUTPUT_PATH:-$PROJECT_DIR/dist/$ARTIFACT_NAME}"

sign_app() {
  if [[ -z "$SIGN_IDENTITY" ]]; then
    return
  fi

  echo "==> Signing $APP_NAME.app with identity: $SIGN_IDENTITY"

  # Sign inside-out. `--deep` does NOT cover standalone executables under
  # Resources/ (Apple treats that directory as data, not code), and the
  # build-phase signing of zmx is skipped here because we build with
  # CODE_SIGNING_ALLOWED=NO. That left zmx unsigned inside an otherwise signed
  # bundle, which notarization rejects as Invalid.
  local nested=("$APP_PATH/Contents/Resources/bin/zmx")
  for binary in "${nested[@]}"; do
    if [[ -f "$binary" ]]; then
      echo "==> Signing nested binary: ${binary#"$APP_PATH/"}"
      codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$binary"
    fi
  done

  # Sparkle ships its own helper executables and XPC services inside the
  # framework. Each is independently loaded code and each needs the hardened
  # runtime plus a secure timestamp of its own; signing only the outer app
  # leaves them stale and notarization rejects the bundle. Order matters —
  # deepest first, because signing a container seals the hashes of everything
  # already inside it.
  local sparkle="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$sparkle" ]]; then
    echo "==> Signing Sparkle helpers"
    local sparkle_nested=(
      "$sparkle/Versions/B/XPCServices/Downloader.xpc"
      "$sparkle/Versions/B/XPCServices/Installer.xpc"
      "$sparkle/Versions/B/Autoupdate"
      "$sparkle/Versions/B/Updater.app"
    )
    for item in "${sparkle_nested[@]}"; do
      if [[ -e "$item" ]]; then
        echo "==> Signing ${item#"$APP_PATH/"}"
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$item"
      fi
    done
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$sparkle"
  fi

  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"

  codesign --verify --deep --strict "$APP_PATH"

  # Catch anything still unsigned or missing the hardened runtime before we pay
  # for a notarization round-trip.
  codesign --verify --verbose=2 "$APP_PATH/Contents/Resources/bin/zmx" 2>&1 | sed 's/^/    /'
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

  # notarytool exits 0 even when Apple rejects the submission, so the status has
  # to be read out of the output. Without this the script sails on to `stapler`,
  # which fails with a generic "Error 65" that says nothing about the real cause.
  # The rejection reason only lives in `notarytool log`, so fetch it before exiting.
  local auth=()
  if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
    auth=(--keychain-profile "$NOTARYTOOL_PROFILE")
  else
    if [[ -z "$APPLE_ID" || -z "$APPLE_APP_SPECIFIC_PASSWORD" || -z "$APPLE_TEAM_ID" ]]; then
      echo "Missing notarization credentials. Set NOTARYTOOL_PROFILE or APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID." >&2
      exit 1
    fi
    auth=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
  fi

  local submit_output
  submit_output="$(xcrun notarytool submit "$OUTPUT_PATH" "${auth[@]}" --wait 2>&1)"
  echo "$submit_output"

  local submission_id
  submission_id="$(printf '%s\n' "$submit_output" | awk '/^ *id: /{print $2; exit}')"

  if ! printf '%s\n' "$submit_output" | grep -q "status: Accepted"; then
    echo "==> Notarization was not accepted; fetching Apple's log" >&2
    if [[ -n "$submission_id" ]]; then
      xcrun notarytool log "$submission_id" "${auth[@]}" >&2 || true
    else
      echo "No submission id found in notarytool output" >&2
    fi
    exit 1
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
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found at $APP_PATH" >&2
  exit 1
fi

# Terminal typography must be self-contained. A fresh install cannot depend on
# fonts or Ghostty configuration already present on the user's Mac.
echo "==> Verifying bundled terminal typography"
for RESOURCE in \
  "ghostty.conf" \
  "JetBrainsMono-Regular.ttf" \
  "JetBrainsMono-Medium.ttf" \
  "JetBrainsMono-Bold.ttf"; do
  if [[ ! -f "$APP_PATH/Contents/Resources/$RESOURCE" ]]; then
    echo "Missing required terminal typography resource: $RESOURCE" >&2
    exit 1
  fi
done
if ! grep -Fqx "font-family = JetBrains Mono" "$APP_PATH/Contents/Resources/ghostty.conf"; then
  echo "Bundled ghostty.conf does not select JetBrains Mono" >&2
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

# The appcast is generated last, from the *final* zip. Signing the pre-staple
# zip would produce a signature for bytes we never ship.
generate_appcast() {
  if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    echo "==> SPARKLE_PRIVATE_KEY unset; skipping appcast (this build cannot be auto-updated to)"
    return
  fi
  if [[ -z "$RELEASE_VERSION" ]]; then
    echo "==> No RELEASE_VERSION; skipping appcast"
    return
  fi

  # sign_update ships inside Sparkle's SPM binary artifact, which lands under the
  # derived data path we just built into.
  local sign_update
  sign_update="$(find "$ARCHIVE_ROOT/SourcePackages/artifacts" -name sign_update -type f -perm -u+x 2>/dev/null | head -1)"
  if [[ -z "$sign_update" ]]; then
    echo "sign_update not found under $ARCHIVE_ROOT/SourcePackages/artifacts" >&2
    exit 1
  fi

  echo "==> Signing $ARTIFACT_NAME for the appcast"
  # sign_update prints an attribute fragment: sparkle:edSignature="..." length="..."
  local attrs
  attrs="$("$sign_update" "$OUTPUT_PATH" --ed-key-file -  <<<"$SPARKLE_PRIVATE_KEY")"
  if [[ -z "$attrs" ]]; then
    echo "sign_update produced no signature" >&2
    exit 1
  fi

  local appcast="$PROJECT_DIR/dist/appcast-${ARCH}.xml"
  local url="https://github.com/BetaYao/seahelm/releases/download/${RELEASE_VERSION}/${ARTIFACT_NAME}"
  # RFC 822 date, which is what the RSS envelope requires.
  local pubdate
  pubdate="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

  echo "==> Writing ${appcast##*/}"
  cat >"$appcast" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Seahelm ($ARCH)</title>
    <link>https://github.com/BetaYao/seahelm</link>
    <description>Seahelm updates for $ARCH</description>
    <language>en</language>
    <item>
      <title>$MARKETING_VERSION</title>
      <link>https://github.com/BetaYao/seahelm/releases/tag/$RELEASE_VERSION</link>
      <sparkle:version>$MARKETING_VERSION</sparkle:version>
      <sparkle:shortVersionString>$MARKETING_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>$pubdate</pubDate>
      <enclosure url="$url" type="application/octet-stream" $attrs />
    </item>
  </channel>
</rss>
XML
}

generate_appcast

echo "==> Created $OUTPUT_PATH"
