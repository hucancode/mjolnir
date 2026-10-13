// Order-dependent transparency.
package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 800, 600, "Transparent") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Transparent", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.main_camera_orbit(&app.renderer, app.yaw, app.pitch, app.dist)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

setup :: proc(app: ^App) {
  render.main_camera_look_at(&app.renderer, {6, 3, 6}, {0, 1, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))

  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, ground.index, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 6.0)

  // Solid red sphere behind the glass slabs
  red_mat := render.material_pbr(&app.renderer, {0.95, 0.15, 0.15, 1}, roughness = 0.4)
  sphere := world.spawn(&app.scene, {0, 1, -2})
  render.attach(&app.renderer, sphere.index, render.MeshAttachment{handle = app.renderer.builtin_meshes[.SPHERE], material = red_mat, cast_shadow = true})

  // Stack of transparent quads, increasing opacity
  cube := app.renderer.builtin_meshes[.CUBE]
  colors := [4][4]f32{
    {0.2, 0.7, 1.0, 0.20},
    {0.2, 1.0, 0.4, 0.40},
    {1.0, 0.7, 0.2, 0.65},
    {1.0, 0.2, 0.7, 0.85},
  }
  for c, i in colors {
    mat := render.material_transparent(&app.renderer, c)
    h := world.spawn(&app.scene, {f32(i) * 0.6 - 1.0, 1.0, f32(i) * 0.4})
    render.attach(&app.renderer, h.index, render.MeshAttachment{handle = cube, material = mat, cast_shadow = false})
    world.scale(&app.scene, h, 0.8)
  }

  light := world.spawn(&app.scene, {3, 6, 3})
  render.attach(&app.renderer, light.index, render.directional_light_attachment(
    color         = {1, 0.97, 0.9, 1},
    shadow_radius = 10,
    cast_shadow   = true,
  ))
}
