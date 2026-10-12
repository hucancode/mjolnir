package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Manager,
  camera:   mjolnir.CameraController,
  input:    input.State,
  time:     f32,
}

rtt_camera_handle: render.CameraHandle
rtt_material_handle: render.MaterialHandle
spinner_handle: world.NodeHandle

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 800, 600, "Render To Texture") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Render To Texture", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  app.camera = mjolnir.orbit_controller()
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
  render.main_camera_look_at(&app.renderer, {5, 3, 6}, {0, 1, 0})

  spawn_primitive(app, .QUAD_XZ, .GRAY, {0, 0, 0}, 6.0, cast_shadow = false)

  spawn_primitive(app, .CUBE,   .RED,   {-1.5, 0.5, 0})
  spawn_primitive(app, .SPHERE, .GREEN, {0, 0.6, 1.0}, 0.6)
  spawn_primitive(app, .CONE,   .BLUE,  {1.5, 0.5, -0.5})
  spinner_handle = spawn_primitive(app, .CUBE, .YELLOW, {0, 1.8, 0}, 0.4)

  light := world.spawn(&app.scene, {0, 3, 1.5})
  render.attach(&app.renderer, light.index, render.point_light_attachment({1.0, 0.6, 0.3, 1.0}, 12.0, false))

  rtt_camera_handle = render.create_camera(&app.renderer, 512, 512, {0, 8, 0.01}, {0, 0, 0}, math.PI * 0.5, 0.1, 100.0)
  rtt_material_handle = render.create_material(&app.renderer)

  display_mesh := app.renderer.builtin_meshes[.QUAD_XY]
  display_handle := world.spawn(&app.scene, {0, 2.5, -3.5})
  render.attach(&app.renderer, display_handle.index, render.MeshAttachment{handle = display_mesh, material = rtt_material_handle, cast_shadow = false})
  world.scale(&app.scene, display_handle, 3.0)
}

update :: proc(app: ^App, dt: f32) {
  app.time += dt
  platform.read_input(&app.window, &app.input)
  mjolnir.camera_controller_update(&app.camera, &app.renderer, &app.input, dt)
  world.rotate(&app.scene, spinner_handle, app.time, linalg.VECTOR3F32_Y_AXIS)
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  render.stage_transforms(&app.renderer, world.changed_nodes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ok := render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
  if mat, found := render.material(&app.renderer, rtt_material_handle); found {
    mat.albedo_index = render.texture_index(render.camera_attachment(&app.renderer, rtt_camera_handle, .FINAL_IMAGE))
    render.set_material(&app.renderer, rtt_material_handle, mat^)
  }
  return ok
}
