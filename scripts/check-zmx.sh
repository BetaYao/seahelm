#!/bin/bash
# Check whether a newer zmx release exists than the one pinned in Vendor/zmx.pin.
#
# Exit codes:  0 = up to date (or pin is ahead)   10 = update available   1 = check failed
# Usage: scripts/check-zmx.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/Vendor/zmx.pin"
# shellcheck disable=SC1090
source "$PIN"   # sets VERSION, URL, SHA256
CURRENT="$VERSION"

# Latest release from the tags atom feed (no GitHub API rate limit). Tag titles
# look like "zmx v0.6.0" or "v0.5.0"; take the highest semver.
if ! FEED="$(curl -fsSL --max-time 20 https://github.com/neurosnap/zmx/tags.atom)"; then
  echo "check-zmx: could not reach the tags feed" >&2
  exit 1
fi

LATEST="$(printf '%s' "$FEED" \
  | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
  | sed 's/^v//' \
  | sort -V | tail -1)"

if [ -z "$LATEST" ]; then
  echo "check-zmx: could not parse any version from the feed" >&2
  exit 1
fi

if [ "$CURRENT" = "$LATEST" ]; then
  echo "check-zmx: up to date (pinned $CURRENT is the latest release)"
  exit 0
fi

# Is LATEST actually newer than CURRENT (not older)?
HIGHEST="$(printf '%s\n%s\n' "$CURRENT" "$LATEST" | sort -V | tail -1)"
if [ "$HIGHEST" = "$CURRENT" ]; then
  echo "check-zmx: pinned $CURRENT is newer than the latest published $LATEST (nothing to do)"
  exit 0
fi

echo "check-zmx: UPDATE AVAILABLE — pinned $CURRENT, latest $LATEST"
echo "  bump with: ./scripts/bump-zmx.sh $LATEST && ./run.sh"
exit 10
