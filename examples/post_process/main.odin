package main

import "../../mjolnir"
import pp "../../mjolnir/render/post_process"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import mu "vendor:microui"

bloom_on: bool
tonemap_on: bool = true
fog_on: bool
outline_on: bool
dof_on: bool
grayscale_on: bool
blur_on: bool
crosshatch_on: bool

bloom_threshold: mu.Real = 0.6
bloom_intensity: mu.Real = 1.0
tonemap_exposure: mu.Real = 1.0
tonemap_gamma: mu.Real = 2.2
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
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.pre_render_proc = debug_ui
  engine.update_proc = update
  mjolnir.run(engine, 1000, 700, "Post-process Stack Panel")
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.debug_ui_enabled = true
  world.main_camera_look_at(&engine.world, {6, 5, 10}, {0, 0.5, 0})

  ground := world.spawn_primitive_mesh(&engine.world, .QUAD_XZ, .GRAY)
  world.scale(&engine.world, ground, 30.0)

  cube_mesh   := world.get_builtin_mesh(&engine.world, .CUBE)
  sphere_mesh := world.get_builtin_mesh(&engine.world, .SPHERE)

  emissive_mat := world.material_pbr(&engine.world, {1.0, 0.4, 0.1, 1}, emissive=8.0)
  world.spawn_mesh(&engine.world, cube_mesh, emissive_mat, {-2.0, 1.0, 0.0})

  metal_mat := world.material_pbr(&engine.world, {0.9, 0.9, 0.95, 1}, metallic=1.0, roughness=0.15)
  world.spawn_mesh(&engine.world, sphere_mesh, metal_mat, {0.5, 1.0, 0.0})

  rough_mat := world.material_pbr(&engine.world, {0.2, 0.6, 0.8, 1}, metallic=0.0, roughness=0.8)
  world.spawn_mesh(&engine.world, cube_mesh, rough_mat, {3.0, 1.0, 0.0})

  glass_mat := world.material_transparent(&engine.world, {0.2, 0.9, 0.4, 0.4})
  world.spawn_mesh(&engine.world, sphere_mesh, glass_mat, {1.5, 1.5, -2.5}, cast_shadow=false)

  white_mat := world.get_builtin_material(&engine.world, .WHITE)
  for i in 0 ..< 5 {
    x := f32(i) * 4.0 - 8.0
    world.spawn_mesh(&engine.world, cube_mesh, white_mat, {x, 0.5, -6.0})
  }

  world.spawn_light_directional(
    &engine.world,
    position    = {-3, 8, 6},
    color       = {1.0, 0.95, 0.9, 1},
    radius      = 5.0,
    cast_shadow = true,
  )
  world.spawn_light_point(
    &engine.world,
    position    = {0, 3, 0},
    color       = {1.0, 0.5, 0.2, 1},
    radius      = 8.0,
    cast_shadow = false,
  )

  log.info("Post-process stack panel — toggle effects via debug UI")
}

t_elapsed: f32

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  t_elapsed += delta_time
  pp_r := &engine.render.post_process
  pp.clear_effects(pp_r)

  if outline_on do pp.add_outline(pp_r, f32(outline_thickness), {0.0, 0.0, 0.0})
  if fog_on do pp.add_fog(pp_r, {0.55, 0.6, 0.7}, f32(fog_density), f32(fog_start), f32(fog_end))
  if dof_on do pp.add_dof(pp_r, f32(dof_focus), f32(dof_range), f32(dof_blur), 0.5)
  if bloom_on do pp.add_bloom(pp_r, f32(bloom_threshold), f32(bloom_intensity), 4.0)
  if blur_on do pp.add_blur(pp_r, f32(blur_radius), true)
  if crosshatch_on {
    ext := engine.swapchain.extent
    pp.add_crosshatch(pp_r, {f32(ext.width), f32(ext.height)})
  }
  if grayscale_on do pp.add_grayscale(pp_r, f32(grayscale_strength))
  if tonemap_on do pp.add_tonemap(pp_r, f32(tonemap_exposure), f32(tonemap_gamma))

}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := &engine.render.debug_ui.ctx
  if mu.window(ctx, "Post-process", {700, 20, 280, 380}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Tonemap", &tonemap_on)
    if tonemap_on {
      mu.label(ctx, fmt.tprintf("exposure %.2f", tonemap_exposure))
      mu.slider(ctx, &tonemap_exposure, 0.1, 4.0)
      mu.label(ctx, fmt.tprintf("gamma %.2f", tonemap_gamma))
      mu.slider(ctx, &tonemap_gamma, 1.0, 3.0)
    }
    mu.checkbox(ctx, "Grayscale", &grayscale_on)
    if grayscale_on {
      mu.slider(ctx, &grayscale_strength, 0.0, 1.0)
    }
    mu.checkbox(ctx, "Bloom", &bloom_on)
    if bloom_on {
      mu.label(ctx, fmt.tprintf("threshold %.2f", bloom_threshold))
      mu.slider(ctx, &bloom_threshold, 0.0, 3.0)
      mu.label(ctx, fmt.tprintf("intensity %.2f", bloom_intensity))
      mu.slider(ctx, &bloom_intensity, 0.0, 3.0)
    }
    mu.checkbox(ctx, "Fog", &fog_on)
    if fog_on {
      mu.label(ctx, fmt.tprintf("density %.3f", fog_density))
      mu.slider(ctx, &fog_density, 0.0, 0.2)
      mu.label(ctx, fmt.tprintf("start %.1f", fog_start))
      mu.slider(ctx, &fog_start, 0.0, 50.0)
      mu.label(ctx, fmt.tprintf("end %.1f", fog_end))
      mu.slider(ctx, &fog_end, 1.0, 200.0)
    }
    mu.checkbox(ctx, "Outline", &outline_on)
    if outline_on {
      mu.slider(ctx, &outline_thickness, 0.5, 5.0)
    }
    mu.checkbox(ctx, "Depth of Field", &dof_on)
    if dof_on {
      mu.label(ctx, fmt.tprintf("focus %.1f", dof_focus))
      mu.slider(ctx, &dof_focus, 1.0, 30.0)
      mu.label(ctx, fmt.tprintf("range %.1f", dof_range))
      mu.slider(ctx, &dof_range, 0.5, 20.0)
      mu.label(ctx, fmt.tprintf("blur %.1f", dof_blur))
      mu.slider(ctx, &dof_blur, 1.0, 50.0)
    }
    mu.checkbox(ctx, "Gaussian Blur", &blur_on)
    if blur_on {
      mu.slider(ctx, &blur_radius, 0.5, 10.0)
    }
    mu.checkbox(ctx, "Crosshatch", &crosshatch_on)
    mu.label(ctx, fmt.tprintf("Stack size: %d", len(engine.render.post_process.effect_stack)))
  }
}
