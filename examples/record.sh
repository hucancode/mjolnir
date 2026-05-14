#!/usr/bin/env bash
# Build and run each example, recording a video clip via the
# VK_LAYER_LUNARG_screenshot layer (one PPM per frame) and stitching the
# frames into docs/videos/<example>.mp4 with ffmpeg.
#
# Per-example overrides live in examples/<name>/record.cfg as key=value lines.
# Recognized keys:
#   frame_limit   total frames to render        (default 300)
#   fps           render cadence + mp4 framerate (default 30)
#   start         first frame to dump            (default 0; skips early garbage)
#   crf           x264 CRF quality               (default 23)
#   timeout       seconds to wait for the run    (default 120)
#   skip          if 1, skip this example
#
# Usage:
#   examples/record.sh                # all examples
#   examples/record.sh cube physics   # specific ones
#   OUT_DIR=foo examples/record.sh    # override video dir
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="${OUT_DIR:-docs/videos}"
LOG_DIR="${LOG_DIR:-artifacts/record}"
BIN_DIR="${BIN_DIR:-bin}"
TMP_ROOT="${TMP_ROOT:-artifacts/record/frames}"

DEFAULT_FRAME_LIMIT=300
DEFAULT_FPS=30
DEFAULT_START=0
DEFAULT_CRF=23
DEFAULT_TIMEOUT=120

mkdir -p "$OUT_DIR" "$LOG_DIR" "$BIN_DIR" "$TMP_ROOT"

for tool in ffmpeg odin awk magick xvfb-run; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done

read_cfg() {
    local file="$1" key="$2" default="$3" value
    [[ -f "$file" ]] || { printf '%s' "$default"; return; }
    value=$(awk -F= -v k="$key" '
        /^[[:space:]]*#/ {next}
        NF<2 {next}
        {
            gsub(/[[:space:]]/, "", $1)
            if ($1 == k) {
                sub(/^[[:space:]]+/, "", $2)
                sub(/[[:space:]]+$/, "", $2)
                print $2
                exit
            }
        }
    ' "$file")
    if [[ -z "$value" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$value"
    fi
}

record_one() {
    local example="$1"
    local example_dir="examples/$example"
    [[ -f "$example_dir/main.odin" ]] || { echo "skip $example (no main.odin)"; return 0; }

    local cfg="$example_dir/record.cfg"
    local skip
    skip=$(read_cfg "$cfg" skip 0)
    if [[ "$skip" == "1" ]]; then
        echo "=== $example: skipped via record.cfg"
        return 0
    fi

    local frame_limit fps start crf to_sec
    frame_limit=$(read_cfg "$cfg" frame_limit "$DEFAULT_FRAME_LIMIT")
    fps=$(read_cfg "$cfg" fps "$DEFAULT_FPS")
    start=$(read_cfg "$cfg" start "$DEFAULT_START")
    crf=$(read_cfg "$cfg" crf "$DEFAULT_CRF")
    to_sec=$(read_cfg "$cfg" timeout "$DEFAULT_TIMEOUT")

    local count=$((frame_limit - start))
    if (( count <= 0 )); then
        echo "  $example: start=$start >= frame_limit=$frame_limit; nothing to capture" >&2
        return 1
    fi

    local bin="$BIN_DIR/record_${example}"
    local build_log="$LOG_DIR/${example}.build.log"
    local run_log="$LOG_DIR/${example}.run.log"
    local ffm_log="$LOG_DIR/${example}.ffmpeg.log"
    local out_file="$OUT_DIR/${example}.mp4"
    local frame_dir="$TMP_ROOT/$example"

    rm -rf "$frame_dir"
    mkdir -p "$frame_dir"

    echo "=== $example (frames=${start}..$((frame_limit - 1)) @ ${fps}fps → $out_file)"

    if ! odin build "$example_dir" -out:"$bin" \
            -define:USE_PARALLEL_UPDATE=false \
            -define:REQUIRE_GEOMETRY_SHADER=false \
            -define:RENDER_FPS="$fps" \
            -define:FRAME_LIMIT="$frame_limit" \
            > "$build_log" 2>&1; then
        echo "  build FAILED — see $build_log" >&2
        return 1
    fi

    # VK_SCREENSHOT_FRAMES "start-count-step" dumps each frame to <dir>/<frame>.ppm
    VK_INSTANCE_LAYERS=VK_LAYER_LUNARG_screenshot \
    VK_SCREENSHOT_FRAMES="${start}-${count}-1" \
    VK_SCREENSHOT_DIR="$frame_dir" \
    timeout "$to_sec" xvfb-run -a -s "-screen 0 1920x1080x24" \
        "./$bin" > "$run_log" 2>&1
    local app_rc=$?
    if (( app_rc != 0 )); then
        echo "  app exit rc=$app_rc — see $run_log" >&2
    fi

    local n
    n=$(find "$frame_dir" -maxdepth 1 -name '*.ppm' | wc -l)
    if (( n == 0 )); then
        echo "  no frames captured — see $run_log" >&2
        return 1
    fi

    # PPMs are named <frame_number>.ppm with no zero-padding. Glob sorts
    # lexically (1,10,100,...,2,20), so feed ffmpeg a numerically sorted
    # concat list to keep frames in capture order.
    local list_file="$frame_dir/frames.txt"
    : > "$list_file"
    while IFS= read -r f; do
        printf "file '%s'\n" "$(realpath "$f")" >> "$list_file"
    done < <(find "$frame_dir" -maxdepth 1 -name '*.ppm' | sort -V)

    ffmpeg -hide_banner -nostdin -y \
        -r "$fps" \
        -f concat -safe 0 -i "$list_file" \
        -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" \
        -c:v libx264 -preset slow -crf "$crf" -pix_fmt yuv420p \
        -movflags +faststart \
        "$out_file" \
        > "$ffm_log" 2>&1
    local ff_rc=$?

    if (( ff_rc != 0 )); then
        echo "  ffmpeg FAILED rc=$ff_rc — see $ffm_log" >&2
        return 1
    fi
    if [[ ! -s "$out_file" ]]; then
        echo "  empty mp4 — see $ffm_log" >&2
        return 1
    fi

    # drop frames once mux succeeds to keep disk usage sane
    rm -rf "$frame_dir"

    local size
    size=$(stat -c%s "$out_file" 2>/dev/null || echo 0)
    echo "  done (${n} frames, ${size} bytes)"
}

declare -a targets
if [[ $# -gt 0 ]]; then
    targets=("$@")
else
    for d in examples/*/; do
        targets+=("$(basename "$d")")
    done
fi

failed=()
for ex in "${targets[@]}"; do
    if ! record_one "$ex"; then
        failed+=("$ex")
    fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
    echo
    echo "FAILED (${#failed[@]}): ${failed[*]}" >&2
    exit 1
fi
echo "all done"
