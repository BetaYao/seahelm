#!/bin/bash
# Fetch the pinned arm64 zmx binary to $1, verifying its SHA-256.
# Idempotent: if the destination already matches the pinned binary checksum, skip.
set -euo pipefail

DEST="${1:?usage: fetch-zmx.sh <dest-path>}"
PIN="$(cd "$(dirname "$0")/.." && pwd)/Vendor/zmx.pin"

# shellcheck disable=SC1090
source "$PIN"   # sets VERSION, URL, SHA256

verify() { shasum -a 256 "$1" | awk '{print $1}'; }

# The pinned SHA256 is of the downloaded ASSET (tarball). We keep a marker so we
# can skip re-downloading when DEST is already the extracted binary from this pin.
MARKER="${DEST}.pin-sha"
if [ -f "$DEST" ] && [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$SHA256" ]; then
  echo "fetch-zmx: up to date ($VERSION)"; exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "fetch-zmx: downloading zmx $VERSION"
curl -fsSL -o "$TMP/asset" "$URL"

GOT="$(verify "$TMP/asset")"
if [ "$GOT" != "$SHA256" ]; then
  echo "fetch-zmx: CHECKSUM MISMATCH" >&2
  echo "  expected $SHA256" >&2
  echo "  got      $GOT" >&2
  exit 1
fi

# Extract if tarball, else treat as the raw binary.
case "$URL" in
  *.tar.gz|*.tgz) tar -xzf "$TMP/asset" -C "$TMP"; BIN="$(find "$TMP" -type f -name zmx | head -1)";;
  *)              BIN="$TMP/asset";;
esac
[ -n "${BIN:-}" ] && [ -f "$BIN" ] || { echo "fetch-zmx: no zmx binary in asset" >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
cp "$BIN" "$DEST"
chmod +x "$DEST"
printf '%s' "$SHA256" > "$MARKER"
echo "fetch-zmx: installed $VERSION -> $DEST"
