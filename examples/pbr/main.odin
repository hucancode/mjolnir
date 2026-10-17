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

model: gltf.Scene
current_model: int = -1
dir_light: world.NodeHandle

dir_intensity: mu.Real = 1.0
rotate_speed: mu.Real = 0.5
spinning: bool = true
rotation_phase: f32
ibl_intensity: mu.Real = 1.0
skybox_on: bool = true
skybox_blur: mu.Real = 0.25

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
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

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))

  render.camera_look_at(render.main_camera(&app.renderer), {0, 0.2, 3.5}, {0, 0, 0})

  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  dir_light = world.spawn(&app.scene, {4, 6, 4})
  render.attach(&app.renderer, render.SlotHandle(dir_light.index), render.light_create(&app.renderer, render.make_directional_light({1, 0.98, 0.95, f32(dir_intensity)}, 15.0, false)))
  swap_model(app, 0)
  return true
}

shutdown :: proc(app: ^App) {
  gltf.destroy(&model)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

swap_model :: proc(app: ^App, index: int) {
  if index == current_model do return
  for h in model.roots do world.destroy(&app.scene, h)
  gltf.destroy(&model)
  current_model = index
  m := MODELS[index]
  model = gltf.scene_create(&app.scene, &app.renderer, m.data)
  rotation_phase = 0
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  if l, ok := render.light(&app.renderer, render.attachment(&app.renderer, render.SlotHandle(dir_light.index), render.LightHandle)); ok {
    l.color[3] = f32(dir_intensity)
  }
  app.renderer.ibl_intensity = f32(ibl_intensity)
  app.renderer.skybox_intensity = skybox_on ? 1 : 0
  app.renderer.skybox_blur = f32(skybox_blur)
  if spinning {
    rotation_phase += dt * f32(rotate_speed)
  }
  m := MODELS[current_model]
  for h in model.roots {
    world.translate(&app.scene, h, m.offset)
    world.rotate(&app.scene, h, rotation_phase, linalg.VECTOR3F32_Y_AXIS)
    if m.rot_x != 0 do world.rotate_by(&app.scene, h, m.rot_x, linalg.VECTOR3F32_X_AXIS)
    world.scale(&app.scene, h, m.scale)
  }
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
      if .SUBMIT in mu.button(ctx, m.label) do swap_model(app, i)
    }
  }
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
