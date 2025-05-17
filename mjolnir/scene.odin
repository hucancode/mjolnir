package mjolnir

import "core:math"
import linalg "core:math/linalg"
import "geometry"

Scene :: struct {
  camera: Camera,
  root:   Handle,
}

init_scene :: proc(s: ^Scene) {
  s.camera = camera_init_orbit(
    math.PI * 0.5, // fov
    16.0 / 9.0, // aspect_ratio
    0.01, // near
    100.0, // far
  )
}

deinit_scene :: proc(s: ^Scene) {
}


rotate_orbit_camera_scene :: proc(
  s: ^Scene,
  delta_yaw: f32,
  delta_pitch: f32,
) {
  camera_orbit_rotate(&s.camera, delta_yaw, delta_pitch)
}

switch_camera_mode_scene :: proc(s: ^Scene) {
  _, in_orbit_mode := s.camera.movement_data.(CameraOrbitMovement)
  if in_orbit_mode {
    camera_switch_to_free(&s.camera)
  } else {
    camera_switch_to_orbit(&s.camera, nil, nil)
  }
}
