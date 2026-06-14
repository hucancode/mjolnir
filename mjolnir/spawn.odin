package mjolnir

import "physics"
import "world"

@(private = "file")
_attach_visual_mesh :: proc(
  engine: ^Engine,
  parent: world.NodeHandle,
  collider: physics.Collider,
  mesh: world.MeshHandle,
  material: world.MaterialHandle,
  visual_scale: Maybe([3]f32),
  cast_shadow: bool,
) {
  if mesh.generation == 0 do return
  visual, _ := world.spawn_child(&engine.world, parent, attachment = world.MeshAttachment{handle = mesh, material = material, cast_shadow = cast_shadow})
  s := visual_scale.? or_else physics.collider_visual_scale(collider)
  world.scale_xyz(&engine.world, visual, s.x, s.y, s.z)
}

spawn_static :: proc(
  engine: ^Engine,
  position: [3]f32,
  collider: physics.Collider,
  mesh: world.MeshHandle = {},
  material: world.MaterialHandle = {},
  visual_scale: Maybe([3]f32) = nil,
  cast_shadow: bool = true,
) -> world.NodeHandle {
  parent, _ := world.spawn(&engine.world, position)
  n, _ := world.node(&engine.world, parent)
  physics.create_static_body(&engine.physics, n.transform.position, n.transform.rotation, collider)
  _attach_visual_mesh(engine, parent, collider, mesh, material, visual_scale, cast_shadow)
  return parent
}

spawn_dynamic :: proc(
  engine: ^Engine,
  position: [3]f32,
  mass: f32,
  collider: physics.Collider,
  mesh: world.MeshHandle = {},
  material: world.MaterialHandle = {},
  visual_scale: Maybe([3]f32) = nil,
  cast_shadow: bool = true,
) -> (parent: world.NodeHandle, body: physics.DynamicRigidBodyHandle) {
  parent, _ = world.spawn(&engine.world, position)
  n, _ := world.node(&engine.world, parent)
  body = physics.create_dynamic_body(&engine.physics, n.transform.position, n.transform.rotation, mass, collider)
  if b, ok := physics.get_dynamic_body(&engine.physics, body); ok {
    physics.set_inertia_from_collider(b, collider)
  }
  n.attachment = world.RigidBodyAttachment{body_handle = body}
  _attach_visual_mesh(engine, parent, collider, mesh, material, visual_scale, cast_shadow)
  return
}

spawn_trigger :: proc(
  engine: ^Engine,
  position: [3]f32,
  collider: physics.Collider,
  mesh: world.MeshHandle = {},
  material: world.MaterialHandle = {},
  visual_scale: Maybe([3]f32) = nil,
  cast_shadow: bool = true,
) -> (parent: world.NodeHandle, body: physics.TriggerHandle, ok: bool) {
  parent = world.spawn(&engine.world, position) or_return
  body = physics.create_trigger(&engine.physics, position = position, collider = collider) or_return
  _attach_visual_mesh(engine, parent, collider, mesh, material, visual_scale, cast_shadow)
  ok = true
  return
}
