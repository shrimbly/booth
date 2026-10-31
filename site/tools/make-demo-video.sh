#!/bin/sh
# Renders the website's demo video from the app's real popover views: Booth draws each frame
# headlessly (--render-demo, nothing is captured from the screen) over this Mac's macOS Tahoe
# wallpaper, and ffmpeg encodes them.
#
#   [DEMO_POSTER=still.jpg] site/tools/make-demo-video.sh [path/to/Booth]
#
# The binary defaults to app/.build/debug/Booth (swift build in app/). DEMO_POSTER, if set, is a
# still from the demo file's video at its own shape; the file's thumbnail and the Done screen's
# picture show it. Writes site/media/demo.mp4 and site/media/demo-poster.jpg, the video's first
# frame for its poster attribute, so nothing blank shows while it loads.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
booth=${1:-"$root/app/.build/debug/Booth"}
wallpaper="/System/Library/Desktop Pictures/.wallpapers/Tahoe Day/Tahoe Day.mov"

[ -x "$booth" ] || { echo "make-demo-video: no Booth binary at $booth (run swift build in app/)" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "make-demo-video: needs ffmpeg" >&2; exit 1; }

frames=$(mktemp -d "${TMPDIR:-/tmp}/booth-demo.XXXXXX")
trap 'rm -rf "$frames"' EXIT

# Without the wallpaper (an older macOS), the renderer draws a plain gradient desktop.
if [ -f "$wallpaper" ]; then
  ffmpeg -v error -y -ss 2 -i "$wallpaper" -frames:v 1 \
    -vf "scale=2880:1800:force_original_aspect_ratio=increase,crop=2880:1800" -q:v 3 "$frames/wallpaper.jpg"
fi

if [ -n "${DEMO_POSTER:-}" ]; then
  ffmpeg -v error -y -i "$DEMO_POSTER" -q:v 2 "$frames/poster.jpg"
fi

BOOTH_LOG_DIR="$frames/log" "$booth" --render-demo "$frames"

mkdir -p "$root/site/media"
ffmpeg -v error -y -framerate 30 -i "$frames/frame-%04d.png" \
  -c:v libx264 -preset slow -crf 24 -pix_fmt yuv420p -movflags +faststart -an "$root/site/media/demo.mp4"
# The first frame, shown while the video loads; the loop starts on it, so nothing jumps.
ffmpeg -v error -y -i "$frames/frame-0001.png" -q:v 3 "$root/site/media/demo-poster.jpg"

echo "wrote site/media/demo.mp4 ($(du -h "$root/site/media/demo.mp4" | cut -f1)) and demo-poster.jpg"
