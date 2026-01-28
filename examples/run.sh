#!/bin/bash
set -e

test_id="$1"
artifact_root="${2:-artifacts}"

# Find test directory
if [[ -d "examples/$test_id" ]]; then
    test_dir="examples/$test_id"
else
    test_dir="$test_id"
fi

# Load config with defaults
timeout=15
metric="RMSE"
threshold=""
direction="lower"
frames=3
frame_limit=3

if [[ -f "$test_dir/compare.cfg" ]]; then
    while IFS='=' read -r key value; do
        [[ $key =~ ^[[:space:]]*# ]] && continue
        [[ -z $key ]] && continue
        case "${key// /}" in
            timeout) timeout="$value" ;;
            metric) metric="$value" ;;
            threshold) threshold="$value" ;;
            direction) direction="$value" ;;
            frames) frames="$value" ;;
            frame_limit) frame_limit="$value" ;;
        esac
    done < "$test_dir/compare.cfg"
fi

# Build test
binary_name="visual_$(basename "$test_dir")"
echo "Building $test_dir with FRAME_LIMIT=$frame_limit"
odin build "$test_dir" -out:"bin/$binary_name" \
    -define:USE_PARALLEL_UPDATE=false \
    -define:ENABLE_VALIDATION_LAYERS=true \
    -define:REQUIRE_GEOMETRY_SHADER=false \
    -define:FRAME_LIMIT="$frame_limit"

# Setup output
out_dir="$artifact_root/$(basename "$test_dir")"
mkdir -p "$out_dir" "$artifact_root/logs"

# Run test
echo "Running $(basename "$test_dir")"
export VK_INSTANCE_LAYERS="VK_LAYER_KHRONOS_validation:VK_LAYER_LUNARG_screenshot"
export VK_SCREENSHOT_FRAMES="$frames"
export VK_SCREENSHOT_DIR="$(realpath "$out_dir")"

xvfb-run -a -s "-screen 0 1920x1080x24" "./bin/$binary_name" \
    > "$artifact_root/logs/$(basename "$test_dir").log" 2>&1 || {
    echo "Test crashed with exit code $?"
    exit 1
}

# Convert PPM to PNG and compare
ppm_file=$(ls "$out_dir"/*.ppm 2>/dev/null | head -1)
[[ -z "$ppm_file" ]] && { echo "No screenshots generated"; exit 1; }

png_file="${ppm_file%.ppm}.png"
magick "$ppm_file" "$png_file"

golden="$test_dir/golden.png"
if [[ "$UPDATE_GOLDEN" == "1" ]]; then
    cp "$png_file" "$golden"
    echo "Updated golden: $golden"
    exit 0
fi

# Simple image comparison using ImageMagick
if [[ -n "$threshold" ]]; then
    # Handle different metric types with appropriate parsing
    case "$metric" in
        SSIM)
            # SSIM returns "dissimilarity (ssim_value)"
            # Extract SSIM from parentheses and convert to similarity: 1 - dissimilarity
            raw_output=$(magick compare -metric SSIM "$golden" "$png_file" null: 2>&1 || true)

            # Check if SSIM is unsupported
            if echo "$raw_output" | grep -q "unrecognized metric"; then
                echo "Error: SSIM metric not supported by installed ImageMagick version"
                echo "ImageMagick 7.x or later is required for SSIM support"
                magick --version | head -1
                exit 1
            fi

            ssim_dissim=$(echo "$raw_output" | sed 's/.*(\(.*\)).*/\1/')
            diff=$(awk "BEGIN {printf \"%.6f\", 1 - $ssim_dissim}")
            ;;

        PHASH)
            # Perceptual hash - returns distance value (lower is better)
            # Format: "distance (normalized)"
            raw_output=$(magick compare -metric PHASH "$golden" "$png_file" null: 2>&1 || true)
            diff=$(echo "$raw_output" | cut -d' ' -f1)
            ;;

        RMSE|MAE|MSE)
            # Error metrics - return "value (normalized)"
            # Use non-normalized value for better precision
            raw_output=$(magick compare -metric "$metric" "$golden" "$png_file" null: 2>&1 || true)
            diff=$(echo "$raw_output" | cut -d' ' -f1)
            ;;

        AE)
            # Absolute error count - just a number
            diff=$(magick compare -metric AE "$golden" "$png_file" null: 2>&1 || true)
            ;;

        *)
            # Default: try to extract first value
            diff=$(magick compare -metric "$metric" "$golden" "$png_file" null: 2>&1 | cut -d' ' -f1 || true)
            ;;
    esac

    echo "$metric: $diff (threshold $threshold, $direction)"
    if [[ "$direction" == "higher" ]]; then
        if awk "BEGIN {exit !($diff < $threshold)}"; then
            echo "$metric $diff failed threshold $threshold ($direction)"
            exit 1
        fi
    else
        if awk "BEGIN {exit !($diff > $threshold)}"; then
            echo "$metric $diff failed threshold $threshold ($direction)"
            exit 1
        fi
    fi
else
    echo "Visual comparison (no threshold set)"
fi
