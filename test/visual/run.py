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


def build_test(repo_root: Path, test_dir: Path):
    test_dir_rel = os.path.relpath(test_dir, repo_root)
    binary_name = f"visual_{test_dir.name}"
    print(f"Building {test_dir_rel}")
    subprocess.run(
        ["odin", "build", test_dir_rel, f"-out:bin/{binary_name}"],
        cwd=repo_root,
        check=True,
    )
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
            start_new_session=True,
        )
        try:
            stdout, _ = proc.communicate(timeout=timeout)
            code = proc.returncode or 0
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                stdout, _ = proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                stdout, _ = proc.communicate()
            code = 0
            print("Timed out (allowed)")

        log_file.write(stdout)
        print(stdout, end="")

    return code


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
    update_golden = os.environ.get("UPDATE_GOLDEN") == "1"

    # Build and run
    binary_name = build_test(repo_root, test_dir)

    out_dir = artifact_root / test_dir.name
    out_dir.mkdir(parents=True, exist_ok=True)
    (artifact_root / "logs").mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    layers = env.get("VK_INSTANCE_LAYERS", "")
    if "VK_LAYER_LUNARG_screenshot" not in layers:
        env["VK_INSTANCE_LAYERS"] = f"{layers}:VK_LAYER_LUNARG_screenshot" if layers else "VK_LAYER_LUNARG_screenshot"
    env["VK_SCREENSHOT_FRAMES"] = str(frames)
    env["VK_SCREENSHOT_DIR"] = str(out_dir.resolve())

    code = run_test(repo_root, binary_name, timeout, env, artifact_root / "logs" / f"{test_dir.name}.log")

    # Compare
    latest = sorted(out_dir.glob("*.ppm"))[0]
    golden = test_dir / "golden.ppm"

    if update_golden:
        shutil.copy2(latest, golden)
        print(f"Updated golden: {golden}")
        return 0

    compare(golden, latest, metric, threshold, direction)
    return code


if __name__ == "__main__":
    sys.exit(main())
