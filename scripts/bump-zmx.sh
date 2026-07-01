#!/bin/bash
# Bump the pinned bundled zmx version.
#
# Downloads the macOS arm64 release for <version>, verifies it's a real tarball
# containing a zmx binary, computes its SHA-256, and rewrites Vendor/zmx.pin plus
# the bundled MIT license. Does NOT commit — it prints the review/commit steps.
#
# Usage: scripts/bump-zmx.sh <version>     e.g. scripts/bump-zmx.sh 0.7.0
set -euo pipefail

VERSION="${1:?usage: scripts/bump-zmx.sh <version>  (e.g. 0.7.0)}"
VERSION="${VERSION#v}"   # tolerate a leading "v"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/Vendor/zmx.pin"
LICENSE_DEST="$ROOT/Resources/licenses/zmx-LICENSE"
URL="https://zmx.sh/a/zmx-${VERSION}-macos-aarch64.tar.gz"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading $URL"
if ! curl -fsSL -o "$TMP/asset" "$URL"; then
  echo "ERROR: could not download $URL" >&2
  echo "  Check the version and assets at https://github.com/neurosnap/zmx/releases" >&2
  exit 1
fi

# Sanity: must be a gzip tarball with a top-level zmx binary.
if ! tar -tzf "$TMP/asset" 2>/dev/null | grep -qx zmx; then
  echo "ERROR: asset is not a tarball containing a top-level 'zmx' binary" >&2
  exit 1
fi

SHA="$(shasum -a 256 "$TMP/asset" | awk '{print $1}')"
echo "==> Version: $VERSION"
echo "==> SHA-256: $SHA"

cat > "$PIN" <<EOF
VERSION=$VERSION
URL=$URL
SHA256=$SHA
EOF
echo "==> Wrote $PIN"

# License is best-effort: the release tag is v<version>.
if curl -fsSL -o "$TMP/LICENSE" "https://raw.githubusercontent.com/neurosnap/zmx/v${VERSION}/LICENSE"; then
  mkdir -p "$(dirname "$LICENSE_DEST")"
  cp "$TMP/LICENSE" "$LICENSE_DEST"
  echo "==> Updated $LICENSE_DEST"
else
  echo "WARN: could not fetch LICENSE for v${VERSION}; leaving existing license unchanged" >&2
fi

cat <<EOF

Done. Review and commit:
  git diff Vendor/zmx.pin Resources/licenses/zmx-LICENSE
  git add Vendor/zmx.pin Resources/licenses/zmx-LICENSE
  git commit -m "build: bump bundled zmx to $VERSION"

Then rebuild (fetch-zmx.sh pulls + verifies the new binary):
  ./run.sh
EOF
