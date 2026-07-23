#!/usr/bin/env bash
# flash.sh — one-shot build/flash for the Seahelm watch firmware.
#
# Wraps the three environment quirks of this machine's ESP-IDF setup:
#   1. toolchain lives on the external drive, not ~/.espressif
#   2. the IDF venv is Python 3.11, but PATH's default python3 is homebrew 3.14
#   3. idf.py's `env python` shebang needs a `python` on PATH
#
# Usage:
#   ./flash.sh                 # build + flash + monitor (default port)
#   ./flash.sh build           # build only
#   ./flash.sh flash           # flash only (assumes a prior build)
#   ./flash.sh monitor         # serial monitor only
#   ./flash.sh build flash     # any subset of idf.py targets, in order
#   PORT=/dev/cu.usbmodemXXXX ./flash.sh   # override the serial port
#
# Ctrl-] exits the monitor.

set -euo pipefail

# ── config (override via env) ────────────────────────────────────────────────
IDF_PATH_DEFAULT=/Volumes/openbeta/esp/esp-idf
IDF_TOOLS_DEFAULT=/Volumes/openbeta/esp/espressif
PY311_DEFAULT=/opt/homebrew/bin/python3.11
PORT="${PORT:-/dev/cu.usbmodem1101}"

export IDF_PATH="${IDF_PATH:-$IDF_PATH_DEFAULT}"
export IDF_TOOLS_PATH="${IDF_TOOLS_PATH:-$IDF_TOOLS_DEFAULT}"
PY311="${PY311:-$PY311_DEFAULT}"

# ── sanity ───────────────────────────────────────────────────────────────────
[ -f "$IDF_PATH/export.sh" ] || { echo "!! ESP-IDF not at $IDF_PATH (set IDF_PATH=)"; exit 1; }
[ -x "$PY311" ] || { echo "!! python3.11 not at $PY311 (set PY311=)"; exit 1; }
cd "$(dirname "$0")"

# ── python 3.11 shim so export.sh detects the matching venv ──────────────────
SHIM="$(mktemp -d)"; trap 'rm -rf "$SHIM"' EXIT
ln -sf "$PY311" "$SHIM/python3"
ln -sf "$PY311" "$SHIM/python"
export PATH="$SHIM:$PATH"

echo ">> IDF_PATH=$IDF_PATH"
echo ">> IDF_TOOLS_PATH=$IDF_TOOLS_PATH"
echo ">> python3 -> $($SHIM/python3 --version 2>&1)"
echo ">> port=$PORT"

# ── source the IDF environment ───────────────────────────────────────────────
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" >/dev/null 2>&1 || {
    echo "!! export.sh failed; re-running verbosely:"; . "$IDF_PATH/export.sh"; exit 1;
}

# ── run requested targets (default: build flash monitor) ─────────────────────
TARGETS=("$@"); [ ${#TARGETS[@]} -eq 0 ] && TARGETS=(build flash monitor)
echo ">> idf.py -p $PORT ${TARGETS[*]}"
exec idf.py -p "$PORT" "${TARGETS[@]}"
