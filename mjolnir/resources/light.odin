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
  node_handle:   Handle, // Associated scene node for transform updates
  camera_handle: Handle, // Camera (regular or spherical based on light type)
}

light_init :: proc(
  self: ^Light,
  light_type: LightType,
  node_handle: Handle,
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
  handle: Handle,
  self: ^Light,
) -> vk.Result {
  return gpu.write(&rm.lights_buffer.buffer, &self.data, int(handle.index))
}

light_destroy :: proc(self: ^Light, rm: ^Manager, handle: Handle) {
  unregister_active_light(rm, handle)
}

create_light :: proc(
  rm: ^Manager,
  gctx: ^gpu.GPUContext,
  light_type: LightType,
  node_handle: Handle,
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  angle_inner: f32 = math.PI * 0.16,
  angle_outer: f32 = math.PI * 0.2,
  cast_shadow: b32 = true,
) -> (
  handle: Handle,
  ok: bool,
) {
  light: ^Light
  handle, light, ok = cont.alloc(&rm.lights)
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
  handle: Handle,
) -> bool {
  light, freed := cont.free(&rm.lights, handle)
  if !freed do return false
  light_destroy(light, rm, handle)
  return true
}

update_light_gpu_data :: proc(rm: ^Manager, handle: Handle) {
  if light, ok := cont.get(rm.lights, handle); ok {
    light_upload_gpu_data(rm, handle, light)
  }
}

update_light_camera :: proc(rm: ^Manager, frame_index: u32 = 0) {
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
    if light.cast_shadow && light.camera_handle.generation != 0 {
      #partial switch light.type {
      case .POINT:
        // Point lights use spherical cameras
        spherical_cam := cont.get(rm.spherical_cameras, light.camera_handle)
        if spherical_cam != nil {
          spherical_cam.center = light_position
          shadow_map_id = spherical_cam.depth_cube[frame_index].index
        }
      case .DIRECTIONAL:
        // TODO: Implement directional light later
        cam := cont.get(rm.cameras, light.camera_handle)
        if cam != nil {
          camera_position := light_position - light_direction * 50.0 // Far back
          target_position := light_position
          camera_look_at(cam, camera_position, target_position)
          shadow_map_id = cam.attachments[.DEPTH][frame_index].index
        }
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

register_active_light :: proc(rm: ^Manager, handle: Handle) {
  // TODO: if this list get more than 10000 items, we need to use a map
  if slice.contains(rm.active_lights[:], handle) do return
  append(&rm.active_lights, handle)
}

unregister_active_light :: proc(rm: ^Manager, handle: Handle) {
  if i, found := slice.linear_search(rm.active_lights[:], handle); found {
    unordered_remove(&rm.active_lights, i)
  }
}
