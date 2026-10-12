package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
}

spinner: world.NodeHandle

ortho_width: mu.Real = 12.0
ortho_height: mu.Real = 12.0
cam_height: mu.Real = 10.0
cam_yaw: mu.Real = 0.0
phase: f32

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 1000, 700, "Orthographic Camera") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Orthographic Camera", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  setup(app)
  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

spawn_primitive :: proc(app: ^App, shape: render.Primitive, color: render.Color, position: [3]f32, scale_factor: f32 = 1, cast_shadow := true) -> world.NodeHandle {
  n := world.spawn(&app.scene, position)
  render.attach(&app.renderer, n.index, render.primitive(&app.renderer, shape, color, cast_shadow))
  if scale_factor != 1 do world.scale(&app.scene, n, scale_factor)
  return n
}

setup :: proc(app: ^App) {
  spawn_primitive(app, .CUBE,     .RED,    {-2.5, 0.5, 0})
  spawn_primitive(app, .SPHERE,   .GREEN,  {2.5, 0.5, 0},  0.7)
  spawn_primitive(app, .CYLINDER, .BLUE,   {0, 1.0, 2.5},  0.5)
  spawn_primitive(app, .CONE,     .YELLOW, {0, 0.8, -2.5}, 0.5)
  spinner = spawn_primitive(app, .CUBE, .MAGENTA, {0, 1.5, 0}, 0.4)

  spawn_primitive(app, .QUAD_XZ, .GRAY, {0, 0, 0}, 6.0, cast_shadow = false)

  point := world.spawn(&app.scene, {3, 8, 3})
  render.attach(&app.renderer, point.index, render.point_light_attachment({1.0, 0.95, 0.8, 1.0}, 25.0, false))
  sun := world.spawn(&app.scene, {-6, 10, -4})
  render.attach(&app.renderer, sun.index, render.directional_light_attachment({1.0, 0.95, 0.9, 4.0}, 15.0, true))

  cam := render.main_camera(&app.renderer)
  render.camera_set_orthographic(cam, f32(ortho_width), f32(ortho_height))
  render.camera_look_at(cam, {0, f32(cam_height), 0.01}, {0, 0, 0})
  log.info("Orthographic Main Camera — top-down view")
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  render.debug_ui_input(&app.renderer, &app.input)
  phase += dt
  world.rotate(&app.scene, spinner, phase)
  yaw := f32(cam_yaw)
  pos := [3]f32{math.sin(yaw) * 0.5, f32(cam_height), math.cos(yaw) * 0.5}
  cam := render.main_camera(&app.renderer)
  render.camera_set_orthographic(cam, f32(ortho_width), f32(ortho_height))
  render.camera_look_at(cam, pos, {0, 0, 0})
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  render.stage_transforms(&app.renderer, world.changed_nodes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "Ortho Main", {700, 20, 280, 280}, {.NO_CLOSE}) {
    mu.label(ctx, fmt.tprintf("Ortho width: %.1f", ortho_width));   mu.slider(ctx, &ortho_width, 2.0, 30.0)
    mu.label(ctx, fmt.tprintf("Ortho height: %.1f", ortho_height)); mu.slider(ctx, &ortho_height, 2.0, 30.0)
    mu.label(ctx, fmt.tprintf("Cam height: %.1f", cam_height));     mu.slider(ctx, &cam_height, 2.0, 30.0)
    mu.label(ctx, fmt.tprintf("Cam yaw: %.2f rad", cam_yaw));       mu.slider(ctx, &cam_yaw, -math.PI, math.PI)
  }
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
