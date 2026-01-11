package resources

import cont "../containers"
import "../geometry"
import "../gpu"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import vk "vendor:vulkan"

LightType :: enum u32 {
  POINT       = 0,
  DIRECTIONAL = 1,
  SPOT        = 2,
}

LightData :: struct {
  color:        [4]f32, // RGB + intensity
  radius:       f32, // range for point/spot lights
  angle_inner:  f32, // inner cone angle for spot lights
  angle_outer:  f32, // outer cone angle for spot lights
  type:         LightType, // LightType
  node_index:   u32, // index into world matrices buffer
  camera_index: u32, // index into camera matrices buffer
  cast_shadow:  b32, // 0 = no shadow, 1 = cast shadow
  _padding:     u32, // Maintain 16-byte alignment
}

DynamicLightData :: struct {
  position:   [4]f32, // xyz = position, w = unused
  shadow_map: u32, // texture index in bindless array (per-frame)
  _padding:   [3]u32, // Maintain 16-byte alignment
}

Light :: struct {
  using data:    LightData,
  node_handle:   NodeHandle, // Associated scene node for transform updates
  camera_handle: CameraHandle, // Camera (regular or spherical based on light type) - can be CameraHandle or SphereCameraHandle
}

light_init :: proc(
  self: ^Light,
  light_type: LightType,
  node_handle: NodeHandle,
  color: [4]f32,
  radius: f32,
  angle_inner: f32,
  angle_outer: f32,
  cast_shadow: b32,
) {
  self.type = light_type
  self.node_handle = node_handle
  self.cast_shadow = cast_shadow
  self.color = color
  self.radius = radius
  self.angle_inner = angle_inner
  self.angle_outer = angle_outer
  self.node_index = node_handle.index
  self.camera_handle = {}
  self.camera_index = 0xFFFFFFFF
}

light_upload_gpu_data :: proc(
  rm: ^Manager,
  handle: LightHandle,
  self: ^Light,
) -> vk.Result {
  return gpu.write(&rm.lights_buffer.buffer, &self.data, int(handle.index))
}

light_destroy :: proc(self: ^Light, rm: ^Manager, handle: LightHandle) {
  unregister_active_light(rm, handle)
}

create_light :: proc(
  rm: ^Manager,
  gctx: ^gpu.GPUContext,
  light_type: LightType,
  node_handle: NodeHandle,
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  angle_inner: f32 = math.PI * 0.16,
  angle_outer: f32 = math.PI * 0.2,
  cast_shadow: b32 = true,
) -> (
  handle: LightHandle,
  ok: bool,
) #optional_ok {
  light: ^Light
  handle, light, ok = cont.alloc(&rm.lights, LightHandle)
  if !ok do return {}, false
  light_init(
    light,
    light_type,
    node_handle,
    color,
    radius,
    angle_inner,
    angle_outer,
    cast_shadow,
  )
  ok = light_upload_gpu_data(rm, handle, light) == .SUCCESS
  if !ok do return {}, false
  register_active_light(rm, handle)
  return handle, true
}

destroy_light :: proc(
  rm: ^Manager,
  gctx: ^gpu.GPUContext,
  handle: LightHandle,
) -> bool {
  light, freed := cont.free(&rm.lights, handle)
  if !freed do return false
  light_destroy(light, rm, handle)
  return true
}

update_light_gpu_data :: proc(rm: ^Manager, handle: LightHandle) {
  if light, ok := cont.get(rm.lights, handle); ok {
    light_upload_gpu_data(rm, handle, light)
  }
}

@(private)
compute_light_space_aabb :: proc(
  world_corners: [8][3]f32,
  light_view_matrix: matrix[4, 4]f32,
) -> (
  min_bounds, max_bounds: [3]f32,
) {
  first_light_space :=
    (light_view_matrix * [4]f32{world_corners[0].x, world_corners[0].y, world_corners[0].z, 1.0}).xyz
  min_bounds = first_light_space
  max_bounds = first_light_space
  for i in 1 ..< 8 {
    light_space :=
      (light_view_matrix * [4]f32{world_corners[i].x, world_corners[i].y, world_corners[i].z, 1.0}).xyz
    min_bounds = linalg.min(min_bounds, light_space)
    max_bounds = linalg.max(max_bounds, light_space)
  }
  return min_bounds, max_bounds
}

update_light_camera :: proc(
  rm: ^Manager,
  main_camera_handle: CameraHandle,
  frame_index: u32 = 0,
) {
  for handle, light_index in rm.active_lights {
    light := cont.get(rm.lights, handle) or_continue
    // Get light's world transform from node
    node_data := gpu.get(&rm.node_data_buffer.buffer, light.node_index)
    if node_data == nil do continue
    world_matrix := gpu.get(&rm.world_matrix_buffer.buffer, light.node_index)
    if world_matrix == nil do continue
    // Extract position and direction from world matrix
    light_position := world_matrix[3].xyz
    light_direction := world_matrix[2].xyz
    shadow_map_id: u32 = 0xFFFFFFFF
    // Update shadow camera transforms only for shadow-casting lights
    if light.cast_shadow {
      #partial switch light.type {
      case .POINT:
        // Point lights use spherical cameras
        spherical_cam := cont.get(rm.spherical_cameras, light.camera_handle)
        if spherical_cam != nil {
          spherical_cam.center = light_position
          shadow_map_id = spherical_cam.depth_cube[frame_index].index
        }
      case .DIRECTIONAL:
        cam := cont.get(rm.cameras, light.camera_handle)
        if cam == nil do continue
        main_cam := cont.get(rm.cameras, main_camera_handle)
        if main_cam == nil {
          far_dist: f32 = 100.0
          if ortho, ok := cam.projection.(OrthographicProjection); ok {
            far_dist = ortho.far
          }
          camera_position :=
            light_position - light_direction * (far_dist * 0.5)
          target_position := light_position + light_direction
          camera_look_at(cam, camera_position, target_position)
          shadow_map_id = cam.attachments[.DEPTH][frame_index].index
          continue
        }
        main_view := camera_view_matrix(main_cam)
        // Build projection matrix from limited projection
        limited_proj_matrix := linalg.MATRIX4F32_IDENTITY
        DIRECTIONAL_LIGHT_SHADOW_MAX_DISTANCE :: 10.0
        switch proj in main_cam.projection {
        case PerspectiveProjection:
          limited_proj_matrix = linalg.matrix4_perspective(
            proj.fov,
            proj.aspect_ratio,
            proj.near,
            min(proj.far, DIRECTIONAL_LIGHT_SHADOW_MAX_DISTANCE),
          )
        case OrthographicProjection:
          limited_proj_matrix = linalg.matrix_ortho3d(
            -proj.width / 2,
            proj.width / 2,
            -proj.height / 2,
            proj.height / 2,
            proj.near,
            min(proj.far, DIRECTIONAL_LIGHT_SHADOW_MAX_DISTANCE),
          )
        }
        frustum_corners := geometry.frustum_corners_world(
          main_view,
          limited_proj_matrix,
        )
        // Build light coordinate system (rotation only, no translation)
        light_forward := linalg.normalize(light_direction)
        light_up := linalg.VECTOR3F32_Y_AXIS
        if math.abs(linalg.dot(light_forward, light_up)) > 0.95 {
          light_up = linalg.VECTOR3F32_Z_AXIS
        }
        light_right := linalg.normalize(linalg.cross(light_up, light_forward))
        light_up_recalc := linalg.cross(light_forward, light_right)
        // Build 3x3 rotation matrix: world → light rotated frame
        // Each row is a basis vector (right, up, forward)
        light_rotation := matrix[3, 3]f32{
          light_right.x, light_right.y, light_right.z,
          light_up_recalc.x, light_up_recalc.y, light_up_recalc.z,
          light_forward.x, light_forward.y, light_forward.z,
        }
        // Transform frustum corners to light-rotated frame (rotation only)
        rotated_corners: [8][3]f32
        for corner, i in frustum_corners {
          rotated_corners[i] = light_rotation * corner
        }
        // Compute AABB in rotated frame
        aabb_min := rotated_corners[0]
        aabb_max := rotated_corners[0]
        #unroll for i in 1 ..< 8 {
          aabb_min = linalg.min(aabb_min, rotated_corners[i])
          aabb_max = linalg.max(aabb_max, rotated_corners[i])
        }
        // Add padding to ensure objects near frustum edges cast shadows
        padding_factor: f32 = 0.1
        aabb_size := aabb_max - aabb_min
        aabb_min -= aabb_size * padding_factor
        aabb_max += aabb_size * padding_factor
        aabb_size = aabb_max - aabb_min
        // Compute AABB center in rotated frame
        aabb_center_rotated := (aabb_min + aabb_max) * 0.5
        // Position camera in rotated frame:
        // - Centered on AABB in XY
        // - Positioned behind AABB center in Z for balanced depth range
        // This allows shadow casters on both sides of the frustum
        near_plane: f32 = 0.1
        camera_distance := (aabb_size.z * 0.5) + near_plane
        camera_pos_rotated := [3]f32 {
          aabb_center_rotated.x,
          aabb_center_rotated.y,
          aabb_center_rotated.z - camera_distance,
        }
        log.debugf(
          "frustum_corners=%v, rotated_coners=%v, camera_pos_rotated=%v, aabb_center_rotated=%v, aabb_size=%v",
          frustum_corners,
          rotated_corners,
          camera_pos_rotated,
          aabb_center_rotated,
          aabb_size,
        )
        far_plane := aabb_size.z + near_plane
        // Transform camera position back to world space (inverse rotation)
        light_rotation_inv := linalg.transpose(light_rotation)
        camera_position := light_rotation_inv * camera_pos_rotated
        // Build view matrix: look from camera_position in light_forward direction
        target_position := camera_position + light_forward
        // Set orthographic projection bounds based on AABB
        if ortho_proj, ok := &cam.projection.(OrthographicProjection); ok {
          ortho_proj.width = aabb_size.x
          ortho_proj.height = aabb_size.y
          ortho_proj.near = near_plane
          ortho_proj.far = far_plane
          log.debugf(
            "light ortho projection %v",
            ortho_proj,
          )
        }
        // Set camera transform
        camera_look_at(cam, camera_position, target_position)
        // Configure directional light shadow camera to use main camera's draw lists
        // This skips expensive culling compute passes for shadow rendering
        camera_use_external_draw_list(cam, main_cam)
        log.debugf(
          "light position %v looking at %v with the aabb %v camera p=%v, r=%v",
          camera_position,
          target_position,
          aabb_size,
          cam.position,
          cam.rotation,
        )
        shadow_map_id = cam.attachments[.DEPTH][frame_index].index
      case .SPOT:
        cam := cont.get(rm.cameras, light.camera_handle)
        if cam != nil {
          target_position := light_position + light_direction
          camera_look_at(cam, light_position, target_position)
          shadow_map_id = cam.attachments[.DEPTH][frame_index].index
        }
      }
    }
    // Always write dynamic light data (position + shadow_map) for all lights
    dynamic_data := DynamicLightData {
      position   = {light_position.x, light_position.y, light_position.z, 1.0},
      shadow_map = shadow_map_id,
    }
    gpu.write(
      &rm.dynamic_light_data_buffer.buffers[frame_index],
      &dynamic_data,
      light_index,
    )
  }
}

register_active_light :: proc(rm: ^Manager, handle: LightHandle) {
  // TODO: if this list get more than 10000 items, we need to use a map
  if slice.contains(rm.active_lights[:], handle) do return
  append(&rm.active_lights, handle)
}

unregister_active_light :: proc(rm: ^Manager, handle: LightHandle) {
  if i, found := slice.linear_search(rm.active_lights[:], handle); found {
    unordered_remove(&rm.active_lights, i)
  }
}
