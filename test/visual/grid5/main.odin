package main

import "core:log"
import "core:math"
import "core:os"
import visual "../common"

main :: proc() {
  config := visual.VisualTestConfig {
    name            = "visual-grid-5x5",
    grid_dims       = {5, 5},
    spacing         = 1.6,
    cube_scale      = 0.45,
    base_color      = {0.93, 0.75, 0.2, 1.0},
    accent_color    = {0.1, 0.55, 0.95, 1.0},
    color_mode      = visual.ColorMode.CHECKER,
    window_width    = 1280,
    window_height   = 720,
    run_seconds     = 5.0,
    camera_position = {7.5, 6.0, 7.5},
    camera_target   = {0.0, 0.0, 0.0},
    camera_fov      = math.PI * 0.3,
    camera_near     = 0.05,
    camera_far      = 120.0,
    enable_shadows  = false,
  }
  if !visual.run_visual_test(config) {
    log.error("visual-grid-5x5 failed to launch")
    os.exit(1)
  }
}
