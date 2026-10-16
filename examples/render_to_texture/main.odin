// Secondary camera rendered into a bindless texture.
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
  renderer: render.Renderer,
  input:    input.State,
  time:     f32,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

rtt_camera_handle: render.CameraHandle
rtt_material_handle: render.MaterialHandle
spinner_handle: world.NodeHandle

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 800, 600, "Render To Texture") do return
  if !render.init(&app.renderer, "Render To Texture", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

spawn_primitive :: proc(app: ^App, shape: render.Primitive, color: render.Color, position: [3]f32, scale_factor: f32 = 1, cast_shadow := true) -> world.NodeHandle {
  n := world.spawn(&app.scene, position)
  render.attach(&app.renderer, n.index, render.primitive(&app.renderer, shape, color, cast_shadow))
  if scale_factor != 1 do world.scale(&app.scene, n, scale_factor)
  return n
}

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {5, 3, 6}, {0, 1, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))

  spawn_primitive(app, .QUAD_XZ, .GRAY, {0, 0, 0}, 6.0, cast_shadow = false)

  spawn_primitive(app, .CUBE,   .RED,   {-1.5, 0.5, 0})
  spawn_primitive(app, .SPHERE, .GREEN, {0, 0.6, 1.0}, 0.6)
  spawn_primitive(app, .CONE,   .BLUE,  {1.5, 0.5, -0.5})
  spinner_handle = spawn_primitive(app, .CUBE, .YELLOW, {0, 1.8, 0}, 0.4)

  light := world.spawn(&app.scene, {0, 3, 1.5})
  render.attach(&app.renderer, light.index, render.make_point_light({1.0, 0.6, 0.3, 1.0}, 12.0, false))

  rtt_camera_handle = render.camera_create(&app.renderer, 512, 512, {0, 8, 0.01}, {0, 0, 0}, math.PI * 0.5, 0.1, 100.0)
  rtt_material_handle = render.material_create(&app.renderer)

  display_mesh := app.renderer.builtin_meshes[.QUAD_XY]
  display_handle := world.spawn(&app.scene, {0, 2.5, -3.5})
  render.attach(&app.renderer, display_handle.index, render.MeshAttachment{handle = display_mesh, material = rtt_material_handle, cast_shadow = false})
  world.scale(&app.scene, display_handle, 3.0)
  return true
}

update :: proc(app: ^App, dt: f32) {
  app.time += dt
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  world.rotate(&app.scene, spinner_handle, app.time, linalg.VECTOR3F32_Y_AXIS)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ok := render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
  if mat, found := render.material(&app.renderer, rtt_material_handle); found {
    // the image the frame just submitted rendered: the next frame samples it
    // while it draws into the other one
    mat.albedo_texture = render.camera_attachment(&app.renderer, rtt_camera_handle, .FINAL_IMAGE, previous_frame = true)
  }
  return ok
}
