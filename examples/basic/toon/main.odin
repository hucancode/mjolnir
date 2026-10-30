// A user material shader: cel-shaded meshes beside PBR ones.
package main

import "core:log"
import "core:math/linalg"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

App :: struct {
  platform:  platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  input:     input.State,
  debug:     debugui.Context,
  orbit:     render.Orbit,
  materials: [dynamic]render.MaterialHandle,
}

bands: f32 = 3
rim: f32 = 0.35
shade: f32 = 0.35

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Toon Material") do return
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
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.orbit = render.make_orbit({0, 4, 10}, {0, 1, 0})

  toon, ok := render.material_shader_create(&app.renderer, #load("toon." + render.SHADER_EXT), blend = .NONE)
  if !ok {
    log.error("Failed to create the toon shader")
    return .FAIL
  }

  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, no_shadow = true), scale = 20.0)

  colors := [?][4]f32{{1.0, 0.45, 0.3, 1}, {0.35, 0.8, 0.45, 1}, {0.35, 0.55, 1.0, 1}, {1.0, 0.85, 0.3, 1}}
  shapes := [?]render.Primitive{.SPHERE, .CUBE, .SPHERE, .CUBE}
  for color, i in colors {
    mat := render.material_create(&app.renderer, render.make_material(toon, base_color_factor = color))
    append(&app.materials, mat)
    spawn_primitive(app, shapes[i], mat, {f32(i) * 2.5 - 3.75, 1.0, 0})
  }
  pbr := render.material_create(&app.renderer, render.make_material(base_color_factor = {0.9, 0.9, 0.95, 1}, roughness_factor = 0.4))
  spawn_primitive(app, .SPHERE, pbr, {0, 1.0, -3.0})

  return .READY
}

spawn_primitive :: proc(app: ^App, shape: render.Primitive, material: render.MaterialHandle, position: [3]f32) {
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, shape, material), position)
}

shutdown :: proc(app: ^App) {
  delete(app.materials)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  for h in app.materials {
    m := render.material(&app.renderer, h) or_continue
    m.params[0] = {bands, rim, shade, 0}
  }
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "Toon", {20, 20, 280, 230}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Bands"); mu.slider(ctx, &bands, 1, 8, 1)
    mu.label(ctx, "Rim"); mu.slider(ctx, &rim, 0, 1)
    mu.label(ctx, "Shade"); mu.slider(ctx, &shade, 0, 1)
  }
}
