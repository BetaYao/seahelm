#!/usr/bin/env bash
# Build seahelmd (seahelmd/) for the architecture being built and install it at
# <dest>, with seahelm-core (the status / cards / First Mate / command service)
# beside it. Run by the "Embed and sign seahelmd" build phase and by CI.
#
#   scripts/build-seahelmd.sh <dest>
#
# The architecture is the first of $ARCHS (Xcode's build setting), else $ARCH
# (package_release.sh), else this machine's. libghostty-vt — the terminal state
# seahelmd keeps — is built once per Ghostty commit and architecture with Zig
# and cached under ~/.cache/seahelm/libghostty-vt (SEAHELMD_VT_CACHE to move it).
#
# Needs cargo (rustup) and, on a cache miss, zig 0.16 and network.
set -euo pipefail

DEST="${1:?usage: build-seahelmd.sh <dest>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE="$ROOT/seahelmd"

# Xcode runs build phases with a bare PATH.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

ARCH="${ARCHS:-${ARCH:-$(uname -m)}}"
ARCH="${ARCH%% *}"
case "$ARCH" in
  arm64|aarch64) TRIPLE=aarch64-apple-darwin; ZIG_TARGET=aarch64-macos ;;
  x86_64)        TRIPLE=x86_64-apple-darwin;  ZIG_TARGET=x86_64-macos ;;
  *) echo "build-seahelmd: unsupported arch $ARCH" >&2; exit 1 ;;
esac

command -v cargo >/dev/null || { echo "build-seahelmd: cargo is required (https://rustup.rs)" >&2; exit 1; }

COMMIT="$(sed -n 's/^COMMIT="\${GHOSTTY_COMMIT:-\([0-9a-f]*\)}"$/\1/p' "$CRATE/vendor/build-vt.sh")"
[ -n "$COMMIT" ] || { echo "build-seahelmd: no pinned Ghostty commit in vendor/build-vt.sh" >&2; exit 1; }
VT="${SEAHELMD_VT_CACHE:-$HOME/.cache/seahelm/libghostty-vt}/${COMMIT:0:12}-$ZIG_TARGET"
if [ ! -f "$VT/libghostty-vt.a" ]; then
  echo "build-seahelmd: building libghostty-vt ${COMMIT:0:12} for $ZIG_TARGET (once)"
  "$CRATE/vendor/build-vt.sh" "$ZIG_TARGET" "$VT"
fi
export KEEP_GHOSTTY_VT_DIR="$VT"

if command -v rustup >/dev/null && ! rustup target list --installed | grep -qx "$TRIPLE"; then
  rustup target add "$TRIPLE"
fi

# Xcode's environment is for Xcode's compilers; keep it out of cargo's.
unset SDKROOT LIBRARY_PATH CPATH LD_LIBRARY_PATH 2>/dev/null || true
# seahelm-core compiles C (SQLite, for reading agent transcripts); with
# Xcode's SDKROOT gone it needs the macOS SDK named again.
if command -v xcrun >/dev/null; then
  SDKROOT="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  [ -n "$SDKROOT" ] && export SDKROOT
fi
cargo build --release --locked --quiet --manifest-path "$CRATE/Cargo.toml" -p seahelmd -p seahelm-core -p seahelm-cli --target "$TRIPLE"
TARGET_DIR="${CARGO_TARGET_DIR:-$CRATE/target}"
mkdir -p "$(dirname "$DEST")"
install -m 755 "$TARGET_DIR/$TRIPLE/release/seahelmd" "$DEST"
install -m 755 "$TARGET_DIR/$TRIPLE/release/seahelm-core" "$(dirname "$DEST")/seahelm-core"
# The `seahelm` command line, which the app installs as ~/.local/bin/seahelm.
install -m 755 "$TARGET_DIR/$TRIPLE/release/seahelm" "$(dirname "$DEST")/seahelm"
