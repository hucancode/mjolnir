package world

import cont "../containers"
import "../geometry"
import "core:log"

// Spawn a builtin primitive mesh with optional transform
spawn_primitive_mesh :: proc(
  world: ^World,
  primitive: Primitive = .CUBE,
  color: Color = .WHITE,
  position: [3]f32 = {0, 0, 0},
  rotation_angle: f32 = 0,
  rotation_axis: [3]f32 = {0, 1, 0},
  scale_factor: f32 = 1.0,
  cast_shadow := true,
) -> (
  ret: NodeHandle,
  ok: bool,
) #optional_ok {
  mesh := get_builtin_mesh(world, primitive)
  mat := get_builtin_material(world, color)
  handle := spawn(
    world,
    position,
    MeshAttachment{handle = mesh, material = mat, cast_shadow = cast_shadow},
  ) or_return
  if rotation_angle != 0 {
    rotate(world, handle, rotation_angle, rotation_axis)
  }
  if scale_factor != 1.0 {
    scale(world, handle, scale_factor)
  }
  return handle, true
}

get_builtin_material :: proc(world: ^World, color: Color) -> MaterialHandle {
  return world.builtin_materials[color]
}

get_builtin_mesh :: proc(world: ^World, primitive: Primitive) -> MeshHandle {
  return world.builtin_meshes[primitive]
}

init_builtin_materials :: proc(world: ^World) {
  log.info("Creating builtin materials...")
  colors := [len(Color)][4]f32 {
    {1.0, 1.0, 1.0, 1.0}, // WHITE
    {0.0, 0.0, 0.0, 1.0}, // BLACK
    {0.3, 0.3, 0.3, 1.0}, // GRAY
    {1.0, 0.0, 0.0, 1.0}, // RED
    {0.0, 1.0, 0.0, 1.0}, // GREEN
    {0.0, 0.0, 1.0, 1.0}, // BLUE
    {1.0, 1.0, 0.0, 1.0}, // YELLOW
    {0.0, 1.0, 1.0, 1.0}, // CYAN
    {1.0, 0.0, 1.0, 1.0}, // MAGENTA
  }
  for color, i in colors {
    world.builtin_materials[i] =
    create_material(world, type = .PBR, base_color_factor = color) or_continue
    stage_material_data(&world.staging, world.builtin_materials[i])
  }
  log.info("Builtin materials created successfully")
}

init_builtin_meshes :: proc(world: ^World) {
  log.info("Creating builtin meshes...")
  world.builtin_meshes[Primitive.CUBE], _, _ = create_mesh(
    world,
    geometry.make_cube(),
    true,
  )
  world.builtin_meshes[Primitive.SPHERE], _, _ = create_mesh(
    world,
    geometry.make_sphere(),
    true,
  )
  world.builtin_meshes[Primitive.QUAD_XZ], _, _ = create_mesh(
    world,
    geometry.make_quad(),
    true,
  )
  world.builtin_meshes[Primitive.QUAD_XY], _, _ = create_mesh(
    world,
    geometry.make_billboard_quad(),
    true,
  )
  world.builtin_meshes[Primitive.CONE], _, _ = create_mesh(
    world,
    geometry.make_cone(),
    true,
  )
  world.builtin_meshes[Primitive.CAPSULE], _, _ = create_mesh(
    world,
    geometry.make_capsule(),
    true,
  )
  world.builtin_meshes[Primitive.CYLINDER], _, _ = create_mesh(
    world,
    geometry.make_cylinder(),
    true,
  )
  world.builtin_meshes[Primitive.TORUS], _, _ = create_mesh(
    world,
    geometry.make_torus(),
    true,
  )
  log.info("Builtin meshes created successfully")
}
