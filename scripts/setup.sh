#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/ghostty"
CACHE_DIR="$HOME/.cache/seahelm/ghosttykit"

echo "==> Initializing Ghostty submodule..."
cd "$REPO_ROOT"
git submodule update --init --recursive

if [ ! -d "$GHOSTTY_DIR" ]; then
    echo "ERROR: ghostty submodule not found at $GHOSTTY_DIR"
    exit 1
fi

# Get current ghostty commit SHA
GHOSTTY_SHA=$(cd "$GHOSTTY_DIR" && git rev-parse HEAD)
CACHED_XCFRAMEWORK="$CACHE_DIR/$GHOSTTY_SHA/GhosttyKit.xcframework"

echo "==> Ghostty commit: $GHOSTTY_SHA"

# Check if we have a cached build
if [ -d "$CACHED_XCFRAMEWORK" ]; then
    echo "==> Using cached GhosttyKit.xcframework"
else
    echo "==> Building GhosttyKit.xcframework (this may take a few minutes)..."
    cd "$GHOSTTY_DIR"
    # -Demit-macos-app=false: emit-macos-app defaults to emit-xcframework, and we
    # only need the xcframework — building the full Ghostty.app fails on CI's Xcode.
    zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=universal -Doptimize=ReleaseFast

    # Cache the build
    mkdir -p "$CACHE_DIR/$GHOSTTY_SHA"
    cp -R "$GHOSTTY_DIR/macos/GhosttyKit.xcframework" "$CACHED_XCFRAMEWORK"
    echo "==> Cached build at $CACHED_XCFRAMEWORK"
fi

# Symlink to repo root
cd "$REPO_ROOT"
ln -sfn "$CACHED_XCFRAMEWORK" GhosttyKit.xcframework
echo "==> Symlinked GhosttyKit.xcframework"

# Copy Ghostty resources for app bundle
RESOURCES_DIR="$REPO_ROOT/Resources/ghostty"
mkdir -p "$RESOURCES_DIR"

if [ -d "$GHOSTTY_DIR/zig-out/share/ghostty" ]; then
    cp -R "$GHOSTTY_DIR/zig-out/share/ghostty/" "$RESOURCES_DIR/"
    echo "==> Copied Ghostty resources"
fi

if [ -d "$GHOSTTY_DIR/zig-out/share/terminfo" ]; then
    mkdir -p "$RESOURCES_DIR/terminfo"
    cp -R "$GHOSTTY_DIR/zig-out/share/terminfo/" "$RESOURCES_DIR/terminfo/"
    echo "==> Copied terminfo"
fi

echo "==> Setup complete!"
echo "    Open seahelm.xcodeproj in Xcode and build."
