package main

import "../../mjolnir"
import "../../mjolnir/render/post_process"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import mu "vendor:microui"

bloom_on: bool = true
tonemap_on: bool = true
fog_on: bool
outline_on: bool
dof_on: bool
grayscale_on: bool
blur_on: bool
crosshatch_on: bool

bloom_threshold: mu.Real = 1.0
bloom_intensity: mu.Real = 1.0
tonemap_exposure: mu.Real = 1.0
tonemap_gamma: mu.Real = 1.0
fog_density: mu.Real = 0.02
fog_start: mu.Real = 5.0
fog_end: mu.Real = 40.0
outline_thickness: mu.Real = 1.5
dof_focus: mu.Real = 8.0
dof_range: mu.Real = 3.0
dof_blur: mu.Real = 20.0
blur_radius: mu.Real = 3.0
grayscale_strength: mu.Real = 1.0

main :: proc() {
  mjolnir.run_app({
    title      = "Post-process Stack Panel",
    width      = 1000,
    height     = 700,
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  render.main_camera_look_at(&engine.render, {6, 5, 10}, {0, 1.0, 0})
  mjolnir.spawn_ground(engine, 30.0)

  cube_mesh   := render.get_builtin_mesh(&engine.render, .CUBE)
  sphere_mesh := render.get_builtin_mesh(&engine.render, .SPHERE)

  magenta_emit := render.material_pbr(&engine.render, {1.0, 0.1, 0.8, 1}, emissive = 4.0)
  mjolnir.spawn_mesh(engine, sphere_mesh, magenta_emit, {-3.0, 1.2, 1.5})
  cyan_emit := render.material_pbr(&engine.render, {0.1, 0.9, 1.0, 1}, emissive = 4.0)
  mjolnir.spawn_mesh(engine, sphere_mesh, cyan_emit, {0.0, 1.2, 1.5})
  yellow_emit := render.material_pbr(&engine.render, {1.0, 0.9, 0.2, 1}, emissive = 4.0)
  mjolnir.spawn_mesh(engine, sphere_mesh, yellow_emit, {3.0, 1.2, 1.5})

  metal := render.material_pbr(&engine.render, {0.9, 0.9, 0.95, 1}, metallic = 1.0, roughness = 0.15)
  mjolnir.spawn_mesh(engine, sphere_mesh, metal, {0.5, 1.0, -1.5})
  rough := render.material_pbr(&engine.render, {0.2, 0.6, 0.8, 1}, metallic = 0.0, roughness = 0.8)
  mjolnir.spawn_mesh(engine, cube_mesh, rough, {3.0, 1.0, -1.5})
  orange := render.material_pbr(&engine.render, {1.0, 0.4, 0.1, 1}, emissive = 4.0)
  mjolnir.spawn_mesh(engine, cube_mesh, orange, {-3.0, 1.0, -1.5})
  glass := render.material_transparent(&engine.render, {0.2, 0.9, 0.4, 0.4})
  mjolnir.spawn_mesh(engine, sphere_mesh, glass, {1.5, 1.5, -3.5}, cast_shadow = false)

  white_mat := render.get_builtin_material(&engine.render, .WHITE)
  for i in 0 ..< 5 do mjolnir.spawn_mesh(engine, cube_mesh, white_mat, {f32(i) * 4.0 - 8.0, 0.5, -7.0})

  mjolnir.spawn(engine, {-3, 8, 6}, render.directional_light_attachment(color = {1.0, 0.95, 0.9, 1}, radius = 5.0, cast_shadow = true))
  mjolnir.spawn(engine, {0, 3, 0}, render.point_light_attachment(color = {1.0, 0.5, 0.2, 1}, radius = 8.0, cast_shadow = false))
  log.info("Post-process stack panel — toggle effects via debug UI")
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  post_process.clear_effects(&engine.render.post_process)
  if outline_on    do post_process.add_outline(&engine.render.post_process, f32(outline_thickness))
  if fog_on        do post_process.add_fog(&engine.render.post_process, {0.55, 0.6, 0.7}, f32(fog_density), f32(fog_start), f32(fog_end))
  if dof_on        do post_process.add_dof(&engine.render.post_process, f32(dof_focus), f32(dof_range), f32(dof_blur), 0.5)
  if bloom_on      do post_process.add_bloom(&engine.render.post_process, f32(bloom_threshold), f32(bloom_intensity), 32.0)
  if blur_on       do post_process.add_blur(&engine.render.post_process, f32(blur_radius))
  if crosshatch_on do post_process.add_crosshatch(&engine.render.post_process, {f32(engine.render.swapchain.extent.width), f32(engine.render.swapchain.extent.height)})
  if grayscale_on  do post_process.add_grayscale(&engine.render.post_process, f32(grayscale_strength))
  if tonemap_on    do post_process.add_tonemap(&engine.render.post_process, f32(tonemap_exposure), f32(tonemap_gamma))
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := render.debug_ui(&engine.render)
  if mu.window(ctx, "Post-process", {700, 20, 280, 380}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Tonemap", &tonemap_on)
    if tonemap_on {
      mu.label(ctx, "Exposure"); mu.slider(ctx, &tonemap_exposure, 0.1, 4.0)
      mu.label(ctx, "Gamma");       mu.slider(ctx, &tonemap_gamma, 1.0, 3.0)
    }
    mu.checkbox(ctx, "Grayscale", &grayscale_on)
    if grayscale_on do mu.slider(ctx, &grayscale_strength, 0.0, 1.0)
    mu.checkbox(ctx, "Bloom", &bloom_on)
    if bloom_on {
      mu.label(ctx, "Threshold"); mu.slider(ctx, &bloom_threshold, 0.0, 3.0)
      mu.label(ctx, "Intensity"); mu.slider(ctx, &bloom_intensity, 0.0, 20.0)
    }
    mu.checkbox(ctx, "Fog", &fog_on)
    if fog_on {
      mu.label(ctx, "Density"); mu.slider(ctx, &fog_density, 0.0, 0.2)
      mu.label(ctx, "Start");     mu.slider(ctx, &fog_start, 0.0, 50.0)
      mu.label(ctx, "End");         mu.slider(ctx, &fog_end, 1.0, 200.0)
    }
    mu.checkbox(ctx, "Outline", &outline_on)
    if outline_on do mu.slider(ctx, &outline_thickness, 0.5, 5.0)
    mu.checkbox(ctx, "Depth of Field", &dof_on)
    if dof_on {
      mu.label(ctx, "Focus"); mu.slider(ctx, &dof_focus, 1.0, 30.0)
      mu.label(ctx, "Range"); mu.slider(ctx, &dof_range, 0.5, 20.0)
      mu.label(ctx, "Blur");   mu.slider(ctx, &dof_blur, 1.0, 50.0)
    }
    mu.checkbox(ctx, "Gaussian Blur", &blur_on)
    if blur_on do mu.slider(ctx, &blur_radius, 0.5, 10.0)
    mu.checkbox(ctx, "Crosshatch", &crosshatch_on)
    mu.label(ctx, fmt.tprintf("Stack size: %d", len(engine.render.post_process.effect_stack)))
  }
}
