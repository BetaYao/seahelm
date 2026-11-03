#!/usr/bin/env bash
# Build libghostty-vt with Zig from the ghostty commit Keep is pinned to, for
# one target, into one vendor slice.
#
#   vendor/build-vt.sh <zig-target> <dest-dir>
#   vendor/build-vt.sh x86_64-windows-msvc vendor/libghostty-vt-windows-x86_64
#
# The pin matters more than the version: libghostty-vt has no stable ABI, and
# `keep-vt` asserts the C struct sizes it was written against. The commit is
# the one the macOS app is built with (kit-mac pins the same one).
#
# On Windows this runs under Git Bash, and the target is MSVC: that is the
# toolchain the Rust links with, and Zig finds its headers on a machine with
# Visual Studio. Cross-compiling to MSVC from elsewhere does not work.
set -euo pipefail

COMMIT="${GHOSTTY_COMMIT:-a53771af0165c34a7bd753ddbcbc5dd7126ee87f}"
TARGET="${1:?usage: build-vt.sh <zig-target> <dest-dir>}"
DEST="${2:?usage: build-vt.sh <zig-target> <dest-dir>}"
OPTIMIZE="${GHOSTTY_OPTIMIZE:-ReleaseFast}"

command -v zig >/dev/null || { echo "zig is required (0.16.0)" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> ghostty $COMMIT"
curl -fsSL "https://github.com/ghostty-org/ghostty/archive/$COMMIT.tar.gz" -o "$work/src.tar.gz"
tar -xzf "$work/src.tar.gz" -C "$work"
src="$work/ghostty-$COMMIT"

echo "==> zig build for $TARGET ($OPTIMIZE)"
(cd "$src" && zig build -Demit-lib-vt=true -Di18n=false -Dtarget="$TARGET" -Doptimize="$OPTIMIZE" ${GHOSTTY_ZIG_FLAGS:-})

rm -rf "$DEST"
mkdir -p "$DEST/include"
# The static library: libghostty-vt.a, or ghostty-vt-static.lib on Windows.
found=0
for lib in "$src/zig-out/lib/libghostty-vt.a" "$src/zig-out/lib/ghostty-vt-static.lib"; do
    if [ -f "$lib" ]; then cp "$lib" "$DEST/"; found=1; fi
done
[ "$found" = 1 ] || { echo "no static library in zig-out/lib:" >&2; ls -la "$src/zig-out/lib" >&2; exit 1; }
cp -R "$src/zig-out/include/." "$DEST/include/"
echo "==> $DEST"
ls -la "$DEST"
