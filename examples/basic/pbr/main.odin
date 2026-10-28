// IBL + physically based rendering showcase: glTF models lit by a choice of HDR environment maps.
package main

import "core:log"
import "core:math/linalg"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/gltf"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

Model :: struct {
  label:  string,
  data:   []u8,
}

MODELS := [?]Model{
  {"Mjolnir",        #load("assets/Mjolnir.glb")},
  {"Suzanne",        #load("assets/Suzanne.glb")},
  {"Duck",           #load("assets/Duck.glb")},
  {"Damaged Helmet", #load("assets/DamagedHelmet.glb")},
}

ENVIRONMENTS := [?]Model{
  {"Default",  #load("mjolnir/render/assets/environment2.hdr")},
  {"Overcast", #load("mjolnir/render/assets/environment.hdr")},
}

dir_intensity: f32 = 1.0
rotate_speed: f32 = 0.5
spinning: bool = true
ibl_intensity: f32 = 1.0
skybox_on: bool = true
skybox_blur: f32 = 0.25

App :: struct {
  platform:    platform.Platform,
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
  environment: int,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 800, 600, "PBR") do return
  if !render.init(&app.renderer, app.platform.window) do return
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
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL

  app.orbit = render.make_orbit({0, 0.24, 4.2}, {0, 0, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

  app.renderer.sun = {enabled = true, cast_shadow = true, color = {1, 0.98, 0.95}, intensity = dir_intensity, direction = {0, 0, -1}, shadow_distance = 15}

  app.turntable = world.spawn(&app.scene)
  app.mount = world.spawn(&app.scene, parent = app.turntable)
  world.translate(&app.scene, app.mount, 0, -1, 0)
  show_model(app, 0)
  show_environment(app, 0)
  return .READY
}

shutdown :: proc(app: ^App) {
  gltf.destroy(&app.instance, &app.scene, &app.renderer)
  gltf.destroy(&app.model, &app.renderer)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.platform)
}

show_model :: proc(app: ^App, index: int) {
  gltf.destroy(&app.instance, &app.scene, &app.renderer)
  gltf.destroy(&app.model, &app.renderer)
  app.model_index = index
  m := MODELS[index]
  app.model = gltf.model_create(&app.renderer, m.data)
  app.instance = gltf.instance_create(&app.model, &app.scene, &app.renderer, parent = app.mount)
}

show_environment :: proc(app: ^App, index: int) {
  if render.environment_map_load(&app.renderer, ENVIRONMENTS[index].data) do app.environment = index
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  render.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  app.renderer.sun.intensity = dir_intensity
  app.renderer.ibl_intensity = ibl_intensity
  app.renderer.skybox_intensity = skybox_on ? 1 : 0
  app.renderer.skybox_blur = skybox_blur
  if spinning do world.rotate_by(&app.scene, app.turntable, dt * rotate_speed, linalg.VECTOR3F32_Y_AXIS)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "PBR Lighting", {560, 20, 220, 440}, {.RIGHT, .TOP}, {.NO_CLOSE}) {
	mu.layout_row(ctx, {-1}, 0)
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
    mu.label(ctx, "Environment:")
    for e, i in ENVIRONMENTS {
      if .SUBMIT in mu.button(ctx, e.label) && i != app.environment do show_environment(app, i)
    }
  }
}
