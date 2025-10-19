package main

import "core:log"
import "core:math"
import "core:os"
import visual "../common"

main :: proc() {
  config := visual.VisualTestConfig {
    name            = "visual-single-cube",
    grid_dims       = {1, 1},
    spacing         = 2.0,
    cube_scale      = 0.5,
    base_color      = {1.0, 0.45, 0.15, 1.0},
    accent_color    = {0.9, 0.3, 0.1, 1.0},
    color_mode      = visual.ColorMode.CONSTANT,
    window_width    = 800,
    window_height   = 600,
    camera_position = {3.0, 2.0, 3.0},
    camera_target   = {0.0, 0.0, 0.0},
    camera_fov      = math.PI * 0.35,
    camera_near     = 0.05,
    camera_far      = 100.0,
    enable_shadows  = false,
  }
  if !visual.run_visual_test(config) {
    log.error("visual-single-cube failed to launch")
    os.exit(1)
  }
}
