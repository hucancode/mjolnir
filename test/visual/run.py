#!/usr/bin/env python3

import os
import shutil
import signal
import subprocess
import sys
from pathlib import Path

from skimage import io, metrics
import numpy as np


def parse_config(path: Path) -> dict[str, str]:
    config = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            config[key.strip().lower()] = value.strip()
    return config


def find_test_dir(repo_root: Path, test_id: str) -> Path:
    candidate = repo_root / "test" / "visual" / test_id
    return candidate if candidate.is_dir() else (repo_root / test_id)


def build_test(repo_root: Path, test_dir: Path, frame_limit: int = 0):
    test_dir_rel = os.path.relpath(test_dir, repo_root)
    binary_name = f"visual_{test_dir.name}"
    print(f"Building {test_dir_rel} with FRAME_LIMIT={frame_limit}")
    build_args = [
        "odin", "build", test_dir_rel,
        f"-out:bin/{binary_name}",
        "-define:USE_PARALLEL_UPDATE=false",
        f"-define:FRAME_LIMIT={frame_limit}"
    ]
    subprocess.run(build_args, cwd=repo_root, check=True)
    return binary_name


def run_test(repo_root: Path, binary_name: str, timeout: int, env: dict, log_path: Path) -> int:
    print(f"Running {binary_name.removeprefix('visual_')}")
    with log_path.open("w") as log_file:
        proc = subprocess.Popen(
            ["xvfb-run", "-a", "-s", "-screen 0 1920x1080x24", f"./bin/{binary_name}"],
            cwd=repo_root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        stdout, _ = proc.communicate()
        code = proc.returncode or 0

        log_file.write(stdout)
        print(stdout, end="")

    return code


def run_test_with_gdb(repo_root: Path, binary_name: str, env: dict, log_path: Path) -> str:
    """
    Re-run the crashed test under gdb to capture a backtrace.
    Returns the gdb output as a string.
    """
    print(f"Re-running {binary_name.removeprefix('visual_')} with gdb to capture crash log...")

    gdb_commands = """
run
thread apply all bt
quit
"""

    crash_log_path = log_path.with_suffix('.crash.log')

    with crash_log_path.open("w") as crash_file:
        proc = subprocess.Popen(
            [
                "xvfb-run", "-a", "-s", "-screen 0 1920x1080x24",
                "gdb", "-batch",
                "-ex", "run",
                "-ex", "thread apply all bt",
                "-ex", "quit",
                f"./bin/{binary_name}"
            ],
            cwd=repo_root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        stdout, _ = proc.communicate()

        crash_file.write(stdout)
        print(stdout, end="")

    print(f"Crash log saved to: {crash_log_path}")
    return stdout


def to_grayscale(img: np.ndarray) -> np.ndarray:
    if len(img.shape) == 3 and img.shape[2] >= 3:
        return np.dot(img[..., :3], [0.299, 0.587, 0.114])
    return img


def compute_ssim(golden: Path, latest: Path) -> float:
    img1 = to_grayscale(io.imread(str(golden))).astype(np.float64)
    img2 = to_grayscale(io.imread(str(latest))).astype(np.float64)
    return float(metrics.structural_similarity(img1, img2, data_range=img1.max() - img1.min()))


def compute_rmse(golden: Path, latest: Path) -> float:
    img1 = io.imread(str(golden)).astype(np.float64)
    img2 = io.imread(str(latest)).astype(np.float64)
    return float(np.sqrt(np.mean((img1 - img2) ** 2)))


def compute_mae(golden: Path, latest: Path) -> float:
    img1 = io.imread(str(golden)).astype(np.float64)
    img2 = io.imread(str(latest)).astype(np.float64)
    return float(np.mean(np.abs(img1 - img2)))


def compute_psnr(golden: Path, latest: Path) -> float:
    img1 = io.imread(str(golden)).astype(np.float64)
    img2 = io.imread(str(latest)).astype(np.float64)
    max_pixel = 255.0 if img1.dtype == np.uint8 else 65535.0 if img1.dtype == np.uint16 else float(img1.max())
    mse = np.mean((img1 - img2) ** 2)
    return float('inf') if mse == 0 else float(20 * np.log10(max_pixel / np.sqrt(mse)))


def compare(golden: Path, latest: Path, metric: str, threshold: float | None, direction: str) -> float:
    metric_map = {"SSIM": compute_ssim, "RMSE": compute_rmse, "MAE": compute_mae, "PSNR": compute_psnr}
    value = metric_map[metric.upper()](golden, latest)

    if threshold is not None:
        if (direction != "higher" and value > threshold) or (direction == "higher" and value < threshold):
            sys.exit(f"{metric} {value:.6f} failed threshold {threshold:.6f} ({direction})")

    print(f"{metric}: {value:.6f}" + (f" (threshold {threshold}, {direction})" if threshold else ""))
    return value


def main():
    test_id = sys.argv[1]
    artifact_root = Path(sys.argv[2] if len(sys.argv) > 2 else "artifacts")
    repo_root = Path(__file__).resolve().parent.parent.parent

    # Load config
    test_dir = find_test_dir(repo_root, test_id)
    config = parse_config(test_dir / "compare.cfg") if (test_dir / "compare.cfg").exists() else {}

    timeout = int(config.get("timeout", os.environ.get("TEST_TIMEOUT", "15")))
    metric = config.get("metric", os.environ.get("COMPARISON_METRIC", "RMSE"))
    threshold = float(config["threshold"]) if "threshold" in config else (
        float(os.environ.get("COMPARISON_THRESHOLD", "0")) or None
    )
    direction = config.get("direction", os.environ.get("COMPARISON_DIRECTION", "lower"))
    frames = int(config.get("frames", os.environ.get("COMPARISON_FRAMES", "3")))
    frame_limit = int(config.get("frame_limit", os.environ.get("FRAME_LIMIT", "0")))
    update_golden = os.environ.get("UPDATE_GOLDEN") == "1"

    # Build and run
    binary_name = build_test(repo_root, test_dir, frame_limit)

    out_dir = artifact_root / test_dir.name
    out_dir.mkdir(parents=True, exist_ok=True)
    (artifact_root / "logs").mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    layers = env.get("VK_INSTANCE_LAYERS", "")
    if "VK_LAYER_LUNARG_screenshot" not in layers:
        env["VK_INSTANCE_LAYERS"] = f"{layers}:VK_LAYER_LUNARG_screenshot" if layers else "VK_LAYER_LUNARG_screenshot"
    env["VK_SCREENSHOT_FRAMES"] = str(frames)
    env["VK_SCREENSHOT_DIR"] = str(out_dir.resolve())

    log_path = artifact_root / "logs" / f"{test_dir.name}.log"
    code = run_test(repo_root, binary_name, timeout, env, log_path)

    # If test crashed, re-run with gdb to get backtrace
    if code != 0:
        print(f"\nTest crashed with exit code {code}")
        run_test_with_gdb(repo_root, binary_name, env, log_path)

    # Compare
    screenshots = sorted(out_dir.glob("*.ppm"))
    if not screenshots:
        print(f"ERROR: No screenshots generated in {out_dir}")
        print(f"Expected VK_LAYER_LUNARG_screenshot to create .ppm files")
        print(f"Environment: VK_SCREENSHOT_FRAMES={env.get('VK_SCREENSHOT_FRAMES')}")
        print(f"             VK_SCREENSHOT_DIR={env.get('VK_SCREENSHOT_DIR')}")
        print(f"Build config: FRAME_LIMIT={frame_limit}")
        print(f"Check the log file at: {artifact_root / 'logs' / f'{test_dir.name}.log'}")
        sys.exit(1)
    latest = screenshots[0]
    golden = test_dir / "golden.ppm"

    if update_golden:
        shutil.copy2(latest, golden)
        print(f"Updated golden: {golden}")
        return 0

    compare(golden, latest, metric, threshold, direction)
    return code


if __name__ == "__main__":
    sys.exit(main())
