#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEME="seahelmUITests"
DESTINATION="platform=macOS"
TEST_FILTER="${1:-}"

# Ensure Xcode project is up to date
if command -v xcodegen &> /dev/null; then
    echo "=== Generating Xcode project ==="
    cd "$PROJECT_DIR" && xcodegen generate
else
    if [ ! -d "$PROJECT_DIR/seahelm.xcodeproj" ]; then
        echo "Error: seahelm.xcodeproj not found and xcodegen is not installed."
        echo "Install with: brew install xcodegen"
        exit 1
    fi
fi

mkdir -p "$PROJECT_DIR/.build"
rm -rf "$PROJECT_DIR/.build/ui-test-results"

ARGS=(
    -project "$PROJECT_DIR/seahelm.xcodeproj"
    -scheme "$SCHEME"
    -destination "$DESTINATION"
    -resultBundlePath "$PROJECT_DIR/.build/ui-test-results"
)

if [ -n "$TEST_FILTER" ]; then
    ARGS=(
        -project "$PROJECT_DIR/seahelm.xcodeproj"
        -scheme "$SCHEME"
        -destination "$DESTINATION"
        -only-testing:"seahelmUITests/$TEST_FILTER"
        -resultBundlePath "$PROJECT_DIR/.build/ui-test-results"
    )
fi

echo "=== Building and running UI tests ==="
set +e
xcodebuild test "${ARGS[@]}" -derivedDataPath "$PROJECT_DIR/.build" -skipPackagePluginValidation -skipMacroValidation \
    2>&1 | tee "$PROJECT_DIR/.build/ui-test-output.log"
status=${PIPESTATUS[0]}
set -e

# Each test launched the app in a scratch home under /tmp/shui-* (UITests'
# ScratchHome): end the core and seahelmd daemons it left there, then remove it.
for dir in /tmp/shui-*; do
    [ -d "$dir" ] || continue
    pids=$(lsof -t +D "$dir" 2>/dev/null | sort -u || true)
    [ -n "$pids" ] && { kill $pids 2>/dev/null || true; }
    rm -rf -- "$dir"
done

echo "=== UI tests complete ==="
echo "Results: $PROJECT_DIR/.build/ui-test-results"
exit "$status"
