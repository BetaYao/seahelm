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

# Keep the bridging header in lockstep with the linked libghostty. Action
# enum ordinals drift when Ghostty adds cases; a stale ghostty.h silently
# misroutes RELOAD_CONFIG and breaks light/dark theme swaps on live panes.
XC_HEADER="$REPO_ROOT/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h"
if [ -f "$XC_HEADER" ]; then
    cp "$XC_HEADER" "$REPO_ROOT/ghostty.h"
    echo "==> Synced ghostty.h from GhosttyKit.xcframework"

    # Re-apply corrections to declarations upstream got wrong, because this sync
    # would otherwise silently restore them. Upstream c5f921bb0 declares a
    # surface parameter `ghostty_surface_free_text` does not take; calling it
    # that way makes the free a no-op and leaks every read_text buffer (measured
    # at 105 MB/h across 19 panes). Idempotent: matches only the upstream form.
    /usr/bin/sed -i '' \
        's|^void ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s\*);|void ghostty_surface_free_text(ghostty_text_s*);|' \
        "$REPO_ROOT/ghostty.h"
    echo "==> Re-applied local ghostty.h declaration fixes"
fi

# The sync above is the moment a wrong upstream declaration enters the build, so
# verify here rather than trusting it. Comparing headers would not help — the
# framework ships the same wrong header — so this compares each declaration
# against the Zig implementation it is supposed to describe.
if [ -f "$REPO_ROOT/scripts/check-ghostty-abi.py" ]; then
    if ! /usr/bin/python3 "$REPO_ROOT/scripts/check-ghostty-abi.py"; then
        echo "==> ghostty.h disagrees with libghostty — see above. Setup aborted." >&2
        exit 1
    fi
fi

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
