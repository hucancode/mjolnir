package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/render/ambient"
import "../../mjolnir/world"
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
sun_light: world.NodeHandle
grid_materials: [GRID][GRID]render.MaterialHandle

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
  render.main_camera_look_at(&engine.render, {half + 2, half + 4, half * 2.4}, {0, half - 1, 0})

  sphere_mesh := render.get_builtin_mesh(&engine.render, .SPHERE)
  plane_mesh := render.get_builtin_mesh(&engine.render, .QUAD_XZ)
  ground_albedo, _ := render.create_texture_from_data(&engine.render, #load("statue-1275469_1280.jpg"), generate_mips = true)
  plane_material := render.create_material(&engine.render, {.ALBEDO_TEXTURE}, .PBR,
    albedo_handle = ground_albedo, roughness_value = 0.7, metallic_value = 0.0,
  )

  plane := mjolnir.spawn(engine, {0, -1, 0}, render.MeshAttachment{handle = plane_mesh, material = plane_material, cast_shadow = false})
  world.scale(&engine.world, plane, f32(GRID) * SPACING * 1.5)

  base_color: [4]f32 = {0.85, 0.85, 0.9, 1}
  for row in 0 ..< GRID do for col in 0 ..< GRID {
    m, r := axis_values(row, col)
    mat := render.create_material(&engine.render, type = .PBR, base_color_factor = base_color,
      metallic_value = m, roughness_value = r,
    )
    grid_materials[row][col] = mat
    x := f32(col) * SPACING - half
    y := f32(row) * SPACING
    mjolnir.spawn(engine, {x, y, 0}, render.MeshAttachment{handle = sphere_mesh, material = mat, cast_shadow = true})
  }

  q1 := linalg.quaternion_angle_axis(-math.PI * 0.35, linalg.VECTOR3F32_Y_AXIS)
  q2 := linalg.quaternion_angle_axis(-math.PI * 0.45, linalg.VECTOR3F32_X_AXIS)
  sun_light = mjolnir.spawn(engine, {0, 10, 0}, render.directional_light_attachment({1, 0.97, 0.92, f32(sun_intensity)}, 12.0))
  world.rotate(&engine.world, sun_light, q2 * q1)
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
  if l, ok := render.attachment(&engine.render, sun_light.index, render.DirectionalLightAttachment); ok {
    l.color[3] = f32(sun_intensity)
    render.mark_slot_dirty(&engine.render, sun_light.index)
  }
  ambient.set_ibl_intensity(&engine.render.ambient, f32(ibl_intensity))
  ambient.set_skybox_enabled(&engine.render.ambient, skybox_on)
  for row in 0 ..< GRID do for col in 0 ..< GRID {
    m, r := axis_values(row, col)
    render.set_material_pbr_params(&engine.render, grid_materials[row][col], metallic = m, roughness = r)
  }
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := render.debug_ui(&engine.render)
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
