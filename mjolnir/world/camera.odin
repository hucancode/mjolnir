package world

import d "../data"
import "../geometry"
import "core:log"
import "core:math"
import "core:math/linalg"

MAX_DEPTH_MIPS_LEVEL :: d.MAX_DEPTH_MIPS_LEVEL
PerspectiveProjection :: d.PerspectiveProjection
OrthographicProjection :: d.OrthographicProjection

// Re-export types from data module
CameraData :: d.CameraData
SphericalCameraData :: d.SphericalCameraData
AttachmentType :: d.AttachmentType
PassType :: d.PassType
PassTypeSet :: d.PassTypeSet
Camera :: d.Camera
SphericalCamera :: d.SphericalCamera
camera_view_matrix :: d.camera_view_matrix
camera_projection_matrix :: d.camera_projection_matrix
camera_forward :: d.camera_forward
camera_right :: d.camera_right
camera_up :: d.camera_up
camera_get_near_far :: d.camera_get_near_far
camera_look_at :: d.camera_look_at
camera_get_visible_count :: d.camera_get_visible_count
camera_viewport_to_world_ray :: d.camera_viewport_to_world_ray

// Camera initialization in world is CPU-only.

camera_init :: proc(
  camera: ^Camera,
  width, height: u32,
  enabled_passes: PassTypeSet = {
    .SHADOW,
    .GEOMETRY,
    .LIGHTING,
    .TRANSPARENCY,
    .PARTICLES,
    .NAVIGATION,
    .POST_PROCESS,
  },
  camera_position: [3]f32 = {0, 0, 3},
  camera_target: [3]f32 = {0, 0, 0},
  fov: f32 = 1.57079632679,
  near_plane: f32 = 0.1,
  far_plane: f32 = 100.0,
  max_draws: u32 = d.MAX_NODES_IN_SCENE,
) -> bool {
  // Initialize CPU-only camera fields
  camera.rotation = linalg.QUATERNIONF32_IDENTITY
  camera.projection = PerspectiveProjection {
    fov          = fov,
    aspect_ratio = f32(width) / f32(height),
    near         = near_plane,
    far          = far_plane,
  }
  camera.position = camera_position
  forward := linalg.normalize(camera_target - camera_position)
  safe_up := linalg.VECTOR3F32_Y_AXIS
  if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
    safe_up = linalg.VECTOR3F32_Z_AXIS
    if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
      safe_up = linalg.VECTOR3F32_X_AXIS
    }
  }
  right := linalg.normalize(linalg.cross(forward, safe_up))
  recalc_up := linalg.cross(right, forward)
  rotation_matrix := matrix[3, 3]f32{
    right.x, recalc_up.x, -forward.x,
    right.y, recalc_up.y, -forward.y,
    right.z, recalc_up.z, -forward.z,
  }
  camera.rotation = linalg.to_quaternion(rotation_matrix)
  camera.extent = {width, height}
  camera.enabled_passes = enabled_passes
  camera.enable_culling = true
  camera.enable_depth_pyramid = true
  camera.draw_list_source_handle = {}
  return true
}

camera_init_orthographic :: proc(
  camera: ^Camera,
  width, height: u32,
  enabled_passes: PassTypeSet = {.SHADOW},
  camera_position: [3]f32 = {0, 0, 0},
  camera_target: [3]f32 = {0, 0, -1},
  ortho_width: f32 = 100.0,
  ortho_height: f32 = 100.0,
  near_plane: f32 = 1.0,
  far_plane: f32 = 1000.0,
  max_draws: u32 = d.MAX_NODES_IN_SCENE,
) -> bool {
  // Initialize CPU-only camera fields
  camera.rotation = linalg.QUATERNIONF32_IDENTITY
  camera.projection = OrthographicProjection {
    width  = ortho_width,
    height = ortho_height,
    near   = near_plane,
    far    = far_plane,
  }
  camera.position = camera_position
  forward := linalg.normalize(camera_target - camera_position)
  safe_up := linalg.VECTOR3F32_Y_AXIS
  if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
    safe_up = linalg.VECTOR3F32_Z_AXIS
    if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
      safe_up = linalg.VECTOR3F32_X_AXIS
    }
  }
  right := linalg.normalize(linalg.cross(forward, safe_up))
  recalc_up := linalg.cross(right, forward)
  rotation_matrix := matrix[3, 3]f32{
    right.x, recalc_up.x, -forward.x,
    right.y, recalc_up.y, -forward.y,
    right.z, recalc_up.z, -forward.z,
  }
  camera.rotation = linalg.to_quaternion(rotation_matrix)
  camera.extent = {width, height}
  camera.enabled_passes = enabled_passes
  camera.enable_culling = true
  camera.enable_depth_pyramid = true
  camera.draw_list_source_handle = {}
  return true
}

camera_destroy :: proc(self: ^Camera) {
  // CPU-only camera data needs no explicit destroy.
}

camera_resize :: proc(
  camera: ^Camera,
  width, height: u32,
) -> bool {
  // Update CPU extent
  if camera.extent[0] == width && camera.extent[1] == height do return true
  camera.extent = {width, height}

  // Update aspect ratio if perspective
  if perspective, ok := &camera.projection.(PerspectiveProjection); ok {
    perspective.aspect_ratio = f32(width) / f32(height)
  }
  return true
}

camera_use_external_draw_list :: proc(
  target_camera: ^Camera,
  source_camera: ^Camera,
) {
  // Legacy pointer-based API cannot resolve a stable source handle.
  // Keep behavior explicit and route callers to the handle-based variant.
  log.warn("camera_use_external_draw_list: use camera_use_external_draw_list_handle")
  target_camera.draw_list_source_handle = {}
  target_camera.enable_culling = false
  target_camera.enable_depth_pyramid = false
}

camera_use_external_draw_list_handle :: proc(
  target_camera: ^Camera,
  source_camera_handle: d.CameraHandle,
) {
  target_camera.draw_list_source_handle = source_camera_handle
  target_camera.enable_culling = false
  target_camera.enable_depth_pyramid = false
}

camera_use_own_draw_list :: proc(
  target_camera: ^Camera,
) {
  target_camera.draw_list_source_handle = {}
  target_camera.enable_culling = true
  target_camera.enable_depth_pyramid = true
}
