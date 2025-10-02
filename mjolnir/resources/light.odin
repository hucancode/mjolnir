package resources

import "../geometry"
import "../gpu"
import "core:log"
import "core:math"
import "core:math/linalg"
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
  shadow_map:   u32, // texture index in bindless array
  camera_index: u32, // index into camera matrices buffer
  cast_shadow:  b32, // 0 = no shadow, 1 = cast shadow
}

Light :: struct {
  using data:               LightData,
  node_handle:              Handle, // Associated scene node for transform updates
  // Shadow render target indices (into Renderer.render_targets)
  shadow_target_index:      int, // For spot/directional lights
  cube_shadow_target_index: [6]int, // For point lights (6 faces)
  last_world_matrix:        matrix[4, 4]f32, // Previous frame's transform
  has_moved:                bool, // True if transform changed since last render
  shadow_slot_index:        int, // Assigned slot in shadow pool (-1 if none)
}

// Create a new light and return its handle
create_light :: proc(
  manager: ^Manager,
  gpu_context: ^gpu.GPUContext,
  light_type: LightType,
  node_handle: Handle,
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  angle_inner: f32 = math.PI * 0.16,
  angle_outer: f32 = math.PI * 0.2,
  cast_shadow: b32 = true,
) -> Handle {
  handle, light := alloc(&manager.lights)
  light.type = light_type
  light.node_handle = node_handle
  light.cast_shadow = cast_shadow
  light.color = color
  light.radius = radius
  light.angle_inner = angle_inner
  light.angle_outer = angle_outer
  light.cast_shadow = b32(cast_shadow)
  light.node_index = node_handle.index
  light.shadow_target_index = -1
  for i in 0 ..< 6 do light.cube_shadow_target_index[i] = -1
  light.last_world_matrix = linalg.MATRIX4F32_IDENTITY
  light.has_moved = true
  light.shadow_slot_index = -1
  gpu.write(&manager.lights_buffer, &light.data, int(handle.index))
  return handle
}

// Destroy a light handle
destroy_light :: proc(
  manager: ^Manager,
  handle: Handle,
) -> bool {
  _, freed := free(&manager.lights, handle)
  return freed
}

// Get a light by handle
get_light :: proc(
  manager: ^Manager,
  handle: Handle,
) -> (
  ret: ^Light,
  ok: bool,
) #optional_ok {
  ret, ok = get(manager.lights, handle)
  return
}

// Update light color and intensity
set_light_color :: proc(
  manager: ^Manager,
  handle: Handle,
  color: [3]f32,
  intensity: f32,
) {
  if light, ok := get(manager.lights, handle); ok {
    light.color = {color.x, color.y, color.z, intensity}
    gpu.write(&manager.lights_buffer, &light.data, int(handle.index))
  }
}

// Update light radius for point/spot lights
set_light_radius :: proc(manager: ^Manager, handle: Handle, radius: f32) {
  if light, ok := get(manager.lights, handle); ok {
    light.radius = radius
    gpu.write(&manager.lights_buffer, &light.data, int(handle.index))
  }
}

// Update spot light angles
set_spot_light_angles :: proc(
  manager: ^Manager,
  handle: Handle,
  inner_angle: f32,
  outer_angle: f32,
) {
  if light, ok := get(manager.lights, handle); ok {
    light.angle_inner = inner_angle
    light.angle_outer = outer_angle
    gpu.write(&manager.lights_buffer, &light.data, int(handle.index))
  }
}

// Enable/disable shadow casting
set_light_cast_shadow :: proc(
  manager: ^Manager,
  handle: Handle,
  cast_shadow: b32,
) {
  if light, ok := get(manager.lights, handle); ok {
    light.cast_shadow = cast_shadow
    gpu.write(&manager.lights_buffer, &light.data, int(handle.index))
  }
}
