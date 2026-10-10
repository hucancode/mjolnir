package mjolnir

import "physics"
import "render"
import "world"

// Spawn a scene node and draw `attachment` at its transform slot. Pass
// `parent` to spawn a child.
spawn :: proc(
  engine: ^Engine,
  position: [3]f32 = {0, 0, 0},
  attachment: render.Attachment = nil,
  parent: world.NodeHandle = {},
) -> (
  handle: world.NodeHandle,
  ok: bool,
) #optional_ok {
  handle = world.spawn_child(
    &engine.world,
    parent if parent != {} else engine.world.root,
    position,
  ) or_return
  if attachment != nil do render.attach(&engine.render, handle.index, attachment)
  return handle, true
}

spawn_mesh :: proc(
  engine: ^Engine,
  mesh: render.MeshHandle,
  material: render.MaterialHandle,
  position: [3]f32 = {0, 0, 0},
  cast_shadow: bool = true,
  parent: world.NodeHandle = {},
) -> (
  world.NodeHandle,
  bool,
) #optional_ok {
  return spawn(
    engine,
    position,
    render.MeshAttachment{handle = mesh, material = material, cast_shadow = cast_shadow},
    parent,
  )
}

// Builtin primitive mesh with a builtin color material.
spawn_primitive_mesh :: proc(
  engine: ^Engine,
  primitive: render.Primitive = .CUBE,
  color: render.Color = .WHITE,
  position: [3]f32 = {0, 0, 0},
  rotation_angle: f32 = 0,
  rotation_axis: [3]f32 = {0, 1, 0},
  scale_factor: f32 = 1.0,
  cast_shadow := true,
  parent: world.NodeHandle = {},
) -> (
  handle: world.NodeHandle,
  ok: bool,
) #optional_ok {
  handle = spawn_mesh(
    engine,
    render.get_builtin_mesh(&engine.render, primitive),
    render.get_builtin_material(&engine.render, color),
    position,
    cast_shadow,
    parent,
  ) or_return
  if rotation_angle != 0 {
    world.rotate(&engine.world, handle, rotation_angle, rotation_axis)
  }
  if scale_factor != 1.0 do world.scale(&engine.world, handle, scale_factor)
  return handle, true
}

// Flat XZ ground plane that does not cast shadows.
spawn_ground :: proc(
  engine: ^Engine,
  size: f32 = 10.0,
  color: render.Color = .GRAY,
  position: [3]f32 = {0, 0, 0},
) -> world.NodeHandle {
  h, _ := spawn_primitive_mesh(
    engine,
    .QUAD_XZ,
    color,
    position,
    scale_factor = size,
    cast_shadow = false,
  )
  return h
}

spawn_sprite :: proc(
  engine: ^Engine,
  texture: render.Texture2DHandle,
  position: [3]f32 = {0, 0, 0},
  frame_columns: u32 = 1,
  frame_rows: u32 = 1,
  animation: Maybe(render.SpriteAnimation) = nil,
  material: render.MaterialHandle = {},
  parent: world.NodeHandle = {},
) -> (
  node: world.NodeHandle,
  sprite: render.SpriteHandle,
  ok: bool,
) {
  sprite = render.create_sprite(
    &engine.render,
    texture,
    frame_columns,
    frame_rows,
    animation,
  ) or_return
  node, ok = spawn(
    engine,
    position,
    render.SpriteAttachment {
      sprite_handle = sprite,
      mesh_handle = render.get_builtin_mesh(&engine.render, .QUAD_XY),
      material = material if material != {} else render.get_builtin_material(&engine.render, .WHITE),
    },
    parent,
  )
  if !ok do render.destroy_sprite(&engine.render, sprite)
  return
}

// ---------- physics ----------
//
// Bodies link back to their node through `user`; copy their poses into the
// world each tick with:
//   for b in physics.body_poses(&p) do world.set_world_pose(&e.world, world.NodeHandle(b.user), b.position, b.rotation)
//
// The returned bodies and triggers are owned by the caller: despawning the
// node does not destroy them. Pair `world.despawn` with
// `physics.destroy_body` / `physics.destroy_trigger`, or `physics.teardown`.

// Scale that fits render's unit builtin meshes (cube, sphere, cylinder) to a
// collider's extents. Cylinders and fans halve `height` because the builtin
// cylinder has unit half-height.
collider_visual_scale :: proc(collider: physics.Collider) -> [3]f32 {
  switch sh in collider {
  case physics.BoxCollider:      return sh.half_extents
  case physics.SphereCollider:   return {sh.radius, sh.radius, sh.radius}
  case physics.CylinderCollider: return {sh.radius, sh.height * 0.5, sh.radius}
  case physics.FanCollider:      return {sh.radius, sh.height * 0.5, sh.radius}
  }
  return {1, 1, 1}
}

@(private = "file")
attach_visual_mesh :: proc(
  engine: ^Engine,
  parent: world.NodeHandle,
  collider: physics.Collider,
  mesh: render.MeshHandle,
  material: render.MaterialHandle,
  visual_scale: Maybe([3]f32),
  cast_shadow: bool,
) {
  if mesh == {} do return
  visual := spawn_mesh(engine, mesh, material, cast_shadow = cast_shadow, parent = parent)
  s := visual_scale.? or_else collider_visual_scale(collider)
  world.scale_xyz(&engine.world, visual, s.x, s.y, s.z)
}

spawn_static :: proc(
  engine: ^Engine,
  phys: ^physics.World,
  position: [3]f32,
  collider: physics.Collider,
  mesh: render.MeshHandle = {},
  material: render.MaterialHandle = {},
  visual_scale: Maybe([3]f32) = nil,
  cast_shadow: bool = true,
) -> (
  node: world.NodeHandle,
  body: physics.StaticRigidBodyHandle,
) {
  node = world.spawn(&engine.world, position)
  body = physics.create_static_body(phys, position, collider = collider, user = world.Handle(node))
  attach_visual_mesh(engine, node, collider, mesh, material, visual_scale, cast_shadow)
  return
}

spawn_dynamic :: proc(
  engine: ^Engine,
  phys: ^physics.World,
  position: [3]f32,
  mass: f32,
  collider: physics.Collider,
  mesh: render.MeshHandle = {},
  material: render.MaterialHandle = {},
  visual_scale: Maybe([3]f32) = nil,
  cast_shadow: bool = true,
) -> (
  node: world.NodeHandle,
  body: physics.DynamicRigidBodyHandle,
) {
  node = world.spawn(&engine.world, position)
  body = physics.create_dynamic_body(
    phys,
    position,
    mass = mass,
    collider = collider,
    user = world.Handle(node),
  )
  attach_visual_mesh(engine, node, collider, mesh, material, visual_scale, cast_shadow)
  return
}

spawn_trigger :: proc(
  engine: ^Engine,
  phys: ^physics.World,
  position: [3]f32,
  collider: physics.Collider,
  mesh: render.MeshHandle = {},
  material: render.MaterialHandle = {},
  visual_scale: Maybe([3]f32) = nil,
  cast_shadow: bool = true,
) -> (
  node: world.NodeHandle,
  body: physics.TriggerHandle,
  ok: bool,
) {
  node = world.spawn(&engine.world, position) or_return
  body = physics.create_trigger(
    phys,
    position = position,
    collider = collider,
    user = world.Handle(node),
  ) or_return
  attach_visual_mesh(engine, node, collider, mesh, material, visual_scale, cast_shadow)
  ok = true
  return
}
