#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEME="seahelm"
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
    -only-testing:seahelmUITests
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
xcodebuild test "${ARGS[@]}" 2>&1 | tee "$PROJECT_DIR/.build/ui-test-output.log"
echo "=== UI tests complete ==="
echo "Results: $PROJECT_DIR/.build/ui-test-results"
