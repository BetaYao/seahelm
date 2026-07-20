#!/bin/sh
# Seahelm installer — downloads the latest (or given) release and installs
# Seahelm.app into /Applications (or ~/Applications without write access).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/BetaYao/seahelm/main/scripts/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- v2.0.11      # pin a version
#   SEAHELM_INSTALL_DIR=~/Applications sh install.sh  # custom destination
set -eu

REPO="BetaYao/seahelm"
VERSION="${1:-}"

err() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || err "seahelm is macOS-only"

case "$(uname -m)" in
  arm64)  ARCH="arm64" ;;
  x86_64) ARCH="x86_64" ;;
  *) err "unsupported architecture: $(uname -m)" ;;
esac

if [ -z "$VERSION" ]; then
  # GitHub redirects releases/latest to the tagged URL; read the tag from it.
  VERSION=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/$REPO/releases/latest" | sed 's|.*/tag/||')
  [ -n "$VERSION" ] || err "could not determine latest release"
fi

ASSET="seahelm-macos-${ARCH}.zip"
URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"

if [ -n "${SEAHELM_INSTALL_DIR:-}" ]; then
  DEST="$SEAHELM_INSTALL_DIR"
elif [ -w /Applications ]; then
  DEST="/Applications"
else
  DEST="$HOME/Applications"
fi
mkdir -p "$DEST"

TMP=$(mktemp -d /tmp/seahelm-install.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

printf '==> Downloading Seahelm %s (%s)\n' "$VERSION" "$ARCH"
curl -fSL --progress-bar -o "$TMP/$ASSET" "$URL" \
  || err "download failed: $URL"

printf '==> Unpacking\n'
ditto -x -k "$TMP/$ASSET" "$TMP/unpacked"
# The bundle is capitalised (PRODUCT_NAME in project.yml), so match that exactly:
# on a case-sensitive volume a lowercase path fails to find it and the error above
# reads as a corrupt download.
[ -d "$TMP/unpacked/Seahelm.app" ] || err "archive did not contain Seahelm.app"

APP="$DEST/Seahelm.app"
# Installs before 2.0.16 landed as lowercase seahelm.app. A case-insensitive volume
# (the macOS default) resolves both to the same directory, but a case-sensitive one
# would keep the old bundle alongside the new one, so remove it by name too.
for OLD in "$APP" "$DEST/seahelm.app"; do
  [ -d "$OLD" ] || continue
  if pgrep -xq Seahelm 2>/dev/null; then
    printf '==> Note: Seahelm is running; the new version takes effect on next launch\n'
  fi
  rm -rf "$OLD"
done
mv "$TMP/unpacked/Seahelm.app" "$APP"

printf '==> Installed %s to %s\n' "$VERSION" "$APP"
printf 'Launch with: open "%s"\n' "$APP"
