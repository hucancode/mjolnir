#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: run.sh <test> [artifact-root]

Builds and runs a single visual test, captures a screenshot via the
Vulkan screenshot layer, and compares it against the test's golden image
(`golden.ppm` stored in the same directory as the test).

Environment variables:
  UPDATE_GOLDEN    If set to 1, refresh the golden image instead of comparing
  TEST_TIMEOUT     Timeout in seconds for the render (default: 45)
  RMSE_THRESHOLD   Allowed RMSE difference vs the golden (default: 0)
USAGE
}

if [[ ${1-} == "-h" || ${1-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

test_id=$1
artifact_root=${2:-artifacts}
update_golden=${UPDATE_GOLDEN:-0}
test_timeout=${TEST_TIMEOUT:-15}
rmse_threshold=${RMSE_THRESHOLD:-0}

if [[ $test_timeout -le 0 ]]; then
  echo "TEST_TIMEOUT must be > 0" >&2
  exit 1
fi

if [[ $rmse_threshold -lt 0 ]]; then
  echo "RMSE_THRESHOLD must be >= 0" >&2
  exit 1
fi

if [[ -d $test_id ]]; then
  test_dir="$test_id"
else
  test_dir="test/visual/$test_id"
fi
if [[ ! -d $test_dir ]]; then
  echo "Test directory not found: $test_dir" >&2
  exit 1
fi
test_name=$(basename "$test_dir")
binary="./bin/visual_$test_name"
build_cmd=(odin build "$test_dir" -out:"bin/visual_$test_name")

log_dir="$artifact_root/logs"
out_dir="$artifact_root/$test_name"
mkdir -p "$log_dir" "$out_dir"

echo "Building $test_name"
"${build_cmd[@]}"

echo "Running visual test: $test_name"
log_file="$log_dir/$test_name.log"
if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "xvfb-run is required to capture headless screenshots" >&2
  exit 1
fi

if [[ -z ${VK_INSTANCE_LAYERS:-} ]]; then
  export VK_INSTANCE_LAYERS=VK_LAYER_LUNARG_screenshot
elif [[ ${VK_INSTANCE_LAYERS} != *VK_LAYER_LUNARG_screenshot* ]]; then
  export VK_INSTANCE_LAYERS="${VK_INSTANCE_LAYERS}:VK_LAYER_LUNARG_screenshot"
fi
export VK_SCREENSHOT_FRAMES=${VK_SCREENSHOT_FRAMES:-3}
export VK_SCREENSHOT_DIR="$(pwd)/$out_dir"

set +e
set +o pipefail
xvfb-run -a -s "-screen 0 1920x1080x24" \
  timeout "${test_timeout}s" "$binary" | tee "$log_file"
pipe_statuses=("${PIPESTATUS[@]}")
set -o pipefail
set -e
render_status=${pipe_statuses[0]}
if [[ $render_status -eq 124 ]]; then
  # echo "Render timed out (allowed)."
  render_status=0
fi

latest_ppm=$(find "$out_dir" -maxdepth 1 -name '*.ppm' | sort | head -n 1)
if [[ -z $latest_ppm ]]; then
  echo "No screenshot produced for $test_name" >&2
  if [[ $render_status -eq 0 ]]; then
    render_status=1
  fi
fi

golden_path="$test_dir/golden.ppm"
if [[ $update_golden == 1 ]]; then
  if [[ -z $latest_ppm ]]; then
    echo "Cannot update golden for $test_name: no screenshot produced" >&2
    exit 1
  fi
  cp "$latest_ppm" "$golden_path"
  echo "Updated golden for $test_name at $golden_path"
  exit 0
fi

if [[ ! -f $golden_path ]]; then
  echo "Golden image missing for $test_name ($golden_path). Set UPDATE_GOLDEN=1 to create it." >&2
  exit 1
fi

if command -v magick >/dev/null 2>&1; then
  diff_output=$(magick compare -metric RMSE "$golden_path" "$latest_ppm" null: 2>&1 || true)
elif command -v compare >/dev/null 2>&1; then
  diff_output=$(compare -metric RMSE "$golden_path" "$latest_ppm" null: 2>&1 || true)
else
  echo "ImageMagick compare tool not found (need 'magick' or 'compare')" >&2
  exit 1
fi
rmse_value=$(printf '%s' "$diff_output" | awk '{print $1}')
if [[ -z $rmse_value ]]; then
  echo "Failed to compute RMSE for $test_name" >&2
  exit 1
fi

awk -v value="$rmse_value" -v threshold="$rmse_threshold" -v name="$test_name" '
  BEGIN {
    if ((value + 0) > (threshold + 0)) {
      printf "Image comparison failed for %s: RMSE %f exceeds threshold %f\n", name, value, threshold > "/dev/stderr";
      exit 1;
    }
  }
'

printf 'RMSE for %s: %s (threshold %s)\n' "$test_name" "$rmse_value" "$rmse_threshold"
exit "$render_status"
