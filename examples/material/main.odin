package main

import "../../mjolnir"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

GRID :: 5
SPACING :: 2.5

ibl_intensity: mu.Real = 1.0
sun_intensity: mu.Real = 5.0
skybox_on: bool = true
sun_light: mjolnir.NodeHandle

main :: proc() {
  mjolnir.run_app({
    title      = "Material PBR Knobs",
    width      = 1000,
    height     = 700,
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  half := f32(GRID - 1) * 0.5 * SPACING
  mjolnir.main_camera_look_at(engine, {half + 2, half + 4, half * 2.4}, {0, half - 1, 0})

  sphere_mesh := mjolnir.builtin_mesh(engine, .SPHERE)
  plane_mesh := mjolnir.builtin_mesh(engine, .QUAD_XZ)
  ground_albedo := mjolnir.create_texture(engine, #load("statue-1275469_1280.jpg"), generate_mips = true)
  plane_material := mjolnir.create_material(
    engine, {.ALBEDO_TEXTURE}, .PBR,
    albedo_handle = ground_albedo, roughness_value = 0.7, metallic_value = 0.0,
  )

  plane := mjolnir.spawn(engine, {0, -1, 0}, mjolnir.MeshAttachment{handle = plane_mesh, material = plane_material, cast_shadow = false})
  mjolnir.scale(engine, plane, f32(GRID) * SPACING * 1.5)

  for row in 0 ..< GRID do for col in 0 ..< GRID {
    t := f32(col) / f32(GRID - 1)
    mat: mjolnir.MaterialHandle
    switch row {
    case 0: mat = mjolnir.create_material(engine, type = .PBR, base_color_factor = {0.85, 0.1, 0.1, 1}, roughness_value = t, metallic_value = 0)
    case 1: mat = mjolnir.create_material(engine, type = .PBR, base_color_factor = {0.95, 0.9, 0.6, 1}, roughness_value = t, metallic_value = 1)
    case 2: mat = mjolnir.create_material(engine, type = .PBR, base_color_factor = {0.9, 0.2, 0.2, 1}, roughness_value = 0.5, metallic_value = 0, emissive_value = t * 5.0)
    case 3:
      rgb := hsv_to_rgb(t * 360.0, 0.85, 0.9)
      mat = mjolnir.create_material(engine, type = .PBR, base_color_factor = {rgb.r, rgb.g, rgb.b, 1}, roughness_value = 0.4, metallic_value = 0)
    case 4: mat = mjolnir.create_material(engine, type = .PBR, base_color_factor = {0.7, 0.7, 0.75, 1}, roughness_value = t, metallic_value = t)
    }
    x := f32(col) * SPACING - half
    y := f32(row) * SPACING
    mjolnir.spawn(engine, {x, y, 0}, mjolnir.MeshAttachment{handle = sphere_mesh, material = mat, cast_shadow = true})
  }

  q1 := linalg.quaternion_angle_axis(-math.PI * 0.35, linalg.VECTOR3F32_Y_AXIS)
  q2 := linalg.quaternion_angle_axis(-math.PI * 0.45, linalg.VECTOR3F32_X_AXIS)
  sun_light = mjolnir.spawn_light_directional(engine, {0, 10, 0}, {1, 0.97, 0.92, f32(sun_intensity)}, 12.0)
  mjolnir.rotate(engine, sun_light, q2 * q1)
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  mjolnir.set_light_intensity(engine, sun_light, f32(sun_intensity))
  mjolnir.set_ibl_intensity(engine, f32(ibl_intensity))
  mjolnir.set_skybox_enabled(engine, skybox_on)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Environment", {700, 20, 280, 220}, {.NO_CLOSE}) {
    mu.label(ctx, fmt.tprintf("Sun intensity: %.2f", sun_intensity))
    mu.slider(ctx, &sun_intensity, 0.0, 5.0)
    mu.label(ctx, fmt.tprintf("IBL intensity: %.2f", ibl_intensity))
    mu.slider(ctx, &ibl_intensity, 0.0, 2.0)
    mu.checkbox(ctx, "Skybox", &skybox_on)
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
