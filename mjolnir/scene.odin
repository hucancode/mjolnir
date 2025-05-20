package mjolnir

import "core:math"

Scene :: struct {
  camera: Camera,
  root:   Handle,
}

init_scene :: proc(scene: ^Scene) {
  scene.camera = make_orbit_perspective_camera(
    math.PI * 0.5, // fov
    16.0 / 9.0, // aspect_ratio
    0.01, // near
    100.0, // far
  )
}

deinit_scene :: proc(s: ^Scene) {
}


rotate_orbit_camera_scene :: proc(
  scene: ^Scene,
  delta_yaw: f32,
  delta_pitch: f32,
) {
  camera_orbit_rotate(&scene.camera, delta_yaw, delta_pitch)
}
