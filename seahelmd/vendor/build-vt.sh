#!/usr/bin/env bash
# Put libghostty-vt — the release keep-vt is written against — for one target
# into one vendor slice: the static library and the C headers.
#
#   vendor/build-vt.sh <zig-target> <dest-dir>
#   vendor/build-vt.sh x86_64-windows-msvc vendor/libghostty-vt-windows-x86_64
#
# libghostty-vt has a stable C ABI from 1.0 (semantic versioning; within a
# major version releases only add). keep-vt's bindings are still written by
# hand, and src/abi.rs pins every value and layout they use: the build checks
# them against the headers here, so a bump that moved one fails to compile.
#
# Releases come from release.files.ghostty.org (PACKAGING-LIBGHOSTTY.md), each
# file checked against the SHA-256 pinned below, taken from the release's
# SHA256SUMS. macOS uses the prebuilt XCFramework: no Zig needed. Every other
# target is built from the source tarball with the dependency tarball as Zig's
# package directory, so the build fetches nothing: that needs Zig 0.17.
#
# On Windows this runs under Git Bash, and the target is MSVC: that is the
# toolchain the Rust links with, and Zig finds its headers on a machine with
# Visual Studio. Cross-compiling to MSVC from elsewhere does not work.
set -euo pipefail

VERSION="1.0.0"
SOURCE_SHA256="4a6ef758be721923e1969e7b81b443dcc92d8dd3fb5a39600c03a8817a753676"
DEPS_SHA256="4d5ea5e448e4c7ea8fb55ccbaa8668f2a97d44f438cee831e2b7ecd162d85c29"
XCFRAMEWORK_SHA256="2c32b7409b2b6c2ef6cfd606526de357762ad458bdc27134ad074e86506a8bc2"
ZIG_VERSION="0.17"

TARGET="${1:?usage: build-vt.sh <zig-target> <dest-dir>}"
DEST="${2:?usage: build-vt.sh <zig-target> <dest-dir>}"
OPTIMIZE="${GHOSTTY_OPTIMIZE:-ReleaseFast}"
BASE="https://release.files.ghostty.org/libghostty-vt/$VERSION"

# The physical path: macOS's temporary directory is behind a symlink
# (/var -> /private/var), and Zig's build runs its generators by a path
# relative to the source that does not survive it.
work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fetch() {
    local name="$1" want="$2"
    echo "==> $name"
    curl -fsSL --retry 3 "$BASE/$name" -o "$work/$name"
    local got
    got="$(sha256 "$work/$name")"
    if [ "$got" != "$want" ]; then
        echo "build-vt: $name has SHA-256 $got, expected $want" >&2
        exit 1
    fi
}

rm -rf "$DEST"
mkdir -p "$DEST/include"

case "$TARGET" in
  *-macos*)
    # One static library for both Apple architectures, and the headers.
    fetch "ghostty-vt-$VERSION.xcframework.zip" "$XCFRAMEWORK_SHA256"
    (cd "$work" && unzip -q "ghostty-vt-$VERSION.xcframework.zip")
    slice="$work/ghostty-vt.xcframework/macos-arm64_x86_64"
    cp "$slice/libghostty-vt.a" "$DEST/"
    cp -R "$slice/Headers/ghostty" "$DEST/include/"
    ;;
  *)
    command -v zig >/dev/null || { echo "build-vt: zig $ZIG_VERSION is required" >&2; exit 1; }
    case "$(zig version)" in
      "$ZIG_VERSION".*) ;;
      *) echo "build-vt: zig $ZIG_VERSION is required, not $(zig version)" >&2; exit 1 ;;
    esac
    fetch "libghostty-vt-$VERSION.tar.gz" "$SOURCE_SHA256"
    fetch "libghostty-vt-$VERSION-deps.tar.gz" "$DEPS_SHA256"
    tar -xzf "$work/libghostty-vt-$VERSION.tar.gz" -C "$work"
    tar -xzf "$work/libghostty-vt-$VERSION-deps.tar.gz" -C "$work"
    echo "==> zig build for $TARGET ($OPTIMIZE)"
    # A fresh, empty cache: with Zig 0.17 a cache holding a package archive
    # can crash the build, and an empty one proves only --system was used.
    (cd "$work/libghostty-vt-$VERSION" && ZIG_GLOBAL_CACHE_DIR="$work/zig-cache" zig build \
        --prefix "$work/out" \
        --system "$work/libghostty-vt-$VERSION-deps" \
        -Dtarget="$TARGET" -Doptimize="$OPTIMIZE" ${GHOSTTY_ZIG_FLAGS:-})
    # The static library: libghostty-vt.a, or ghostty-vt-static.lib on Windows.
    found=0
    for lib in "$work/out/lib/libghostty-vt.a" "$work/out/lib/ghostty-vt-static.lib"; do
        if [ -f "$lib" ]; then cp "$lib" "$DEST/"; found=1; fi
    done
    [ "$found" = 1 ] || { echo "build-vt: no static library in lib/:" >&2; ls -la "$work/out/lib" >&2; exit 1; }
    cp -R "$work/out/include/ghostty" "$DEST/include/"
    ;;
esac

echo "==> $DEST (libghostty-vt $VERSION)"
ls -la "$DEST"
