#!/usr/bin/env bash
# Render the social cards: scripts/og-card.html -> site/og.png (English) and
# scripts/og-card.zh.html -> site/og.zh.png (Chinese). Both are 1200x630.
#
# The Chinese card needs a system CJK face, so it renders correctly on macOS and
# on any machine with PingFang/Noto installed — not on a bare CI runner. This is
# a local tool; the committed PNGs are what ship.
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "Chrome not found; set CHROME=<path>" >&2; exit 1; }

render() {  # <source html> <output png>
  "$CHROME" --headless --disable-gpu --hide-scrollbars \
    --window-size=1200,630 --virtual-time-budget=8000 \
    --screenshot="$PWD/$2" "file://$PWD/$1" 2>/dev/null
  echo "wrote $2"
}

render scripts/og-card.html    site/og.png
render scripts/og-card.zh.html site/og.zh.png
