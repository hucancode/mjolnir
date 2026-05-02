package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  mjolnir.run(engine, 1000, 700, "Material PBR Knobs")
}

GRID :: 5
SPACING :: 2.5

setup :: proc(engine: ^mjolnir.Engine) {
  half := f32(GRID - 1) * 0.5 * SPACING
  world.main_camera_look_at(
    &engine.world,
    {half + 2, half + 4, half * 2.4},
    {0, half - 1, 0},
  )

  sphere_mesh := world.get_builtin_mesh(&engine.world, .SPHERE)
  plane_mesh := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
  ground_albedo := mjolnir.create_texture(
    engine,
    #load("statue-1275469_1280.jpg"),
    generate_mips = true,
  )
  plane_material := world.create_material(
    &engine.world,
    {.ALBEDO_TEXTURE},
    .PBR,
    albedo_handle = ground_albedo,
    roughness_value = 0.7,
    metallic_value = 0.0,
  ) or_else {}

  plane := world.spawn(
    &engine.world,
    {0, -1, 0},
    world.MeshAttachment{handle = plane_mesh, material = plane_material, cast_shadow = false},
  ) or_else {}
  world.scale(&engine.world, plane, f32(GRID) * SPACING * 1.5)

  // Row 0: roughness sweep, metallic = 0
  // Row 1: roughness sweep, metallic = 1
  // Row 2: emissive sweep on red albedo
  // Row 3: base_color hue sweep, fixed roughness
  // Row 4: combined: roughness + metallic diagonal
  for row in 0 ..< GRID {
    for col in 0 ..< GRID {
      t := f32(col) / f32(GRID - 1)
      mat: world.MaterialHandle
      switch row {
      case 0:
        mat = world.create_material(
          &engine.world,
          type = .PBR,
          base_color_factor = {0.85, 0.1, 0.1, 1},
          roughness_value = t,
          metallic_value = 0,
        ) or_else {}
      case 1:
        mat = world.create_material(
          &engine.world,
          type = .PBR,
          base_color_factor = {0.95, 0.9, 0.6, 1},
          roughness_value = t,
          metallic_value = 1,
        ) or_else {}
      case 2:
        mat = world.create_material(
          &engine.world,
          type = .PBR,
          base_color_factor = {0.9, 0.2, 0.2, 1},
          roughness_value = 0.5,
          metallic_value = 0,
          emissive_value = t * 5.0,
        ) or_else {}
      case 3:
        hue := t * 360.0
        rgb := hsv_to_rgb(hue, 0.85, 0.9)
        mat = world.create_material(
          &engine.world,
          type = .PBR,
          base_color_factor = {rgb.r, rgb.g, rgb.b, 1},
          roughness_value = 0.4,
          metallic_value = 0,
        ) or_else {}
      case 4:
        mat = world.create_material(
          &engine.world,
          type = .PBR,
          base_color_factor = {0.7, 0.7, 0.75, 1},
          roughness_value = t,
          metallic_value = t,
        ) or_else {}
      }
      x := f32(col) * SPACING - half
      y := f32(row) * SPACING
      world.spawn(
        &engine.world,
        {x, y, 0},
        world.MeshAttachment{handle = sphere_mesh, material = mat, cast_shadow = true},
      )
    }
  }

  // Sun
  q1 := linalg.quaternion_angle_axis(-math.PI * 0.35, linalg.VECTOR3F32_Y_AXIS)
  q2 := linalg.quaternion_angle_axis(-math.PI * 0.45, linalg.VECTOR3F32_X_AXIS)
  light := world.spawn(
    &engine.world,
    {0, 10, 0},
    world.create_directional_light_attachment({1, 0.97, 0.92, 5}, 12.0),
  ) or_else {}
  if n, ok := world.node(&engine.world, light); ok {
    n.transform.rotation = q2 * q1
    n.transform.is_dirty = true
  }
}

hsv_to_rgb :: proc(h, s, v: f32) -> (rgb: [3]f32) {
  c := v * s
  hh := math.mod(h, 360) / 60.0
  x := c * (1 - abs(math.mod(hh, 2) - 1))
  m := v - c
  switch int(hh) {
  case 0: rgb = {c, x, 0}
  case 1: rgb = {x, c, 0}
  case 2: rgb = {0, c, x}
  case 3: rgb = {0, x, c}
  case 4: rgb = {x, 0, c}
  case:   rgb = {c, 0, x}
  }
  rgb += {m, m, m}
  return
}
