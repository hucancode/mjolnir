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

camera_data_update :: proc(
  uniform: ^CameraData,
  camera: ^geometry.Camera,
  viewport_width, viewport_height: u32,
) {
  uniform.view, uniform.projection = geometry.camera_calculate_matrices(camera^)
  camera_near, camera_far := geometry.camera_get_near_far(camera^)
  uniform.viewport_params = [4]f32{
    f32(viewport_width),
    f32(viewport_height),
    camera_near,
    camera_far,
  }
  uniform.position = [4]f32{camera.position[0], camera.position[1], camera.position[2], 1.0}
  frustum := geometry.make_frustum(uniform.projection * uniform.view)
  uniform.frustum_planes = frustum.planes
}
