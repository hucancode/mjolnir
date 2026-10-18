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
}

MODELS := [?]Model{
  {"Mjolnir",        #load("../../assets/Mjolnir.glb")},
  {"Suzanne",        #load("../../assets/Suzanne.glb")},
  {"Duck",           #load("../../assets/Duck.glb")},
  {"Damaged Helmet", #load("../../assets/DamagedHelmet.glb")},
  {"SciFi Helmet",   #load("../../assets/SciFiHelmet.glb")},
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
  turntable:   world.NodeHandle,
  mount:       world.NodeHandle,
  model:       gltf.Model,
  instance:    gltf.Instance,
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer, {800, 600}) do return .FAIL

  render.camera_look_at(render.main_camera(&app.renderer), {0, 0.24, 4.2}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 0, 0})

  app.renderer.sun = {enabled = true, cast_shadow = true, color = {1, 0.98, 0.95}, intensity = f32(dir_intensity), direction = {0, 0, -1}, shadow_distance = 15}

  app.turntable = world.spawn(&app.scene)
  app.mount = world.spawn(&app.scene, parent = app.turntable)
  world.translate(&app.scene, app.mount, 0, -1, 0)
  show_model(app, 0)
  return .READY
}

shutdown :: proc(app: ^App) {
  gltf.destroy(&app.instance, &app.scene)
  gltf.destroy(&app.model, &app.renderer)
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
  gltf.destroy(&app.instance, &app.scene)
  gltf.destroy(&app.model, &app.renderer)
  app.model_index = index
  m := MODELS[index]
  app.model = gltf.model_create(&app.renderer, m.data)
  app.instance = gltf.instance_create(&app.model, &app.scene, &app.renderer, parent = app.mount)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  app.renderer.sun.intensity = f32(dir_intensity)
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
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "PBR Lighting", {550, 20, 220, 400}, {.RIGHT, .TOP}, {.NO_CLOSE}) {
    mu.label(ctx, "Sun intensity")
    mu.slider(ctx, &dir_intensity, 0.0, 20.0)
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
}
