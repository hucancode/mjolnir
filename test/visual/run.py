#!/usr/bin/env python3

import argparse
import os
import shutil
import signal
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="run.py",
        description=(
            "Builds and runs a single visual test, captures a screenshot via the "
            "Vulkan screenshot layer, and compares it against the test's golden image."
        ),
    )
    parser.add_argument("test", help="Test identifier or path to test directory")
    parser.add_argument(
        "artifact_root",
        nargs="?",
        default="artifacts",
        help="Directory to store logs and screenshots (default: artifacts)",
    )
    return parser.parse_args()


def parse_config(path: Path) -> dict[str, str]:
    config: dict[str, str] = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        config[key.strip().lower()] = value.strip()
    return config


def ensure_positive_int(value: str, name: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise SystemExit(f"{name} must be an integer, got {value!r}") from exc
    if parsed <= 0:
        raise SystemExit(f"{name} must be > 0 (got {parsed})")
    return parsed


def find_test_dir(repo_root: Path, test_id: str) -> Path:
    direct = (repo_root / test_id).resolve()
    if direct.is_dir():
        return direct
    candidate = (repo_root / "test" / "visual" / test_id).resolve()
    if candidate.is_dir():
        return candidate
    raise SystemExit(f"Test directory not found: {test_id}")


def build_test(repo_root: Path, test_dir_rel: str, output_name: str) -> None:
    build_cmd = [
        "odin",
        "build",
        test_dir_rel,
        f"-out:bin/{output_name}",
    ]
    print(f"Building {test_dir_rel}")
    subprocess.run(build_cmd, cwd=repo_root, check=True)


def run_test(
    repo_root: Path,
    binary_name: str,
    timeout_seconds: int,
    env: dict[str, str],
    log_path: Path,
) -> int:
    cmd = [
        "xvfb-run",
        "-a",
        "-s",
        "-screen 0 1920x1080x24",
        f"./bin/{binary_name}",
    ]
    print(f"Running visual test: {binary_name.removeprefix('visual_')}")
    stdout_data = ""
    with log_path.open("w", encoding="utf-8") as log_file:
        try:
            proc = subprocess.Popen(
                cmd,
                cwd=repo_root,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                start_new_session=True,
            )
        except FileNotFoundError as exc:
            raise SystemExit("xvfb-run is required to capture headless screenshots") from exc

        try:
            stdout_data, _ = proc.communicate(timeout=timeout_seconds)
            return_code = proc.returncode or 0
        except subprocess.TimeoutExpired:
            # Terminate the entire process group created by xvfb-run.
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                stdout_data, _ = proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                stdout_data, _ = proc.communicate()
            return_code = 124
        if stdout_data:
            log_file.write(stdout_data)

    if stdout_data:
        print(stdout_data, end="")

    if return_code == 124:
        print("Render timed out (allowed).")
        return_code = 0

    return return_code


def find_first_ppm(directory: Path) -> Path | None:
    candidates = sorted(directory.glob("*.ppm"))
    return candidates[0] if candidates else None


def run_compare(
    golden: Path,
    latest: Path,
    metric: str,
    threshold: float | None,
    direction: str,
) -> float:
    command = ["magick", "compare", "-metric", metric, str(golden), str(latest), "null:"]
    alt_command = ["compare", "-metric", metric, str(golden), str(latest), "null:"]
    for args in (command, alt_command):
        try:
            completed = subprocess.run(
                args,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
        except FileNotFoundError:
            continue
        break
    else:
        raise SystemExit("ImageMagick compare tool not found (need 'magick' or 'compare')")

    output = completed.stderr.strip() or completed.stdout.strip()
    try:
        value = float(output.split()[0])
    except (IndexError, ValueError) as exc:
        raise SystemExit(f"Failed to compute {metric} (got output: '{output}')") from exc

    if threshold is not None:
        if direction in ("", "lower"):
            if value > threshold:
                raise SystemExit(
                    f"Image comparison failed: {metric} {value:.6f} exceeds threshold {threshold:.6f}"
                )
        elif direction == "higher":
            if value < threshold:
                raise SystemExit(
                    f"Image comparison failed: {metric} {value:.6f} below threshold {threshold:.6f}"
                )
        else:
            raise SystemExit(f"Unknown comparison direction '{direction}'")

    print(
        f"{metric} for {golden.parent.name}: {value:.6f}"
        + ("" if threshold is None else f" (threshold {threshold}, direction {direction})")
    )
    return value


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parent.parent.parent

    test_timeout = ensure_positive_int(os.environ.get("TEST_TIMEOUT", "15"), "TEST_TIMEOUT")
    update_golden = os.environ.get("UPDATE_GOLDEN", "0") == "1"
    comparison_metric = os.environ.get("COMPARISON_METRIC", "RMSE")
    comparison_threshold: float | None
    try:
        comparison_threshold = float(os.environ.get("COMPARISON_THRESHOLD", "0"))
    except ValueError:
        raise SystemExit("COMPARISON_THRESHOLD must be numeric")
    comparison_direction = os.environ.get("COMPARISON_DIRECTION", "lower").lower()
    comparison_frames = os.environ.get("COMPARISON_FRAMES")

    test_dir = find_test_dir(repo_root, args.test)
    config_path = test_dir / "compare.cfg"
    if config_path.exists():
        config = parse_config(config_path)
        if "metric" in config:
            comparison_metric = config["metric"] or comparison_metric
        if "timeout" in config:
            test_timeout = ensure_positive_int(config["timeout"], "timeout")
        if "threshold" in config:
            try:
                comparison_threshold = float(config["threshold"])
            except ValueError as exc:
                raise SystemExit(
                    f"Invalid threshold in {config_path}: {config['threshold']!r}"
                ) from exc
        if "direction" in config:
            comparison_direction = config["direction"].lower()
        if "frames" in config:
            comparison_frames = config["frames"]

    if comparison_frames is None:
        comparison_frames_int = 3
    else:
        comparison_frames_int = ensure_positive_int(comparison_frames, "COMPARISON_FRAMES")

    test_name = test_dir.name
    binary_name = f"visual_{test_name}"
    test_dir_rel = os.path.relpath(test_dir, repo_root)

    build_test(repo_root, test_dir_rel, binary_name)

    artifact_root = Path(args.artifact_root)
    artifact_root.mkdir(parents=True, exist_ok=True)
    log_dir = artifact_root / "logs"
    out_dir = artifact_root / test_name
    log_dir.mkdir(parents=True, exist_ok=True)
    out_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / f"{test_name}.log"

    env = os.environ.copy()
    layers = env.get("VK_INSTANCE_LAYERS", "")
    if "VK_LAYER_LUNARG_screenshot" not in layers.split(":"):
        env["VK_INSTANCE_LAYERS"] = (
            "VK_LAYER_LUNARG_screenshot" if not layers else f"{layers}:VK_LAYER_LUNARG_screenshot"
        )
    env["VK_SCREENSHOT_FRAMES"] = str(comparison_frames_int)
    env["VK_SCREENSHOT_DIR"] = str(out_dir.resolve())

    result_code = run_test(
        repo_root,
        binary_name,
        test_timeout,
        env,
        log_path,
    )

    latest_ppm = find_first_ppm(out_dir)
    if latest_ppm is None:
        print(f"No screenshot produced for {test_name}", file=sys.stderr)
        return 1 if result_code == 0 else result_code

    golden_path = test_dir / "golden.ppm"
    if update_golden:
        shutil.copy2(latest_ppm, golden_path)
        print(f"Updated golden for {test_name} at {golden_path}")
        return 0

    if not golden_path.exists():
        print(
            f"Golden image missing for {test_name} ({golden_path}). Set UPDATE_GOLDEN=1 to create it.",
            file=sys.stderr,
        )
        return 1

    run_compare(
        golden=golden_path,
        latest=latest_ppm,
        metric=comparison_metric,
        threshold=comparison_threshold,
        direction=comparison_direction,
    )

    return result_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as err:
        sys.exit(err.returncode)
