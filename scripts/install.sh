#!/bin/sh
# Seahelm installer — downloads the latest (or given) release and installs
# seahelm.app into /Applications (or ~/Applications without write access).
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

printf '==> Downloading seahelm %s (%s)\n' "$VERSION" "$ARCH"
curl -fSL --progress-bar -o "$TMP/$ASSET" "$URL" \
  || err "download failed: $URL"

printf '==> Unpacking\n'
ditto -x -k "$TMP/$ASSET" "$TMP/unpacked"
[ -d "$TMP/unpacked/seahelm.app" ] || err "archive did not contain seahelm.app"

APP="$DEST/seahelm.app"
if [ -d "$APP" ]; then
  if pgrep -xq seahelm 2>/dev/null; then
    printf '==> Note: seahelm is running; the new version takes effect on next launch\n'
  fi
  rm -rf "$APP"
fi
mv "$TMP/unpacked/seahelm.app" "$APP"

printf '==> Installed %s to %s\n' "$VERSION" "$APP"
printf 'Launch with: open "%s"\n' "$APP"
