package geometry

import "core:math"
import "core:log"
import linalg "core:math/linalg"

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
  position:   [3]f32,
  rotation:   quaternion128,
  projection: union {
    PerspectiveProjection,
    OrthographicProjection,
  },
}

make_camera_perspective :: proc(
  fov: f32,
  aspect_ratio: f32,
  near: f32,
  far: f32,
) -> Camera {
  return Camera {
    rotation = linalg.QUATERNIONF32_IDENTITY,
    projection = PerspectiveProjection {
      fov = fov,
      aspect_ratio = aspect_ratio,
      near = near,
      far = far,
    },
  }
}

make_camera_ortho :: proc(
  width: f32,
  height: f32,
  near: f32,
  far: f32,
) -> Camera {
  return Camera {
    rotation = linalg.QUATERNIONF32_IDENTITY,
    projection = OrthographicProjection {
      width = width,
      height = height,
      near = near,
      far = far,
    },
  }
}

// Camera creation with look-at functionality
make_camera_look_at :: proc(
  from, to: [3]f32,
  fov, aspect_ratio, near, far: f32,
) -> Camera {
  camera := make_camera_perspective(fov, aspect_ratio, near, far)
  camera_look_at(&camera, from, to)
  return camera
}

// Safe up vector calculation to avoid gimbal lock
@(private = "file")
calculate_safe_up_vector :: proc(forward: [3]f32) -> [3]f32 {
  world_up := [3]f32{0, 1, 0}
  // If forward is nearly parallel with world up, use alternative up
  if math.abs(linalg.dot(forward, world_up)) > 0.999 {
    world_up = {0, 0, 1}  // Use Z-axis as fallback
  }
  return world_up
}

// Quaternion creation from forward and up vectors
@(private = "file")
quaternion_from_forward_and_up :: proc(forward, up: [3]f32) -> quaternion128 {
  right := linalg.normalize(linalg.cross(forward, up))
  recalc_up := linalg.cross(right, forward)
  // Create rotation matrix from basis vectors
  rotation_matrix := linalg.Matrix3f32{
    right.x,     recalc_up.x,     -forward.x,
    right.y,     recalc_up.y,     -forward.y,
    right.z,     recalc_up.z,     -forward.z,
  }
  return linalg.quaternion_from_matrix3(rotation_matrix)
}

// Universal camera manipulation functions
// Look at target with automatic up vector calculation
camera_look_at :: proc(camera: ^Camera, from, to: [3]f32, world_up := [3]f32{0, 1, 0}) {
  camera.position = from
  forward := linalg.normalize(to - from)
  // Safe up vector calculation
  safe_up := world_up
  if math.abs(linalg.dot(forward, world_up)) > 0.999 {
    safe_up = {0, 0, 1}  // Use Z-axis if Y is too close to forward
    if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
      safe_up = {1, 0, 0}  // Use X-axis as last resort
    }
  }
  // linalg.quaternion_from_forward_and_up expect row-major matrix
  // our custom calculation expect column-major matrix
  camera.rotation = quaternion_from_forward_and_up(forward, safe_up)
}

// Set camera position
camera_set_position :: proc(camera: ^Camera, position: [3]f32) {
  camera.position = position
}

// Set camera rotation
camera_set_rotation :: proc(camera: ^Camera, rotation: quaternion128) {
  camera.rotation = rotation
}

// Move camera by delta
camera_move :: proc(camera: ^Camera, delta: [3]f32) {
  camera.position += delta
}

// Rotate camera by yaw/pitch deltas
camera_rotate :: proc(camera: ^Camera, delta_yaw, delta_pitch: f32) {
  // Create rotation quaternions for yaw (around world Y) and pitch (around local X)
  yaw_rotation := linalg.quaternion_angle_axis(delta_yaw, [3]f32{0, 1, 0})
  right := camera_right(camera^)
  pitch_rotation := linalg.quaternion_angle_axis(delta_pitch, right)
  // Apply rotations
  camera.rotation = yaw_rotation * camera.rotation
  camera.rotation = camera.rotation * pitch_rotation
  camera.rotation = linalg.quaternion_normalize(camera.rotation)
}

calculate_projection_matrix :: proc(
  camera: Camera,
) -> matrix[4,4]f32 {
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

calculate_view_matrix :: proc(camera: Camera) -> matrix[4,4]f32 {
  forward_vec := camera_forward(camera)
  up_vec := camera_up(camera)
  target_point := camera.position + forward_vec
  return linalg.matrix4_look_at(camera.position, target_point, up_vec)
}

camera_forward :: proc(camera: Camera) -> [3]f32 {
  return linalg.quaternion_mul_vector3(
    camera.rotation,
    -linalg.VECTOR3F32_Z_AXIS,
  )
}

camera_right :: proc(camera: Camera) -> [3]f32 {
  return linalg.quaternion_mul_vector3(
    camera.rotation,
    linalg.VECTOR3F32_X_AXIS,
  )
}

camera_up :: proc(camera: Camera) -> [3]f32 {
  return linalg.quaternion_mul_vector3(
    camera.rotation,
    linalg.VECTOR3F32_Y_AXIS,
  )
}

// Helper to get both view and projection matrices simultaneously
camera_calculate_matrices :: proc(camera: Camera) -> (view: matrix[4,4]f32, projection: matrix[4,4]f32) {
  view = calculate_view_matrix(camera)
  projection = calculate_projection_matrix(camera)
  return
}

camera_make_frustum :: proc(camera: Camera) -> Frustum {
  view_matrix, proj_matrix := camera_calculate_matrices(camera)
  return make_frustum(proj_matrix * view_matrix)
}

camera_update_aspect_ratio :: proc(camera: ^Camera, new_aspect_ratio: f32) {
  switch &proj in camera.projection {
  case PerspectiveProjection:
    proj.aspect_ratio = new_aspect_ratio
  case OrthographicProjection:
    // For orthographic projection, we might want to adjust width/height
    // based on the aspect ratio, but this depends on the desired behavior
  }
}

camera_get_near_far :: proc(camera: Camera) -> (near: f32, far: f32) {
  switch proj in camera.projection {
  case PerspectiveProjection:
    return proj.near, proj.far
  case OrthographicProjection:
    return proj.near, proj.far
  case:
    return 0.1, 50.0
  }
}
