#!/usr/bin/env bash
# Encode the hero loop for site/ from a full-resolution screen recording.
#
# The master recording is NOT in this repo (it is ~76 MB of 1920x1080 h264).
# Keep it wherever you keep raw footage and pass the path in:
#
#   scripts/build-loop.sh ~/Downloads/"Recording 2026-08-21 at 20.48.15.mp4"
#
# CROP is the seahelm window plus the Island pill floating above it, measured
# on that recording — it drops the desktop wallpaper and the screen-recording
# border. Re-measure if you shoot new footage.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:?usage: build-loop.sh <recording.mp4> [start_seconds] [duration]}"
START="${2:-28.5}"
DUR="${3:-7.5}"
CROP="1380:890:250:64"

echo "==> source: $SRC  (${START}s +${DUR}s, crop ${CROP})"

# H.264 only. VP9 came out *larger* than x264 on this footage, so a second
# encode would be bytes for nothing; mp4/h264 plays everywhere that matters.
ffmpeg -v error -ss "$START" -t "$DUR" -i "$SRC" \
  -vf "crop=${CROP}" -an \
  -c:v libx264 -profile:v high -pix_fmt yuv420p -crf 26 -preset slow \
  -movflags +faststart -y site/tour-loop.mp4

# First frame doubles as the <video poster> and the reduced-motion still, so it
# must match frame 0 of the loop exactly.
ffmpeg -v error -ss "$START" -i "$SRC" -frames:v 1 \
  -vf "crop=${CROP}" -q:v 4 -y site/poster.jpg

ls -lh site/tour-loop.mp4 site/poster.jpg | awk '{print "   ", $9, $5}'
