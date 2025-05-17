package mjolnir

import "core:fmt"
import "core:math"
import linalg "core:math/linalg"
import "geometry"

CameraOrbitMovement :: struct {
  target:       linalg.Vector3f32,
  distance:     f32,
  yaw:          f32, // Rotation around Y-axis
  pitch:        f32, // Rotation around X-axis
  min_distance: f32,
  max_distance: f32,
  min_pitch:    f32,
  max_pitch:    f32,
}

DEFAULT_ORBIT_DATA := CameraOrbitMovement {
  target       = {0.0, 0.0, 0.0},
  distance     = 3.0,
  yaw          = 0.0,
  pitch        = 0.0,
  min_distance = 1.0,
  max_distance = 20.0,
  min_pitch    = -0.2 * math.PI,
  max_pitch    = 0.45 * math.PI,
}

MOUSE_SENSITIVITY_X :: 0.005
MOUSE_SENSITIVITY_Y :: 0.005
SCROLL_SENSITIVITY :: 0.5

CameraFreeMovement :: struct {
}
PerspectiveProjection :: struct {
  fov:          f32,
  aspect_ratio: f32,
  near:         f32,
  far:          f32,
}

OrthographicProjection :: struct {
  width:  f32,
  height: f32,
  near:   f32,
  far:    f32,
}

Camera :: struct {
  movement_data: union {
    CameraFreeMovement,
    CameraOrbitMovement,
  },
  up:            linalg.Vector3f32,
  position:      linalg.Vector3f32,
  rotation:      linalg.Quaternionf32,
  projection:    union {
    PerspectiveProjection,
    OrthographicProjection,
  },
}

// Initialization
camera_init_perspective :: proc(
  fov: f32,
  aspect_ratio: f32,
  near: f32,
  far: f32,
) -> Camera {
  return Camera {
    up = {0.0, 1.0, 0.0},
    position = {0.0, 0.0, 0.0},
    rotation = linalg.QUATERNIONF32_IDENTITY,
    movement_data = CameraFreeMovement{},
    projection = PerspectiveProjection {
      fov = fov,
      aspect_ratio = aspect_ratio,
      near = near,
      far = far,
    },
  }
}

camera_init_ortho :: proc(
  width: f32,
  height: f32,
  near: f32,
  far: f32,
) -> Camera {
  return Camera {
    up = {0.0, 1.0, 0.0},
    position = {0.0, 0.0, 0.0},
    rotation = linalg.QUATERNIONF32_IDENTITY,
    movement_data = CameraFreeMovement{},
    projection = OrthographicProjection {
      width = width,
      height = height,
      near = near,
      far = far,
    },
  }
}

camera_init_orbit :: proc(
  fov: f32,
  aspect_ratio: f32,
  near: f32,
  far: f32,
) -> Camera {
  cam := Camera {
    up = {0.0, 1.0, 0.0},
    rotation = linalg.QUATERNIONF32_IDENTITY,
    movement_data = DEFAULT_ORBIT_DATA,
    projection = PerspectiveProjection {
      fov = fov,
      aspect_ratio = aspect_ratio,
      near = near,
      far = far,
    },
  }
  camera_update_orbit_position(&cam) // Set initial position and rotation
  return cam
}

// Mode Switching
camera_switch_to_orbit :: proc(
  camera: ^Camera,
  target: Maybe(linalg.Vector3f32),
  distance: Maybe(f32),
) {
  orbit_data := DEFAULT_ORBIT_DATA
  if t, ok := target.?; ok {
    orbit_data.target = t
  }
  if d, ok := distance.?; ok {
    orbit_data.distance = d
  }
  // Reset yaw and pitch or carry them over if desired. Zig version resets.
  orbit_data.yaw = 0.0
  orbit_data.pitch = 0.0
  camera.movement_data = orbit_data
  camera_update_orbit_position(camera)
}

camera_switch_to_free :: proc(camera: ^Camera) {
  camera.movement_data = CameraFreeMovement{}
}

// Orbit Mode Methods
camera_orbit_rotate :: proc(self: ^Camera, yaw_delta: f32, pitch_delta: f32) {
  #partial switch &movement in &self.movement_data {
  case CameraOrbitMovement:
    movement.yaw += yaw_delta
    movement.pitch += pitch_delta
    PI_HALF :: math.PI / 2.0
    epsilon :: 0.001
    movement.pitch = math.clamp(
      movement.pitch,
      -PI_HALF + epsilon,
      PI_HALF - epsilon,
    )
    camera_update_orbit_position(self)
  // fmt.printfln("Orbit camera rotated: yaw %f, pitch %f", movement.yaw, movement.pitch)
  case:
    //log.warnf("rotate_orbit_camera called on non-orbit camera or uninitialized orbit data")
    return
  }
}

camera_orbit_zoom :: proc(camera: ^Camera, delta_distance: f32) {
  movement, ok := &camera.movement_data.(CameraOrbitMovement)
  if !ok {
    return
  }
  movement.distance = clamp(
    movement.distance + delta_distance,
    movement.min_distance,
    movement.max_distance,
  )
  // fmt.printfln("Zoomed to distance: delta %f -> %f", delta_distance, movement.distance)
  camera_update_orbit_position(camera)
}

camera_set_orbit_target :: proc(
  camera: ^Camera,
  new_target: linalg.Vector3f32,
) {
  movement, ok := &camera.movement_data.(CameraOrbitMovement)
  if !ok {
    return
  }
  movement.target = new_target
  camera_update_orbit_position(camera)
}

camera_update_orbit_position :: proc(camera: ^Camera) {
  movement, ok := &camera.movement_data.(CameraOrbitMovement)
  if !ok {
    return
  }
  sin_pitch := math.sin_f32(movement.pitch)
  cos_pitch := math.cos_f32(movement.pitch)
  sin_yaw := math.sin_f32(movement.yaw)
  cos_yaw := math.cos_f32(movement.yaw)

  offset_direction := linalg.Vector3f32 {
    cos_pitch * cos_yaw,
    sin_pitch,
    cos_pitch * sin_yaw,
  }

  camera.position = movement.target + offset_direction * movement.distance
}

// Matrix Calculations
camera_calculate_projection_matrix :: proc(
  camera: ^Camera,
) -> linalg.Matrix4f32 {
  switch proj in camera.projection {
  case PerspectiveProjection:
    return linalg.matrix4_perspective(
      proj.fov,
      proj.aspect_ratio,
      proj.near,
      proj.far,
    )
  case OrthographicProjection:
    return linalg.matrix_ortho3d(
      -proj.width / 2,
      proj.width / 2,
      -proj.height / 2,
      proj.height / 2,
      proj.near,
      proj.far,
    )
  case:
    return linalg.MATRIX4F32_IDENTITY
  }
}

camera_calculate_view_matrix :: proc(camera: ^Camera) -> linalg.Matrix4f32 {
  switch movement_data in camera.movement_data {
  case CameraOrbitMovement:
    return linalg.matrix4_look_at(
      camera.position,
      movement_data.target,
      camera.up,
    )
  case CameraFreeMovement:
    forward_vec := camera_forward(camera)
    up_vec := camera_up(camera)
    target_point := camera.position + forward_vec
    return linalg.matrix4_look_at(camera.position, target_point, up_vec)
  case:
    return linalg.MATRIX4F32_IDENTITY
  }
}

camera_forward :: proc(camera: ^Camera) -> linalg.Vector3f32 {
  return linalg.quaternion_mul_vector3(
    camera.rotation,
    linalg.VECTOR3F32_Z_AXIS,
  )
}

camera_right :: proc(camera: ^Camera) -> linalg.Vector3f32 {
  return linalg.quaternion_mul_vector3(
    camera.rotation,
    linalg.VECTOR3F32_X_AXIS,
  )
}

camera_up :: proc(camera: ^Camera) -> linalg.Vector3f32 {
  return linalg.quaternion_mul_vector3(
    camera.rotation,
    linalg.VECTOR3F32_Y_AXIS,
  )
}


// Frustum
camera_make_frustum :: proc(camera: ^Camera) -> geometry.Frustum {
  view_matrix := camera_calculate_view_matrix(camera)
  proj_matrix := camera_calculate_projection_matrix(camera)
  return geometry.make_frustum(proj_matrix * view_matrix)
}
