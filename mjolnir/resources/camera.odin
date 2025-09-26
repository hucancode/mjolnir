package resources

import "core:math"
import "core:math/linalg"
import "../geometry"

CameraData :: struct {
  view:             matrix[4, 4]f32,
  projection:       matrix[4, 4]f32,
  viewport_params:  [4]f32,
  position:         [4]f32,
  frustum_planes:   [6][4]f32,
}
