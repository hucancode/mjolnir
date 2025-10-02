package main

import "core:log"
import "core:math"
import "core:os"
import visual "../common"

main :: proc() {
  config := visual.VisualTestConfig {
    name            = "visual-grid-256x256",
    grid_dims       = {256, 256},
    spacing         = 1.1,
    cube_scale      = 0.16,
    base_color      = {0.18, 0.82, 0.36, 1.0},
    accent_color    = {0.95, 0.96, 0.99, 1.0},
    color_mode      = visual.ColorMode.CONSTANT,
    window_width    = 1600,
    window_height   = 900,
    run_seconds     = 6.0,
    camera_position = {6.0, 5.0, 6.0},
    camera_target   = {0.0, 0.0, 0.0},
    camera_fov      = math.PI * 0.3,
    camera_near     = 0.05,
    camera_far      = 80.0,
    enable_shadows  = false,
  }
  if !visual.run_visual_test(config) {
    log.error("visual-grid-256x256 failed to launch")
    os.exit(1)
  }
}
