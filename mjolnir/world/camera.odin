package world

import "../geometry"
import "core:log"
import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

PassType :: enum {
  SHADOW       = 0,
  GEOMETRY     = 1,
  LIGHTING     = 2,
  TRANSPARENCY = 3,
  PARTICLES    = 4,
  NAVIGATION   = 5,
  DEBUG_DRAW   = 6,
  POST_PROCESS = 7,
}

PassTypeSet :: bit_set[PassType;u32]

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

// Camera (CPU-only data, managed by World module)
Camera :: struct {
  position:                [3]f32,
  rotation:                quaternion128,
  projection:              union {
    PerspectiveProjection,
    OrthographicProjection,
  },
  extent:                  [2]u32, // width, height
  enabled_passes:          PassTypeSet,
  enable_culling:          bool,
  enable_depth_pyramid:    bool,
  draw_list_source_handle: CameraHandle,
}

// SphericalCamera (CPU-only data, managed by World module)
// Captures a full sphere (omnidirectional view) into a cube map
SphericalCamera :: struct {
  center:    [3]f32, // Center position of the sphere
  radius:    f32, // Capture radius
  near:      f32, // Near plane
  far:       f32, // Far plane
  size:      u32, // Resolution of cube map faces (size x size)
  max_draws: u32, // Maximum number of draw calls
}

camera_view_matrix :: proc(camera: ^Camera) -> matrix[4, 4]f32 {
  forward_vec := camera_forward(camera)
  up_vec := camera_up(camera)
  target_point := camera.position + forward_vec
  return linalg.matrix4_look_at(camera.position, target_point, up_vec)
}

camera_projection_matrix :: proc(camera: ^Camera) -> matrix[4, 4]f32 {
  switch proj in camera.projection {
  case PerspectiveProjection:
    return linalg.matrix4_perspective(
      proj.fov,
      proj.aspect_ratio,
      proj.near,
      proj.far,
    )
  case OrthographicProjection:
    hw := proj.width / 2
    hh := proj.height / 2
    return matrix[4, 4]f32{
      1 / hw, 0, 0, 0,
      0, 1 / hh, 0, 0,
      0, 0, 1 / (proj.near - proj.far), 0,
      0, 0, proj.near / (proj.near - proj.far), 1,
    }
  case:
    return linalg.MATRIX4F32_IDENTITY
  }
}

camera_forward :: proc(self: ^Camera) -> [3]f32 {
  return -geometry.qz(self.rotation)
}

camera_right :: proc(self: ^Camera) -> [3]f32 {
  return geometry.qx(self.rotation)
}

camera_up :: proc(self: ^Camera) -> [3]f32 {
  return geometry.qy(self.rotation)
}

camera_get_near_far :: proc(self: ^Camera) -> (near: f32, far: f32) {
  switch proj in self.projection {
  case PerspectiveProjection:
    return proj.near, proj.far
  case OrthographicProjection:
    return proj.near, proj.far
  case:
    return 0.1, 50.0
  }
}

camera_look_at :: proc(self: ^Camera, from, to: [3]f32) {
  self.position = from
  forward := linalg.normalize(to - from)
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
  self.rotation = linalg.to_quaternion(rotation_matrix)
}

camera_update_aspect_ratio :: proc(self: ^Camera, new_aspect_ratio: f32) {
  switch &proj in self.projection {
  case PerspectiveProjection:
    proj.aspect_ratio = new_aspect_ratio
  case OrthographicProjection:
  // For orthographic projection, might want to adjust width/height
  }
}

// TODO: this procedure has around 8 matrices operations, if you run this thousands times per frame you should optimize it first
camera_viewport_to_world_ray :: proc(
  camera: ^Camera,
  mouse_x, mouse_y: f32,
) -> (
  ray_origin: [3]f32,
  ray_dir: [3]f32,
) {
  // Convert screen coordinates to normalized device coordinates (NDC)
  ndc_x := (2.0 * mouse_x) / f32(camera.extent[0]) - 1.0
  ndc_y := 1.0 - (2.0 * mouse_y) / f32(camera.extent[1])
  // Get view and projection matrices
  view_matrix := camera_view_matrix(camera)
  proj_matrix := camera_projection_matrix(camera)
  inv_proj := linalg.matrix4_inverse(proj_matrix)
  inv_view := linalg.matrix4_inverse(view_matrix)
  // Ray in clip space
  ray_clip := [4]f32{ndc_x, ndc_y, -1.0, 1.0}
  // Ray in view space
  ray_eye := inv_proj * ray_clip
  ray_eye = [4]f32{ray_eye.x, ray_eye.y, -1.0, 0.0}
  // Ray in world space
  ray_world_4 := inv_view * ray_eye
  ray_dir = linalg.normalize(ray_world_4.xyz)
  ray_origin = camera.position
  return ray_origin, ray_dir
}

camera_init :: proc(
  camera: ^Camera,
  width, height: u32,
  enabled_passes: PassTypeSet = {
    .SHADOW,
    .GEOMETRY,
    .LIGHTING,
    .TRANSPARENCY,
    .PARTICLES,
    .POST_PROCESS,
  },
  camera_position: [3]f32 = {0, 0, 3},
  camera_target: [3]f32 = {0, 0, 0},
  fov: f32 = 1.57079632679,
  near_plane: f32 = 0.1,
  far_plane: f32 = 100.0,
) -> vk.Result {
  camera.rotation = linalg.QUATERNIONF32_IDENTITY
  camera.projection = PerspectiveProjection {
    fov          = fov,
    aspect_ratio = f32(width) / f32(height),
    near         = near_plane,
    far          = far_plane,
  }
  camera.position = camera_position
  camera_look_at(camera, camera_position, camera_target)
  camera.extent = {width, height}
  camera.enabled_passes = enabled_passes
  camera.enable_culling = true
  camera.enable_depth_pyramid = true
  camera.draw_list_source_handle = {}
  return .SUCCESS
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
) -> vk.Result {
  camera.rotation = linalg.QUATERNIONF32_IDENTITY
  camera.projection = OrthographicProjection {
    width  = ortho_width,
    height = ortho_height,
    near   = near_plane,
    far    = far_plane,
  }
  camera.position = camera_position
  camera_look_at(camera, camera_position, camera_target)
  camera.extent = {width, height}
  camera.enabled_passes = enabled_passes
  camera.enable_culling = true
  camera.enable_depth_pyramid = true
  camera.draw_list_source_handle = {}
  return .SUCCESS
}

camera_resize :: proc(camera: ^Camera, width, height: u32) -> vk.Result {
  if camera.extent[0] == width && camera.extent[1] == height do return .SUCCESS
  camera.extent = {width, height}
  if perspective, ok := &camera.projection.(PerspectiveProjection); ok {
    perspective.aspect_ratio = f32(width) / f32(height)
  }
  return .SUCCESS
}

camera_use_external_draw_list_handle :: proc(
  target_camera: ^Camera,
  source_camera_handle: CameraHandle,
) {
  target_camera.draw_list_source_handle = source_camera_handle
  target_camera.enable_culling = false
  target_camera.enable_depth_pyramid = false
}

camera_use_own_draw_list :: proc(target_camera: ^Camera) {
  target_camera.draw_list_source_handle = {}
  target_camera.enable_culling = true
  target_camera.enable_depth_pyramid = true
}

spherical_camera_init :: proc(
  self: ^SphericalCamera,
  size: u32,
  center: [3]f32 = {0, 0, 0},
  radius: f32 = 1.0,
  near: f32 = 0.1,
  far: f32 = 100.0,
  max_draws: u32 = MAX_NODES_IN_SCENE,
) -> bool {
  // Initialize CPU-only fields
  self.center = center
  self.radius = radius
  self.near = near
  self.far = far
  self.size = size
  self.max_draws = max_draws
  return true
}

spherical_camera_destroy :: proc(self: ^SphericalCamera) {
  self^ = {}
}
