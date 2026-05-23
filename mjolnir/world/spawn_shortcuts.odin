package world

import "../gpu"
import "../physics"
import "core:math"

// Mesh attachment shorthand. Defaults match the common case (cast shadows).
mesh_attach :: proc(
  handle: MeshHandle,
  material: MaterialHandle,
  cast_shadow: bool = true,
) -> MeshAttachment {
  return MeshAttachment{handle = handle, material = material, cast_shadow = cast_shadow}
}

spawn_mesh :: proc(
  world: ^World,
  mesh: MeshHandle,
  material: MaterialHandle,
  position: [3]f32 = {0, 0, 0},
  cast_shadow: bool = true,
) -> (NodeHandle, bool) #optional_ok {
  return spawn(world, position, mesh_attach(mesh, material, cast_shadow))
}

// Spawn a point light. Returns the new node handle.
spawn_light_point :: proc(
  world: ^World,
  position: [3]f32 = {0, 0, 0},
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  cast_shadow: bool = true,
) -> (NodeHandle, bool) #optional_ok {
  return spawn(
    world,
    position,
    PointLightAttachment{color = color, radius = radius, cast_shadow = cast_shadow},
  )
}

spawn_light_directional :: proc(
  world: ^World,
  position: [3]f32 = {0, 0, 0},
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  cast_shadow: bool = false,
) -> (NodeHandle, bool) #optional_ok {
  return spawn(
    world,
    position,
    DirectionalLightAttachment{color = color, radius = radius, cast_shadow = cast_shadow},
  )
}

spawn_light_spot :: proc(
  world: ^World,
  position: [3]f32 = {0, 0, 0},
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  angle: f32 = math.PI * 0.2,
  cast_shadow: bool = true,
) -> (NodeHandle, bool) #optional_ok {
  inner := angle * 0.8
  return spawn(
    world,
    position,
    SpotLightAttachment{
      color       = color,
      radius      = radius,
      angle_inner = inner,
      angle_outer = angle,
      cast_shadow = cast_shadow,
    },
  )
}

// Spawn a node carrying an emitter. The emitter is created and bound to the
// node in one step.
spawn_emitter :: proc(
  world: ^World,
  position: [3]f32 = {0, 0, 0},
  texture: gpu.Texture2DHandle = {},
  emission_rate: f32 = 50.0,
  initial_velocity: [3]f32 = {0, 1, 0},
  velocity_spread: f32 = 0.5,
  color_start: [4]f32 = {1, 1, 1, 1},
  color_end: [4]f32 = {1, 1, 1, 0},
  aabb_min: [3]f32 = {-10, -10, -10},
  aabb_max: [3]f32 = {10, 10, 10},
  particle_lifetime: f32 = 2.0,
  position_spread: f32 = 0.0,
  size_start: f32 = 100.0,
  size_end: f32 = 100.0,
  weight: f32 = 1.0,
  weight_spread: f32 = 0.0,
) -> (parent: NodeHandle, ok: bool) #optional_ok {
  parent = spawn(world, position) or_return
  emitter_handle := create_emitter(
    world,
    node_handle       = parent,
    texture_handle    = texture,
    emission_rate     = emission_rate,
    initial_velocity  = initial_velocity,
    velocity_spread   = velocity_spread,
    color_start       = color_start,
    color_end         = color_end,
    aabb_min          = aabb_min,
    aabb_max          = aabb_max,
    particle_lifetime = particle_lifetime,
    position_spread   = position_spread,
    size_start        = size_start,
    size_end          = size_end,
    weight            = weight,
    weight_spread     = weight_spread,
  ) or_return
  spawn_child(world, parent, attachment = EmitterAttachment{handle = emitter_handle}) or_return
  ok = true
  return
}

// Spawn a node carrying a force field. Returns the parent node handle.
spawn_forcefield :: proc(
  world: ^World,
  position: [3]f32 = {0, 0, 0},
  area_of_effect: f32 = 5.0,
  strength: f32 = 1.0,
  tangent_strength: f32 = 0.0,
) -> (parent: NodeHandle, ok: bool) #optional_ok {
  parent = spawn(world, position) or_return
  ff_handle := create_forcefield(
    world,
    node_handle      = parent,
    area_of_effect   = area_of_effect,
    strength         = strength,
    tangent_strength = tangent_strength,
  ) or_return
  spawn_child(world, parent, attachment = ForceFieldAttachment{handle = ff_handle}) or_return
  ok = true
  return
}

// Spawn a node bound to an existing rigid body. The body is created by the
// physics module first, then attached.
spawn_rigid_body :: proc(
  world: ^World,
  body: physics.DynamicRigidBodyHandle,
  position: [3]f32 = {0, 0, 0},
) -> (NodeHandle, bool) #optional_ok {
  return spawn(world, position, RigidBodyAttachment{body_handle = body})
}
