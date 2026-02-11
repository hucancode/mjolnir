package world

import cont "../containers"
import "core:math"
import "core:slice"

LightType :: enum u32 {
  POINT       = 0,
  DIRECTIONAL = 1,
  SPOT        = 2,
}

Light :: struct {
  type:          LightType, // LightType
  radius:        f32, // range for point/spot lights
  angle_inner:   f32, // inner cone angle for spot lights
  angle_outer:   f32, // outer cone angle for spot lights
  color:         [4]f32, // RGB + intensity
  cast_shadow:   b32, // 0 = no shadow, 1 = cast shadow
  node_handle:   NodeHandle, // Associated scene node for transform updates
  camera_handle: CameraHandle, // Camera (regular or spherical based on light type)
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
  self.camera_handle = {}
}

light_destroy :: proc(self: ^Light, world: ^World, handle: LightHandle) {
  unregister_active_light(world, handle)
}

create_light :: proc(
  world: ^World,
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
  handle, light, ok = cont.alloc(&world.lights, LightHandle)
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
  stage_light_data(&world.staging, handle)
  register_active_light(world, handle)
  return handle, true
}

destroy_light :: proc(world: ^World, handle: LightHandle) -> bool {
  light, freed := cont.free(&world.lights, handle)
  if !freed do return false
  light_destroy(light, world, handle)
  return true
}

register_active_light :: proc(world: ^World, handle: LightHandle) {
  if slice.contains(world.active_lights[:], handle) do return
  append(&world.active_lights, handle)
}

unregister_active_light :: proc(world: ^World, handle: LightHandle) {
  if i, found := slice.linear_search(world.active_lights[:], handle); found {
    unordered_remove(&world.active_lights, i)
  }
}
