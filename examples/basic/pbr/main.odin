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

rotate_speed: f32 = 0.5
spinning: bool = true
skybox_on: bool = true

App :: struct {
  platform:    platform.Platform,
  scene:       world.World,
  renderer:    render.Renderer,
  input:       input.State,
  debug:       debugui.Context,
  orbit:       render.Orbit,
  turntable:   world.NodeHandle,
  mount:       world.NodeHandle,
  model:       gltf.Model,
  instance:    gltf.Instance,
  model_index: int,
  environment: int,
  sun:         render.LightHandle,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "PBR") do return
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL

  app.orbit = render.make_orbit({0, 0.24, 4.2}, {0, 0, 0})

  app.sun = render.light_create(&app.renderer, render.make_directional_light({1, 0.98, 0.95}, 1, 15))
  mjolnir.spawn(&app.scene, &app.renderer, app.sun)

  app.turntable = world.spawn(&app.scene)
  app.mount = world.spawn(&app.scene, parent = app.turntable)
  world.transform(&app.scene, app.mount).position = {0, -1, 0}
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
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  app.renderer.skybox_intensity = skybox_on ? 1 : 0
  if spinning do world.transform(&app.scene, app.turntable).rotation *= linalg.quaternion_angle_axis(dt * rotate_speed, linalg.VECTOR3F32_Y_AXIS)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "PBR Lighting", {20, 20, 220, 440}) {
  mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Sun intensity")
    mu.slider(ctx, &render.light(&app.renderer, app.sun).intensity, 0.0, 20.0)
    mu.label(ctx, "IBL intensity")
    mu.slider(ctx, &app.renderer.ibl_intensity, 0.0, 2.0)
    mu.checkbox(ctx, "Skybox", &skybox_on)
    mu.label(ctx, "Skybox blur")
    mu.slider(ctx, &app.renderer.skybox_blur, 0.0, 1.0)
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
