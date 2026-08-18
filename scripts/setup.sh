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

# Preflight only matters when we are about to build; a cache hit needs neither
# toolchain. Both of these fail deep inside `zig build` with errors that read as
# Ghostty bugs rather than missing prerequisites, which is why they are checked
# here with the fix spelled out.
preflight_build_tools() {
    local want zig_have
    want="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' "$GHOSTTY_DIR/build.zig.zon" | head -1)"
    if ! command -v zig >/dev/null 2>&1; then
        echo "ERROR: zig not found; Ghostty needs at least ${want:-the pinned version}." >&2
        echo "       brew install zig" >&2
        exit 1
    fi
    zig_have="$(zig version)"
    echo "==> zig $zig_have (ghostty wants >= ${want:-?})"

    # Xcode 26 split the Metal compiler out of the main install, so a machine
    # that builds everything else still cannot compile Ghostty's shaders.
    if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
        echo "ERROR: the Metal compiler is unavailable, so Ghostty's shaders cannot build." >&2
        echo "       xcodebuild -downloadComponent MetalToolchain   # ~690MB, once" >&2
        exit 1
    fi
}

# Check if we have a cached build
if [ -d "$CACHED_XCFRAMEWORK" ]; then
    echo "==> Using cached GhosttyKit.xcframework"
else
    preflight_build_tools
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

    # No local corrections are applied any more. We used to rewrite
    # `ghostty_surface_free_text` to drop the surface parameter its
    # implementation did not take — a mismatch that made the free a no-op and
    # leaked every read_text buffer (105 MB/h across 19 panes). Upstream fixed
    # it from the other side in 12967b68f by giving the implementation the
    # parameter, so re-applying our rewrite here would now break the ABI in the
    # opposite, worse direction: a one-argument call into a two-argument
    # function dereferences whatever x1 happens to hold.
    # scripts/check-ghostty-abi.py below is what keeps either form honest.
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
