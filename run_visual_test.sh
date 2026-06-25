#!/bin/bash
# Visual integration test: verify terminal fills container after spotlight/repo switch
set -e

BUILD_DIR="$(pwd)/.build"
APP="$BUILD_DIR/Build/Products/Debug/seahelm.app"

echo "==> Building seahelm..."
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -derivedDataPath "$BUILD_DIR" build 2>&1 | tail -1

echo "==> Launching seahelm..."
pkill -f "seahelm.app" 2>/dev/null || true
sleep 1
"$APP/Contents/MacOS/seahelm" &
PID=$!
sleep 5

echo "==> Getting window info..."
osascript -e 'tell application "System Events" to tell process "seahelm" to set frontmost to true' 2>/dev/null
sleep 1

# Get repo tab position — second wide button (>50px)
REPO_POS_X=$(osascript -e '
tell application "System Events"
    tell process "seahelm"
        set allBtns to every button of window 1
        set wideCount to 0
        repeat with b in allBtns
            set s to size of b
            if (item 1 of s) > 50 then
                set wideCount to wideCount + 1
                if wideCount = 2 then
                    set p to position of b
                    return (item 1 of p) + (item 1 of s) / 2
                end if
            end if
        end repeat
        return 0
    end tell
end tell
' 2>/dev/null)

REPO_POS_Y=$(osascript -e '
tell application "System Events"
    tell process "seahelm"
        set allBtns to every button of window 1
        set wideCount to 0
        repeat with b in allBtns
            set s to size of b
            if (item 1 of s) > 50 then
                set wideCount to wideCount + 1
                if wideCount = 2 then
                    set p to position of b
                    return (item 2 of p) + (item 2 of s) / 2
                end if
            end if
        end repeat
        return 0
    end tell
end tell
' 2>/dev/null)

REPO_X=${REPO_POS_X:-0}
REPO_Y=${REPO_POS_Y:-0}
echo "Repo tab at: ($REPO_X, $REPO_Y)"

if [ "$REPO_X" -eq 0 ] 2>/dev/null; then
    echo "SKIP: Could not find repo tab button"
    kill $PID 2>/dev/null
    exit 0
fi

echo "==> Clicking repo tab..."
swift -e "
import Foundation; import CoreGraphics
let p = CGPoint(x: $REPO_X, y: $REPO_Y)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.1)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
" 2>/dev/null

echo "==> Waiting for terminal to resize..."
sleep 5

# Find the tmux session with the LARGEST window (the one that was resized for repo view)
SESSION=$(tmux list-sessions -F '#{window_width} #{session_name}' 2>/dev/null | grep 'amux-' | sort -rn | head -1 | awk '{print $2}')
if [ -z "$SESSION" ]; then
    echo "FAIL: No seahelm tmux sessions found"
    kill $PID 2>/dev/null
    exit 1
fi
echo "tmux session: $SESSION"

# Query tmux dimensions
COLS=$(tmux display-message -t "$SESSION" -p '#{window_width}' 2>/dev/null)
ROWS=$(tmux display-message -t "$SESSION" -p '#{window_height}' 2>/dev/null)
echo "tmux reports: ${COLS} columns x ${ROWS} rows"

PASS=true

# A dashboard card is ~432px wide → ~32 columns.
# After switching to repo/spotlight view, terminal should have MORE columns.
# The exact count depends on font size, but it must be > card size.
CARD_COLS=35  # slightly above typical card column count

# Test 1: Column count should be greater than card size
if [ "$COLS" -gt "$CARD_COLS" ]; then
    echo "PASS: columns=$COLS (>$CARD_COLS) — terminal resized beyond card width"
else
    echo "FAIL: columns=$COLS (<=$CARD_COLS) — terminal stuck at card size"
    PASS=false
fi

# Test 2: Row count should be greater than card size (~7 rows)
if [ "$ROWS" -gt 10 ]; then
    echo "PASS: rows=$ROWS (>10) — terminal resized beyond card height"
else
    echo "FAIL: rows=$ROWS (<=10) — terminal stuck at card size"
    PASS=false
fi

# Test 3: Type a long line and verify it renders at full width
FILL_LINE=$(printf 'X%.0s' $(seq 1 "$COLS"))
tmux send-keys -t "$SESSION" "echo '$FILL_LINE'" Enter 2>/dev/null
sleep 1

PANE_CONTENT=$(tmux capture-pane -t "$SESSION" -p 2>/dev/null)
X_LINE_LEN=$(echo "$PANE_CONTENT" | grep -o 'X\{10,\}' | awk '{ print length }' | sort -rn | head -1)

if [ -n "$X_LINE_LEN" ] && [ "$X_LINE_LEN" -ge "$((COLS - 5))" ]; then
    echo "PASS: long line renders at $X_LINE_LEN chars (expected ~$COLS)"
else
    echo "FAIL: long line only ${X_LINE_LEN:-0} chars (expected ~$COLS)"
    PASS=false
fi

# Screenshot for visual inspection
screencapture -x -o /tmp/seahelm-visual-test.png 2>/dev/null
echo "Screenshot: /tmp/seahelm-visual-test.png"

# Cleanup
tmux send-keys -t "$SESSION" C-c 2>/dev/null
kill $PID 2>/dev/null
sleep 1

echo ""
if [ "$PASS" = true ]; then
    echo "=== ALL VISUAL TESTS PASSED ==="
    exit 0
else
    echo "=== VISUAL TESTS FAILED ==="
    exit 1
fi
