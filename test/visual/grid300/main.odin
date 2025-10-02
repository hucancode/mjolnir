package main

import "core:log"
import "core:math"
import "core:os"
import visual "../common"

main :: proc() {
  config := visual.VisualTestConfig {
    name            = "visual-grid-300x300",
    grid_dims       = {300, 300},
    spacing         = 1.3,
    cube_scale      = 0.14,
    base_color      = {0.95, 0.45, 0.45, 1.0},
    accent_color    = {0.25, 0.25, 0.85, 1.0},
    color_mode      = visual.ColorMode.CONSTANT,
    window_width    = 1600,
    window_height   = 900,
    run_seconds     = 7.0,
    camera_position = {0.0, 70.0, 70.0},
    camera_target   = {0.0, 0.0, 0.0},
    camera_fov      = math.PI * 0.26,
    camera_near     = 0.1,
    camera_far      = 300.0,
    enable_shadows  = false,
  }
  if !visual.run_visual_test(config) {
    log.error("visual-grid-300x300 failed to launch")
    os.exit(1)
  }
}
