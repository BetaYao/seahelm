#!/bin/bash
# zmx-cleanup.sh — Kill all zmx sessions

sessions=$(zmx list 2>&1)

if echo "$sessions" | grep -q "no sessions found"; then
    echo "No zmx sessions to clean up."
    exit 0
fi

count=$(echo "$sessions" | wc -l | tr -d ' ')
echo "Found $count zmx session(s). Cleaning up..."

# Step 1: try graceful kill via zmx
echo "$sessions" | awk -F'\t' '{split($1,a,"="); print a[2]}' | while read -r name; do
    zmx kill "$name" 2>/dev/null && echo "  killed: $name" || echo "  failed: $name (will force kill)"
done

# Step 2: force kill any remaining zmx attach processes
remaining=$(ps aux | grep '[z]mx attach' | awk '{print $2}')
if [ -n "$remaining" ]; then
    echo "Force killing $(echo "$remaining" | wc -l | tr -d ' ') remaining process(es)..."
    echo "$remaining" | xargs kill -9 2>/dev/null
fi

# Step 3: clean up stale socket files
socket_dir="/var/folders/40/hgk5mdr97v35d47cz8jy36y00000gn/T/zmx-501"
if [ -d "$socket_dir" ]; then
    rm -f "$socket_dir"/* 2>/dev/null
    echo "Cleaned socket dir: $socket_dir"
fi

# Verify
final=$(zmx list 2>&1)
if echo "$final" | grep -q "no sessions found"; then
    echo "Done. All zmx sessions cleaned up."
else
    echo "Warning: some sessions may remain:"
    echo "$final"
fi
