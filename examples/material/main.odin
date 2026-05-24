package main

import "../../mjolnir"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

GRID :: 6
SPACING :: 2.5

ibl_intensity: mu.Real = 1.0
sun_intensity: mu.Real = 5.0
skybox_on: bool = true
metallic_min: mu.Real = 0.0
metallic_max: mu.Real = 1.0
roughness_min: mu.Real = 0.0
roughness_max: mu.Real = 1.0
sun_light: mjolnir.NodeHandle
grid_materials: [GRID][GRID]mjolnir.MaterialHandle

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

  base_color: [4]f32 = {0.85, 0.85, 0.9, 1}
  for row in 0 ..< GRID do for col in 0 ..< GRID {
    m, r := axis_values(row, col)
    mat := mjolnir.create_material(
      engine, type = .PBR, base_color_factor = base_color,
      metallic_value = m, roughness_value = r,
    )
    grid_materials[row][col] = mat
    x := f32(col) * SPACING - half
    y := f32(row) * SPACING
    mjolnir.spawn(engine, {x, y, 0}, mjolnir.MeshAttachment{handle = sphere_mesh, material = mat, cast_shadow = true})
  }

  q1 := linalg.quaternion_angle_axis(-math.PI * 0.35, linalg.VECTOR3F32_Y_AXIS)
  q2 := linalg.quaternion_angle_axis(-math.PI * 0.45, linalg.VECTOR3F32_X_AXIS)
  sun_light = mjolnir.spawn_light_directional(engine, {0, 10, 0}, {1, 0.97, 0.92, f32(sun_intensity)}, 12.0)
  mjolnir.rotate(engine, sun_light, q2 * q1)
}

axis_values :: proc(row, col: int) -> (metallic, roughness: f32) {
  t_row := f32(row) / f32(GRID - 1)
  t_col := f32(col) / f32(GRID - 1)
  m_lo, m_hi := f32(metallic_min), f32(metallic_max)
  r_lo, r_hi := f32(roughness_min), f32(roughness_max)
  metallic = math.lerp(m_lo, m_hi, t_row)
  roughness = math.lerp(r_lo, r_hi, t_col)
  return
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  mjolnir.set_light_intensity(engine, sun_light, f32(sun_intensity))
  mjolnir.set_ibl_intensity(engine, f32(ibl_intensity))
  mjolnir.set_skybox_enabled(engine, skybox_on)
  for row in 0 ..< GRID do for col in 0 ..< GRID {
    h := grid_materials[row][col]
    mat, ok := mjolnir.material(engine, h)
    if !ok do continue
    m, r := axis_values(row, col)
    if mat.metallic_value == m && mat.roughness_value == r do continue
    mat.metallic_value = m
    mat.roughness_value = r
    mjolnir.stage_material_data(engine, h)
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Environment", {700, 20, 280, 180}, {.NO_CLOSE}) {
    mu.label(ctx, fmt.tprintf("Sun intensity: %.2f", sun_intensity))
    mu.slider(ctx, &sun_intensity, 0.0, 5.0)
    mu.label(ctx, fmt.tprintf("IBL intensity: %.2f", ibl_intensity))
    mu.slider(ctx, &ibl_intensity, 0.0, 2.0)
    mu.checkbox(ctx, "Skybox", &skybox_on)
  }
  if mu.window(ctx, "PBR Range", {700, 210, 280, 220}, {.NO_CLOSE}) {
    mu.label(ctx, fmt.tprintf("Metallic min: %.2f (rows bottom)", metallic_min))
    mu.slider(ctx, &metallic_min, 0.0, 1.0)
    mu.label(ctx, fmt.tprintf("Metallic max: %.2f (rows top)", metallic_max))
    mu.slider(ctx, &metallic_max, 0.0, 1.0)
    mu.label(ctx, fmt.tprintf("Roughness min: %.2f (cols left)", roughness_min))
    mu.slider(ctx, &roughness_min, 0.0, 1.0)
    mu.label(ctx, fmt.tprintf("Roughness max: %.2f (cols right)", roughness_max))
    mu.slider(ctx, &roughness_max, 0.0, 1.0)
  }
}
