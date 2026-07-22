#!/bin/bash
# Workaround: libtool -static on this machine drops unaligned members.
# Manually combine all .a inputs with ar instead.
set -euo pipefail

GHOSTTY_DIR="$(cd "$(dirname "$0")/.." && pwd)/ghostty"
cd "$GHOSTTY_DIR"

# Build native xcframework (libtool will produce broken fat archive, but we fix it after)
/opt/homebrew/opt/zig@0.15/bin/zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast --verbose 2>&1 | grep "libtool -static" > /tmp/libtool_cmd.txt

# Extract the input archives from the libtool command
LIBTOOL_INPUTS=$(cat /tmp/libtool_cmd.txt | sed 's/.*-o [^ ]* //' | tr ' ' '\n' | grep '\.a$')

WORK=/tmp/combine_archs
rm -rf "$WORK" && mkdir -p "$WORK"

for lib in $LIBTOOL_INPUTS; do
    dir="$WORK/$(basename "$lib" .a)"
    mkdir -p "$dir"
    (cd "$dir" && ar -x "$GHOSTTY_DIR/$lib")
done

chmod -R 755 "$WORK"

OUTPUT="$GHOSTTY_DIR/macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a"
rm -f "$OUTPUT"
cd "$WORK"
find . -name "*.o" -print0 | xargs -0 ar -r "$OUTPUT"
ranlib "$OUTPUT"

# Cache and setup
SHA=$(cd "$GHOSTTY_DIR" && git rev-parse HEAD)
CACHE="$HOME/.cache/seahelm/ghosttykit/$SHA"
rm -rf "$CACHE"
mkdir -p "$CACHE"
cp -R "$GHOSTTY_DIR/macos/GhosttyKit.xcframework" "$CACHE/"

cd "$GHOSTTY_DIR/.."
./scripts/setup.sh

# Symlinks for project.yml's expected paths
ln -sfn macos-arm64 GhosttyKit.xcframework/macos-arm64_x86_64
cd GhosttyKit.xcframework/macos-arm64_x86_64 && ln -sfn libghostty-fat.a libghostty.a

echo "==> GhosttyKit fixed and cached"
