// Wireframe rendering pipeline.
package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
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

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 800, 600, "Wireframe") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Wireframe", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

handles: [9]world.NodeHandle

setup :: proc(app: ^App) {
  render.main_camera_look_at(&app.renderer, {0, 4, 9}, {0, 0, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  app.renderer.ambient.skybox_intensity = 0

  cube := app.renderer.builtin_meshes[.CUBE]
  mat := render.material_wireframe(&app.renderer)

  for i in 0 ..< 9 {
    row := i / 3
    col := i % 3
    x := f32(col - 1) * 2.5
    z := f32(row - 1) * 2.5
    h := world.spawn(&app.scene, {x, 0, z})
    render.attach(&app.renderer, h.index, render.MeshAttachment{handle = cube, material = mat, cast_shadow = false})
    world.scale(&app.scene, h, 0.7)
    handles[i] = h
  }
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
  render.main_camera_orbit(&app.renderer, app.yaw, app.pitch, app.dist)
  t := app.time
  axis := linalg.normalize([3]f32{1, 1, 0.4})
  for h, i in handles {
    world.rotate(&app.scene, h, linalg.quaternion_angle_axis(t * (0.4 + f32(i) * 0.15), axis))
  }
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
