package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

Model :: struct {
  label:  string,
  path:   string,
  scale:  f32,
  offset: [3]f32,
  rot_x:  f32,
}

MODELS := [?]Model{
  {"Mjolnir",        "assets/Mjolnir.glb",        0.3,   {0, -1, 0},    math.PI * -0.3},
  {"Suzanne",        "assets/Suzanne.glb",        1.0,   {0, 0, 0},     0},
  {"Duck",           "assets/Duck.glb",           0.4,   {0, -1, 0},    0},
  {"Damaged Helmet", "assets/DamagedHelmet.glb",  1.0,   {0, 0, 0},     math.PI * 0.5},
  {"SciFi Helmet",   "assets/SciFiHelmet.glb",    1.0,   {0, -1, 0},    0},
}

model: mjolnir.GltfScene
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
  renderer: render.Manager,
  input:    input.State,
}

main :: proc() {
  defer mjolnir.gltf_scene_destroy(&model)
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 800, 600, "PBR") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "PBR", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")

  render.main_camera_look_at(&app.renderer, {0, 0.2, 3.5}, {0, 0, 0})
  dir_light = world.spawn(&app.scene, {4, 6, 4})
  render.attach(&app.renderer, dir_light.index, render.directional_light_attachment({1, 0.98, 0.95, f32(dir_intensity)}, 15.0, false))
  swap_model(app, 0)

  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

swap_model :: proc(app: ^App, index: int) {
  if index == current_model do return
  for h in model.roots do world.despawn(&app.scene, h)
  mjolnir.gltf_scene_destroy(&model)
  current_model = index
  m := MODELS[index]
  model = mjolnir.load_gltf(&app.scene, &app.renderer, m.path)
  rotation_phase = 0
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  render.debug_ui_input(&app.renderer, &app.input)
  if cam, ok := render.main_camera(&app.renderer); ok && !app.input.mouse_captured {
    yaw, pitch, dist := render.camera_orbit_state(cam)
    if input.mouse_down(&app.input, .LEFT) {
      yaw += app.input.mouse_delta.x * 0.02
      pitch = clamp(pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    render.camera_orbit(cam, yaw, pitch, clamp(dist - app.input.scroll.y * 2, 1, 200))
  }
  if l, ok := render.attachment(&app.renderer, dir_light.index, render.LightAttachment); ok {
    l.color[3] = f32(dir_intensity)
    render.attach(&app.renderer, dir_light.index, l)
  }
  app.renderer.ambient.ibl_intensity = f32(ibl_intensity)
  app.renderer.ambient.skybox_intensity = skybox_on ? 1 : 0
  app.renderer.ambient.skybox_blur = f32(skybox_blur)
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
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  render.stage_transforms(&app.renderer, world.changed_nodes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := render.debug_ui(&app.renderer)
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
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
