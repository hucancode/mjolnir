#!/usr/bin/env bash
# Build and run each example, recording a video clip via the
# VK_LAYER_LUNARG_screenshot layer (one PPM per frame) and stitching the
# frames into docs/site/videos/<example>.mp4 with ffmpeg; one frame becomes the screenshot
# docs/site/screenshots/<example>.png.
#
# Usage:
#   examples/record.sh [options] [example...]    (no examples = all)
#
# Options:
#   --frames N    total frames to render        (default 300)
#   --fps N       render cadence + mp4 framerate (default 30)
#   --start N     first frame to dump            (default 0; skips early garbage)
#   --shot N      frame saved as the screenshot  (default: the middle recorded frame)
#   --crf N       x264 CRF quality               (default 23)
#   --timeout N   seconds to wait for the run    (default 120)
#
# Environment: OUT_DIR (videos), SHOT_DIR (screenshots), LOG_DIR, BIN_DIR, TMP_ROOT.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="${OUT_DIR:-docs/site/videos}"
SHOT_DIR="${SHOT_DIR:-docs/site/screenshots}"
LOG_DIR="${LOG_DIR:-artifacts/record}"
BIN_DIR="${BIN_DIR:-bin}"
TMP_ROOT="${TMP_ROOT:-artifacts/record/frames}"

frame_limit=300
fps=30
start=0
crf=23
to_sec=120
shot=""

usage() { sed -n "2,/^set -u/p" "$0" | sed "s/^# \?//;/^set -u/d" >&2; exit 2; }

targets=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --frames)  frame_limit="${2:?}"; shift 2 ;;
        --fps)     fps="${2:?}"; shift 2 ;;
        --start)   start="${2:?}"; shift 2 ;;
        --shot)    shot="${2:?}"; shift 2 ;;
        --crf)     crf="${2:?}"; shift 2 ;;
        --timeout) to_sec="${2:?}"; shift 2 ;;
        -h|--help) usage ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) targets+=("$1"); shift ;;
    esac
done

mkdir -p "$OUT_DIR" "$SHOT_DIR" "$LOG_DIR" "$BIN_DIR" "$TMP_ROOT"

for tool in ffmpeg odin awk magick xvfb-run; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done

record_one() {
    local example="$1"
    local example_dir
    example_dir=$(ls -d examples/*/"$example" 2>/dev/null | head -1)
    [[ -f "$example_dir/main.odin" ]] || { echo "skip $example (no main.odin)"; return 0; }

    local shot_frame="${shot:-$(((start + frame_limit) / 2))}"

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
    local shot_file="$SHOT_DIR/${example}.png"
    local frame_dir="$TMP_ROOT/$example"

    rm -rf "$frame_dir"
    mkdir -p "$frame_dir"

    echo "=== $example (frames=${start}..$((frame_limit - 1)) @ ${fps}fps → $out_file)"

    if ! odin build "$example_dir" -out:"$bin" \
            -define:USE_PARALLEL_UPDATE=false \
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

    if ! magick "$frame_dir/${shot_frame}.ppm" "$shot_file" 2>> "$ffm_log"; then
        echo "  screenshot FAILED (no frame $shot_frame) — see $ffm_log" >&2
        return 1
    fi

    # drop frames once mux succeeds to keep disk usage sane
    rm -rf "$frame_dir"

    local size
    size=$(wc -c < "$out_file" | tr -d " ")
    echo "  done (${n} frames, ${size} bytes)"
}

if [[ ${#targets[@]} -eq 0 ]]; then
    for d in examples/*/*/; do
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
