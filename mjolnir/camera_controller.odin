package mjolnir

import geom "geometry"
import "input"
import "render"
import "core:math"
import "core:math/linalg"

// Orbits `target`. Distance, yaw and pitch come from the camera's pose each
// tick, so moving the camera by other means never makes the orbit snap back.
OrbitCameraData :: struct {
  target:       [3]f32,
  min_distance: f32,
  max_distance: f32,
  min_pitch:    f32,
  max_pitch:    f32,
  zoom_speed:   f32,
  rotate_speed: f32,
  pan_speed:    f32,
}

FreeCameraData :: struct {
  move_speed:        f32,
  boost_multiplier:  f32,
  mouse_sensitivity: f32,
}

// Follows `target`; the caller updates `target` every tick.
FollowCameraData :: struct {
  target:       [3]f32,
  offset:       [3]f32,
  follow_speed: f32,
}

CameraController :: struct {
  data:        union {
    OrbitCameraData,
    FreeCameraData,
    FollowCameraData,
  },
  is_dragging: bool,
}

// Pitch stays short of the poles, where yaw can't be recovered from the pose.
@(private = "file")
ORBIT_PITCH_LIMIT :: math.PI * 0.5 - 0.01

orbit_controller :: proc(target: [3]f32 = {0, 0, 0}) -> CameraController {
  return {
    data = OrbitCameraData {
      target = target,
      min_distance = 1.0,
      max_distance = 200.0,
      min_pitch = -ORBIT_PITCH_LIMIT,
      max_pitch = ORBIT_PITCH_LIMIT,
      zoom_speed = 2.0,
      rotate_speed = 2.0,
      pan_speed = 0.01,
    },
  }
}

free_controller :: proc(move_speed := f32(5.0)) -> CameraController {
  return {
    data = FreeCameraData {
      move_speed = move_speed,
      boost_multiplier = 3.0,
      mouse_sensitivity = 0.002,
    },
  }
}

follow_controller :: proc(
  target: [3]f32,
  offset: [3]f32,
  follow_speed := f32(5.0),
) -> CameraController {
  return {
    data = FollowCameraData {
      target = target,
      offset = offset,
      follow_speed = follow_speed,
    },
  }
}

@(private = "file")
orbit_update :: proc(
  self: ^CameraController,
  orbit: ^OrbitCameraData,
  camera: ^render.Camera,
  s: ^input.State,
  mouse_blocked, keyboard_blocked: bool,
) {
  // A drag may only start outside the UI; one in progress continues. The
  // tick a drag starts carries no motion.
  drag := input.mouse_down(s, .LEFT)
  started := drag && !self.is_dragging && !mouse_blocked
  if started do self.is_dragging = true
  if !drag do self.is_dragging = false
  scroll := s.scroll.y if !mouse_blocked else 0
  offset := camera.position - orbit.target
  distance := max(linalg.length(offset), 0.001)
  yaw := math.atan2(offset.z, offset.x)
  pitch := math.asin(clamp(offset.y / distance, -1, 1))
  if scroll != 0 {
    if ortho, is_ortho := &camera.projection.(render.OrthographicProjection); is_ortho {
      factor := math.exp(-scroll * 0.1)
      ortho.width = max(ortho.width * factor, 0.01)
      ortho.height = max(ortho.height * factor, 0.01)
    } else {
      distance = clamp(distance - scroll * orbit.zoom_speed, orbit.min_distance, orbit.max_distance)
    }
  }
  moved := false
  if self.is_dragging && !started && s.mouse_delta != {} {
    d := s.mouse_delta
    if !keyboard_blocked && shift_down(s) {
      forward := linalg.normalize(-offset)
      right := linalg.normalize(linalg.cross(forward, linalg.VECTOR3F32_Y_AXIS))
      up := linalg.cross(right, forward)
      orbit.target +=
        right * (-d.x * orbit.pan_speed * distance) +
        up * (d.y * orbit.pan_speed * distance)
    } else {
      yaw += d.x * orbit.rotate_speed * 0.01
      pitch = clamp(pitch + d.y * orbit.rotate_speed * 0.01, orbit.min_pitch, orbit.max_pitch)
    }
    moved = true
  }
  if !moved && scroll == 0 do return
  cp, sp := math.cos(pitch), math.sin(pitch)
  cy, sy := math.cos(yaw), math.sin(yaw)
  position := orbit.target + distance * [3]f32{cp * cy, sp, cp * sy}
  render.camera_look_at(camera, position, orbit.target, {-sp * cy, cp, -sp * sy})
}

// Shift: orbit pans instead of rotating, free moves faster.
@(private = "file")
shift_down :: proc(s: ^input.State) -> bool {
  return input.key_down(s, .LEFT_SHIFT) || input.key_down(s, .RIGHT_SHIFT)
}

@(private = "file")
free_update :: proc(
  free: ^FreeCameraData,
  camera: ^render.Camera,
  s: ^input.State,
  delta_time: f32,
  mouse_blocked, keyboard_blocked: bool,
) {
  if !keyboard_blocked {
    move :=
      geom.qx(camera.rotation) * input.axis(s, .A, .D) +
      [3]f32{0, 1, 0} * input.axis(s, .Q, .E) +
      -geom.qz(camera.rotation) * input.axis(s, .S, .W)
    if linalg.length2(move) > 0 {
      speed := free.move_speed * (free.boost_multiplier if shift_down(s) else 1)
      camera.position += linalg.normalize(move) * speed * delta_time
    }
  }
  if mouse_blocked || s.mouse_delta == {} do return
  yaw := s.mouse_delta.x * free.mouse_sensitivity
  pitch := s.mouse_delta.y * free.mouse_sensitivity
  camera.rotation =
    linalg.quaternion_angle_axis(-yaw, linalg.VECTOR3F32_Y_AXIS) * camera.rotation
  camera.rotation =
    linalg.quaternion_angle_axis(-pitch, geom.qx(camera.rotation)) * camera.rotation
}

@(private = "file")
follow_update :: proc(
  follow: ^FollowCameraData,
  camera: ^render.Camera,
  delta_time: f32,
) {
  desired := follow.target + follow.offset
  position := linalg.lerp(
    camera.position,
    desired,
    min(follow.follow_speed * delta_time, 1),
  )
  render.camera_look_at(camera, position, follow.target)
}

// Drive the main camera with `controller` for one tick of input. Captured
// mouse / keyboard input (see input.State) belongs to another consumer and is
// ignored; a drag already in progress continues. The zero controller does
// nothing.
camera_controller_update :: proc(
  controller: ^CameraController,
  self: ^render.Manager,
  s: ^input.State,
  delta_time: f32,
) {
  camera, ok := render.main_camera(self)
  if !ok do return
  switch &d in controller.data {
  case OrbitCameraData:
    orbit_update(controller, &d, camera, s, s.mouse_captured, s.keyboard_captured)
  case FreeCameraData:
    free_update(&d, camera, s, delta_time, s.mouse_captured, s.keyboard_captured)
  case FollowCameraData:
    follow_update(&d, camera, delta_time)
  }
}
