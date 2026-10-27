#!/usr/bin/env bash
# Build and run each example with -define:FRAME_DUMP, which makes the engine write every
# presented frame as a PNG (no window capture, no virtual display), then encode the frames into
# docs/site/videos/<example>.mp4; one frame becomes its poster, docs/site/posters/<example>.jpg.
# The frames are encoded with ffmpeg.
#
# Usage:
#   examples/record.sh [options] [example...]    (no examples = all)
#
# Options:
#   --frames N    total frames to render        (default 300)
#   --fps N       render cadence + mp4 framerate (default 30)
#   --start N     first frame in the video       (default 0; skips early garbage)
#   --shot N      frame saved as the poster      (default: 40% into the video)
#   --crf N       x264 CRF quality               (default 23)
#   --timeout N   seconds to wait for the run    (default 120)
#
# Environment: OUT_DIR (videos), POSTER_DIR (posters), LOG_DIR, BIN_DIR, TMP_ROOT.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="${OUT_DIR:-docs/site/videos}"
POSTER_DIR="${POSTER_DIR:-docs/site/posters}"
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

mkdir -p "$OUT_DIR" "$POSTER_DIR" "$LOG_DIR" "$BIN_DIR" "$TMP_ROOT"

command -v ffmpeg >/dev/null || { echo "missing tool: ffmpeg" >&2; exit 2; }

record_one() {
    local example="$1"
    local example_dir
    example_dir=$(ls -d examples/*/"$example" 2>/dev/null | head -1)
    [[ -f "$example_dir/main.odin" ]] || { echo "skip $example (no main.odin)"; return 0; }

    local count=$((frame_limit - start))
    if (( count <= 0 )); then
        echo "  $example: start=$start >= frame_limit=$frame_limit; nothing to capture" >&2
        return 1
    fi
    local shot_frame="${shot:-$((start + count * 2 / 5))}"

    local bin="$BIN_DIR/record_${example}"
    local build_log="$LOG_DIR/${example}.build.log"
    local run_log="$LOG_DIR/${example}.run.log"
    local ffm_log="$LOG_DIR/${example}.ffmpeg.log"
    local out_file="$OUT_DIR/${example}.mp4"
    local poster_file="$POSTER_DIR/${example}.jpg"
    local frame_dir="$TMP_ROOT/$example"

    rm -rf "$frame_dir"
    mkdir -p "$frame_dir"

    echo "=== $example (frames=${start}..$((frame_limit - 1)) @ ${fps}fps → $out_file)"

    if ! odin build "$example_dir" -out:"$bin" \
            -define:USE_PARALLEL_UPDATE=false \
            -define:RENDER_FPS="$fps" \
            -define:FRAME_LIMIT="$frame_limit" \
            -define:FRAME_DUMP="$frame_dir" \
            > "$build_log" 2>&1; then
        echo "  build FAILED — see $build_log" >&2
        return 1
    fi

    local timer=()
    command -v timeout >/dev/null && timer=(timeout "$to_sec")
    ${timer[@]+"${timer[@]}"} "./$bin" > "$run_log" 2>&1
    local app_rc=$?
    if (( app_rc != 0 )); then
        echo "  app exit rc=$app_rc — see $run_log" >&2
    fi

    local n=0 f
    for f in "$frame_dir"/*.png; do
        [[ -e "$f" ]] || break
        if (( 10#$(basename "$f" .png) < start )); then rm -f "$f"; else n=$((n + 1)); fi
    done
    if (( n == 0 )); then
        echo "  no frames captured — see $run_log" >&2
        return 1
    fi
    local shot_src
    shot_src="$frame_dir/$(printf '%05d' "$shot_frame").png"
    if [[ ! -f "$shot_src" ]]; then
        echo "  poster FAILED (no frame $shot_frame) — see $run_log" >&2
        return 1
    fi

    local rc=0
    ffmpeg -hide_banner -nostdin -y \
        -framerate "$fps" -start_number "$start" -i "$frame_dir/%05d.png" \
        -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" \
        -c:v libx264 -preset slow -crf "$crf" -pix_fmt yuv420p \
        -movflags +faststart \
        "$out_file" \
        > "$ffm_log" 2>&1 || rc=$?
    if (( rc != 0 )); then
        echo "  encode FAILED rc=$rc — see $ffm_log" >&2
        return 1
    fi
    if [[ ! -s "$out_file" ]]; then
        echo "  empty mp4 — see $ffm_log" >&2
        return 1
    fi
    # a small still shown until the video plays
    if ! ffmpeg -hide_banner -nostdin -y -i "$shot_src" -vf "scale=480:-2" -q:v 4 "$poster_file" >> "$ffm_log" 2>&1; then
        echo "  poster FAILED — see $ffm_log" >&2
        return 1
    fi

    # drop frames once encoded to keep disk usage sane
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
