package world

import cont "../containers"
import d "../data"
import "core:math"
import "core:slice"

// Re-export types from data module
LightType :: d.LightType
LightData :: d.LightData
Light :: d.Light
light_init :: d.light_init

light_destroy :: proc(self: ^Light, world: ^World, handle: d.LightHandle) {
  unregister_active_light(world, handle)
}

create_light :: proc(
  world: ^World,
  light_type: LightType,
  node_handle: d.NodeHandle,
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  angle_inner: f32 = math.PI * 0.16,
  angle_outer: f32 = math.PI * 0.2,
  cast_shadow: b32 = true,
) -> (
  handle: d.LightHandle,
  ok: bool,
) #optional_ok {
  light: ^Light
  handle, light, ok = cont.alloc(&world.lights, d.LightHandle)
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
  register_active_light(world, handle)
  return handle, true
}

destroy_light :: proc(
  world: ^World,
  handle: d.LightHandle,
) -> bool {
  light, freed := cont.free(&world.lights, handle)
  if !freed do return false
  light_destroy(light, world, handle)
  return true
}

register_active_light :: proc(world: ^World, handle: d.LightHandle) {
  if slice.contains(world.active_lights[:], handle) do return
  append(&world.active_lights, handle)
}

unregister_active_light :: proc(world: ^World, handle: d.LightHandle) {
  if i, found := slice.linear_search(world.active_lights[:], handle); found {
    unordered_remove(&world.active_lights, i)
  }
}
