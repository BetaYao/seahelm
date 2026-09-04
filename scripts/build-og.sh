#!/usr/bin/env bash
# Render scripts/og-card.html to site/og.png (1200x630 social preview).
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "Chrome not found; set CHROME=<path>" >&2; exit 1; }
"$CHROME" --headless --disable-gpu --hide-scrollbars \
  --window-size=1200,630 --virtual-time-budget=8000 \
  --screenshot="$PWD/site/og.png" "file://$PWD/scripts/og-card.html" 2>/dev/null
echo "wrote site/og.png"
