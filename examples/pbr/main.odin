// IBL + physically based rendering showcase.
package main

import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"
import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/gltf"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"

Model :: struct {
  label:  string,
  data:   []u8,
  scale:  f32,
  offset: [3]f32,
  rot_x:  f32,
}

MODELS := [?]Model{
  {"Mjolnir",        #load("../../assets/Mjolnir.glb"),        0.3,   {0, -1, 0},    math.PI * -0.3},
  {"Suzanne",        #load("../../assets/Suzanne.glb"),        1.0,   {0, 0, 0},     0},
  {"Duck",           #load("../../assets/Duck.glb"),           0.4,   {0, -1, 0},    0},
  {"Damaged Helmet", #load("../../assets/DamagedHelmet.glb"),  1.0,   {0, 0, 0},     math.PI * 0.5},
  {"SciFi Helmet",   #load("../../assets/SciFiHelmet.glb"),    1.0,   {0, -1, 0},    0},
}

dir_intensity: mu.Real = 1.0
rotate_speed: mu.Real = 0.5
spinning: bool = true
ibl_intensity: mu.Real = 1.0
skybox_on: bool = true
skybox_blur: mu.Real = 0.25

App :: struct {
  window:      platform.Platform,
  scene:       world.World,
  renderer:    render.Renderer,
  debug:       debugui.Context,
  input:       input.State,
  orbit:       render.Orbit,
  sun:         render.LightHandle,
  turntable:   world.NodeHandle,
  mount:       world.NodeHandle,
  model:       gltf.Scene,
  model_index: int,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 800, 600, "PBR") do return
  if !render.init(&app.renderer, "PBR", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))

  render.camera_look_at(render.main_camera(&app.renderer), {0, 0.2, 3.5}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer))

  sun := world.spawn(&app.scene, {4, 6, 4})
  app.sun = render.light_create(&app.renderer, render.make_directional_light({1, 0.98, 0.95}, f32(dir_intensity), 15.0))
  render.attach(&app.renderer, render.SlotHandle(sun.index), app.sun)

  app.turntable = world.spawn(&app.scene)
  app.mount = world.spawn(&app.scene, parent = app.turntable)
  show_model(app, 0)
  return true
}

shutdown :: proc(app: ^App) {
  gltf.destroy(&app.model, &app.scene, &app.renderer)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

show_model :: proc(app: ^App, index: int) {
  gltf.destroy(&app.model, &app.scene, &app.renderer)
  app.model_index = index
  m := MODELS[index]
  world.translate(&app.scene, app.mount, m.offset)
  world.rotate(&app.scene, app.mount, m.rot_x, linalg.VECTOR3F32_X_AXIS)
  world.scale(&app.scene, app.mount, m.scale)
  app.model = gltf.scene_create(&app.scene, &app.renderer, m.data, parent = app.mount)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  render.light(&app.renderer, app.sun).intensity = f32(dir_intensity)
  app.renderer.ibl_intensity = f32(ibl_intensity)
  app.renderer.skybox_intensity = skybox_on ? 1 : 0
  app.renderer.skybox_blur = f32(skybox_blur)
  if spinning do world.rotate_by(&app.scene, app.turntable, dt * f32(rotate_speed), linalg.VECTOR3F32_Y_AXIS)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "PBR Lighting", {550, 20, 220, 400}, {.NO_CLOSE}) {
    mu.label(ctx, "Sun intensity")
    mu.slider(ctx, &dir_intensity, 0.0, 5.0)
    mu.label(ctx, "IBL intensity")
    mu.slider(ctx, &ibl_intensity, 0.0, 2.0)
    mu.checkbox(ctx, "Skybox", &skybox_on)
    mu.label(ctx, "Skybox blur")
    mu.slider(ctx, &skybox_blur, 0.0, 1.0)
    mu.checkbox(ctx, "Spinning", &spinning)
    mu.label(ctx, "Model:")
    mu.layout_row(ctx, {-1}, 0)
    for m, i in MODELS {
      if .SUBMIT in mu.button(ctx, m.label) && i != app.model_index do show_model(app, i)
    }
  }
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
