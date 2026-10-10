package mjolnir

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
    engine.render.builtin_meshes[primitive],
    engine.render.builtin_materials[color],
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
