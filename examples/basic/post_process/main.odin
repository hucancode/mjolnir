// Bloom, DoF, fog, tonemap, outline, crosshatch, and a user shader: vignette.
package main

import "core:log"
import "core:math/linalg"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  debug:    debugui.Context,
  orbit:    render.Orbit,
  vignette: render.ShaderHandle,
}

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

bloom_threshold: f32 = 1.0
bloom_intensity: f32 = 1.0
tonemap_exposure: f32 = 1.0
tonemap_gamma: f32 = 1.0
fog_start: f32 = 5.0
fog_end: f32 = 40.0
fog_height: f32 = 1.0
fog_height_falloff: f32 = 0.0
outline_thickness: f32 = 1.5
dof_focus: f32 = 8.0
dof_range: f32 = 3.0
dof_blur: f32 = 20.0
blur_radius: f32 = 3.0
grayscale_strength: f32 = 1.0
vignette_radius: f32 = 0.75
vignette_softness: f32 = 0.45
vignette_strength: f32 = 0.8

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Post-process Stack Panel") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
  mjolnir.run(
    mjolnir.Loop(App) {
      app = app,
      setup = setup,
      shutdown = shutdown,
      update = update,
      render = draw,
    },
  )
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.orbit = render.make_orbit({6, 5, 10}, {0, 1.0, 0})
  ok: bool
  app.vignette, ok = render.post_shader_create(&app.renderer, #load("vignette." + render.SHADER_EXT))
  if !ok do log.error("Failed to create the vignette shader")
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, no_shadow = true), scale = 30.0)

  magenta_emit := render.material_create(&app.renderer, render.make_material(base_color_factor = {1.0, 0.1, 0.8, 1}, emissive_factor = 4.0))
  spawn_primitive(app, .SPHERE, magenta_emit, {-3.0, 1.2, 1.5})
  cyan_emit := render.material_create(&app.renderer, render.make_material(base_color_factor = {0.1, 0.9, 1.0, 1}, emissive_factor = 4.0))
  spawn_primitive(app, .SPHERE, cyan_emit, {0.0, 1.2, 1.5})
  yellow_emit := render.material_create(&app.renderer, render.make_material(base_color_factor = {1.0, 0.9, 0.2, 1}, emissive_factor = 4.0))
  spawn_primitive(app, .SPHERE, yellow_emit, {3.0, 1.2, 1.5})

  metal := render.material_create(&app.renderer, render.make_material(base_color_factor = {0.9, 0.9, 0.95, 1}, metallic_factor = 1.0, roughness_factor = 0.15))
  spawn_primitive(app, .SPHERE, metal, {0.5, 1.0, -1.5})
  rough := render.material_create(&app.renderer, render.make_material(base_color_factor = {0.2, 0.6, 0.8, 1}, metallic_factor = 0.0, roughness_factor = 0.8))
  spawn_primitive(app, .CUBE, rough, {3.0, 1.0, -1.5})
  orange := render.material_create(&app.renderer, render.make_material(base_color_factor = {1.0, 0.4, 0.1, 1}, emissive_factor = 4.0))
  spawn_primitive(app, .CUBE, orange, {-3.0, 1.0, -1.5})
  glass := render.material_create(&app.renderer, render.make_material(.TRANSPARENT, base_color_factor = {0.2, 0.9, 0.4, 0.4}))
  spawn_primitive(app, .SPHERE, glass, {1.5, 1.5, -3.5}, no_shadow = true)

  for i in 0 ..< 5 do mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, .WHITE), {f32(i) * 4.0 - 8.0, 0.5, -7.0})

  mjolnir.spawn(&app.scene, &app.renderer, render.light_create(&app.renderer, render.make_point_light(color = {1.0, 0.5, 0.2}, intensity = 200, radius = 8.0, cast_shadow = false)))
  return .READY
}

spawn_primitive :: proc(app: ^App, shape: render.Primitive, material: render.MaterialHandle, position: [3]f32, no_shadow := false) {
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, shape, material, no_shadow), position)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  if input.key_pressed(&app.input, .F12) do render.screenshot(&app.renderer, "post_process.png")
  effects := &render.main_camera(&app.renderer).effects
  effects^ = {}
  if outline_on    do effects[0] = render.make_effect(render.OutlineEffect{thickness = outline_thickness})
  if fog_on        do effects[1] = render.make_effect(render.FogEffect{color = {0.55, 0.6, 0.7}, start = fog_start, end = fog_end, height = fog_height, height_falloff = fog_height_falloff})
  if dof_on        do effects[2] = render.make_effect(render.DoFEffect{focus_distance = dof_focus, focus_range = dof_range, blur_strength = dof_blur, bokeh_intensity = 0.5})
  if bloom_on      do effects[3] = render.make_effect(render.BloomEffect{threshold = bloom_threshold, intensity = bloom_intensity, blur_radius = 32.0})
  if blur_on       do effects[4] = render.make_effect(render.BlurEffect{radius = blur_radius, weight_falloff = 1.0})
  if crosshatch_on do effects[5] = render.make_effect(render.CrossHatchEffect{hatch_offset_y = 5.0, lum_thresholds = {0.6, 0.3, 0.15, 0.07}})
  if grayscale_on  do effects[6] = render.make_effect(render.GrayscaleEffect{strength = grayscale_strength})
  if tonemap_on    do effects[7] = render.make_effect(render.ToneMapEffect{exposure = tonemap_exposure, gamma = tonemap_gamma})
  if vignette_on && app.vignette != 0 {
    params := VignetteParams{color = {0.02, 0.0, 0.05}, radius = vignette_radius, softness = vignette_softness, strength = vignette_strength}
    effects[8] = render.make_effect(app.vignette, params)
  }
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "Post-process", {20, 20, 280, 560}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Tonemap", &tonemap_on)
    if tonemap_on {
      mu.label(ctx, "Exposure"); mu.slider(ctx, &tonemap_exposure, 0.1, 4.0)
      mu.label(ctx, "Gamma"); mu.slider(ctx, &tonemap_gamma, 1.0, 3.0)
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
      mu.label(ctx, "Start"); mu.slider(ctx, &fog_start, 0.0, 50.0)
      mu.label(ctx, "End"); mu.slider(ctx, &fog_end, 1.0, 200.0)
      mu.label(ctx, "Height"); mu.slider(ctx, &fog_height, -2.0, 10.0)
      mu.label(ctx, "Height falloff"); mu.slider(ctx, &fog_height_falloff, 0.0, 2.0)
    }
    mu.checkbox(ctx, "Outline", &outline_on)
    if outline_on do mu.slider(ctx, &outline_thickness, 0.5, 5.0)
    mu.checkbox(ctx, "Depth of Field", &dof_on)
    if dof_on {
      mu.label(ctx, "Focus"); mu.slider(ctx, &dof_focus, 1.0, 30.0)
      mu.label(ctx, "Range"); mu.slider(ctx, &dof_range, 0.5, 20.0)
      mu.label(ctx, "Blur"); mu.slider(ctx, &dof_blur, 1.0, 50.0)
    }
    mu.checkbox(ctx, "Gaussian Blur", &blur_on)
    if blur_on do mu.slider(ctx, &blur_radius, 0.5, 10.0)
    mu.checkbox(ctx, "Crosshatch", &crosshatch_on)
    mu.checkbox(ctx, "Vignette (user shader)", &vignette_on)
    if vignette_on {
      mu.label(ctx, "Radius"); mu.slider(ctx, &vignette_radius, 0.2, 1.0)
      mu.label(ctx, "Softness"); mu.slider(ctx, &vignette_softness, 0.05, 0.8)
      mu.label(ctx, "Strength"); mu.slider(ctx, &vignette_strength, 0.0, 1.0)
    }
  }
}
