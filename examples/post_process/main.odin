// Bloom, DoF, fog, tonemap, outline, crosshatch, and a user shader: vignette.
package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import mu "vendor:microui"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
  vignette:         render.PostShader,
}

// The params of vignette.frag / vignette.wgsl, as their push block lays them out.
VignetteParams :: struct {
  color:    [3]f32,
  radius:   f32,
  softness: f32,
  strength: f32,
}

bloom_on: bool = true
tonemap_on: bool = true
fog_on: bool
outline_on: bool
dof_on: bool
grayscale_on: bool
blur_on: bool
crosshatch_on: bool
vignette_on: bool

bloom_threshold: mu.Real = 1.0
bloom_intensity: mu.Real = 1.0
tonemap_exposure: mu.Real = 1.0
tonemap_gamma: mu.Real = 1.0
fog_start: mu.Real = 5.0
fog_end: mu.Real = 40.0
outline_thickness: mu.Real = 1.5
dof_focus: mu.Real = 8.0
dof_range: mu.Real = 3.0
dof_blur: mu.Real = 20.0
blur_radius: mu.Real = 3.0
grayscale_strength: mu.Real = 1.0
vignette_radius: mu.Real = 0.75
vignette_softness: mu.Real = 0.45
vignette_strength: mu.Real = 0.8

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1000, 700, "Post-process Stack Panel") do return
  if !render.init(&app.renderer, "Post-process Stack Panel", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  if !world.init(&app.scene) do return
  mjolnir.run(
    mjolnir.Loop(App) {
      app = app,
      setup = setup,
      shutdown = shutdown,
      should_close = should_close,
      update = update,
      frame = frame,
    },
  )
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  render.load_environment_map(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.main_camera_look_at(&app.renderer, {6, 5, 10}, {0, 1.0, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  // each backend embeds only its own source
  when render.RENDER_BACKEND == "vulkan" {
    vignette_spirv, vignette_wgsl := #load("vignette.frag.spv"), ""
  } else {
    vignette_spirv, vignette_wgsl := ([]u8)(nil), #load("vignette.wgsl", string)
  }
  ok: bool
  app.vignette, ok = render.post_shader_create(&app.renderer, vignette_spirv, vignette_wgsl)
  if !ok do log.error("Failed to create the vignette shader")
  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, ground.index, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 30.0)

  cube_mesh   := app.renderer.builtin_meshes[.CUBE]
  sphere_mesh := app.renderer.builtin_meshes[.SPHERE]

  magenta_emit := render.material_pbr(&app.renderer, {1.0, 0.1, 0.8, 1}, emissive = 4.0)
  spawn_mesh(app, sphere_mesh, magenta_emit, {-3.0, 1.2, 1.5})
  cyan_emit := render.material_pbr(&app.renderer, {0.1, 0.9, 1.0, 1}, emissive = 4.0)
  spawn_mesh(app, sphere_mesh, cyan_emit, {0.0, 1.2, 1.5})
  yellow_emit := render.material_pbr(&app.renderer, {1.0, 0.9, 0.2, 1}, emissive = 4.0)
  spawn_mesh(app, sphere_mesh, yellow_emit, {3.0, 1.2, 1.5})

  metal := render.material_pbr(&app.renderer, {0.9, 0.9, 0.95, 1}, metallic = 1.0, roughness = 0.15)
  spawn_mesh(app, sphere_mesh, metal, {0.5, 1.0, -1.5})
  rough := render.material_pbr(&app.renderer, {0.2, 0.6, 0.8, 1}, metallic = 0.0, roughness = 0.8)
  spawn_mesh(app, cube_mesh, rough, {3.0, 1.0, -1.5})
  orange := render.material_pbr(&app.renderer, {1.0, 0.4, 0.1, 1}, emissive = 4.0)
  spawn_mesh(app, cube_mesh, orange, {-3.0, 1.0, -1.5})
  glass := render.material_transparent(&app.renderer, {0.2, 0.9, 0.4, 0.4})
  spawn_mesh(app, sphere_mesh, glass, {1.5, 1.5, -3.5}, cast_shadow = false)

  white_mat := app.renderer.builtin_materials[.WHITE]
  for i in 0 ..< 5 do spawn_mesh(app, cube_mesh, white_mat, {f32(i) * 4.0 - 8.0, 0.5, -7.0})

  sun := world.spawn(&app.scene, {-3, 8, 6})
  render.attach(&app.renderer, sun.index, render.directional_light_attachment(color = {1.0, 0.95, 0.9, 1}, shadow_radius = 5.0, cast_shadow = true))
  lamp := world.spawn(&app.scene, {0, 3, 0})
  render.attach(&app.renderer, lamp.index, render.point_light_attachment(color = {1.0, 0.5, 0.2, 1}, radius = 8.0, cast_shadow = false))
  log.info("Post-process stack panel — toggle effects via debug UI")
  return true
}

spawn_mesh :: proc(app: ^App, mesh: render.MeshHandle, material: render.MaterialHandle, position: [3]f32, cast_shadow := true) {
  n := world.spawn(&app.scene, position)
  render.attach(&app.renderer, n.index, render.MeshAttachment{handle = mesh, material = material, cast_shadow = cast_shadow})
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  input.feed_microui(&app.input, render.debug_ctx(&app.renderer))
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.main_camera_orbit(&app.renderer, app.yaw, app.pitch, app.dist)
  clear(&app.renderer.effect_stack)
  if outline_on    do append(&app.renderer.effect_stack, render.OutlineEffect{thickness = f32(outline_thickness)})
  if fog_on        do append(&app.renderer.effect_stack, render.FogEffect{color = {0.55, 0.6, 0.7}, start = f32(fog_start), end = f32(fog_end)})
  if dof_on        do append(&app.renderer.effect_stack, render.DoFEffect{focus_distance = f32(dof_focus), focus_range = f32(dof_range), blur_strength = f32(dof_blur), bokeh_intensity = 0.5})
  if bloom_on      do append(&app.renderer.effect_stack, render.BloomEffect{threshold = f32(bloom_threshold), intensity = f32(bloom_intensity), blur_radius = 32.0})
  if blur_on       do append(&app.renderer.effect_stack, render.BlurEffect{radius = f32(blur_radius), weight_falloff = 1.0})
  if crosshatch_on do append(&app.renderer.effect_stack, render.CrossHatchEffect{hatch_offset_y = 5.0, lum_thresholds = {0.6, 0.3, 0.15, 0.07}})
  if grayscale_on  do append(&app.renderer.effect_stack, render.GrayscaleEffect{strength = f32(grayscale_strength)})
  if tonemap_on    do append(&app.renderer.effect_stack, render.ToneMapEffect{exposure = f32(tonemap_exposure), gamma = f32(tonemap_gamma)})
  if vignette_on && app.vignette != 0 {
    params := VignetteParams{color = {0.02, 0.0, 0.05}, radius = f32(vignette_radius), softness = f32(vignette_softness), strength = f32(vignette_strength)}
    append(&app.renderer.effect_stack, render.custom_effect(app.vignette, params))
  }
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  debug_ui(app)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "Post-process", {700, 20, 280, 560}, {.NO_CLOSE}) {
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
    mu.checkbox(ctx, "Vignette (user shader)", &vignette_on)
    if vignette_on {
      mu.label(ctx, "Radius");   mu.slider(ctx, &vignette_radius, 0.2, 1.0)
      mu.label(ctx, "Softness"); mu.slider(ctx, &vignette_softness, 0.05, 0.8)
      mu.label(ctx, "Strength"); mu.slider(ctx, &vignette_strength, 0.0, 1.0)
    }
  }
}
