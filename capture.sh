#!/usr/bin/env bash
set -euo pipefail

# Defaults
APP_PATH="${1:-./bin/main}"
FRAME_N="${2:-5}"
OUT_DIR="${3:-.}"
PPM_FILE="$OUT_DIR/$FRAME_N.ppm"
PNG_FILE="$OUT_DIR/screenshot.png"
TIMEOUT_SEC="${4:-10}"

# Ensure dependencies
command -v convert >/dev/null || { echo "Error: ImageMagick 'convert' not found" >&2; exit 1; }
command -v xvfb-run >/dev/null || { echo "Error: 'xvfb-run' not found" >&2; exit 1; }

# Run Vulkan app headlessly with timeout
echo "Running $APP_PATH for $TIMEOUT_SEC seconds to capture frame $FRAME_N..."
VK_INSTANCE_LAYERS="VK_LAYER_LUNARG_screenshot" \
VK_SCREENSHOT_FRAMES="$FRAME_N" \
VK_SCREENSHOT_DIR="$OUT_DIR" \
xvfb-run -a -s "-screen 0 1920x1080x24" \
timeout "$TIMEOUT_SEC"s "$APP_PATH" || true

# Verify and convert output
if [[ -f "$PPM_FILE" ]]; then
  convert "$PPM_FILE" "$PNG_FILE"
  rm -f "$PPM_FILE"
  echo "Screenshot saved: $PNG_FILE"
else
  echo "Error: no screenshot captured (file not found: $PPM_FILE)" >&2
  exit 1
fi
