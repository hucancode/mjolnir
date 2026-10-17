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
  w := &app.window
  if !platform.init(w, 800, 600, "Transparent") do return
  if !render.init(&app.renderer, "Transparent", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {6, 3, 6}, {0, 1, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))

  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 6.0)

  // Solid red sphere behind the glass slabs
  red_mat := render.material_create(&app.renderer, render.make_material(base_color_factor = {0.95, 0.15, 0.15, 1}, roughness_value = 0.4))
  sphere := world.spawn(&app.scene, {0, 1, -2})
  render.attach(&app.renderer, render.SlotHandle(sphere.index), render.MeshAttachment{mesh = app.renderer.builtin_meshes[.SPHERE], material = red_mat, cast_shadow = true})

  // Stack of transparent quads, increasing opacity
  cube := app.renderer.builtin_meshes[.CUBE]
  colors := [4][4]f32{
    {0.2, 0.7, 1.0, 0.20},
    {0.2, 1.0, 0.4, 0.40},
    {1.0, 0.7, 0.2, 0.65},
    {1.0, 0.2, 0.7, 0.85},
  }
  for c, i in colors {
    mat := render.material_create(&app.renderer, render.make_material(.TRANSPARENT, base_color_factor = c))
    h := world.spawn(&app.scene, {f32(i) * 0.6 - 1.0, 1.0, f32(i) * 0.4})
    render.attach(&app.renderer, render.SlotHandle(h.index), render.MeshAttachment{mesh = cube, material = mat, cast_shadow = false})
    world.scale(&app.scene, h, 0.8)
  }

  light := world.spawn(&app.scene, {3, 6, 3})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_directional_light(
    color         = {1, 0.97, 0.9, 1},
    shadow_radius = 10,
    cast_shadow   = true,
  )))
  return true
}
