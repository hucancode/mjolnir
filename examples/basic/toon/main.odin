// A user material shader: cel-shaded meshes beside PBR ones.
package main

import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:log"
import mu "vendor:microui"

App :: struct {
  platform:  platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  debug:     debugui.Context,
  input:     input.State,
  orbit:     render.Orbit,
  toon:      render.MaterialShader,
  materials: [dynamic]render.MaterialHandle,
}

bands: f32 = 3
rim: f32 = 0.35
shade: f32 = 0.35

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1000, 700, "Toon Material") do return
  if !render.init(&app.renderer, app.platform.window) do return
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.orbit = render.make_orbit({0, 4, 10}, {0, 1, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

  ok: bool
  app.toon, ok = render.material_shader_create(&app.renderer, #load("toon." + render.SHADER_EXT), blend = .NONE)
  if !ok {
    log.error("Failed to create the toon shader")
    return .FAIL
  }

  mjolnir.spawn_mesh(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false), scale = 20.0)

  colors := [?][4]f32{{1.0, 0.45, 0.3, 1}, {0.35, 0.8, 0.45, 1}, {0.35, 0.55, 1.0, 1}, {1.0, 0.85, 0.3, 1}}
  shapes := [?]render.Primitive{.SPHERE, .CUBE, .SPHERE, .CUBE}
  for color, i in colors {
    mat := render.material_create(&app.renderer, render.make_material(.CUSTOM, base_color_factor = color, shader = app.toon))
    append(&app.materials, mat)
    spawn_primitive(app, shapes[i], mat, {f32(i) * 2.5 - 3.75, 1.0, 0})
  }
  pbr := render.material_create(&app.renderer, render.make_material(base_color_factor = {0.9, 0.9, 0.95, 1}, roughness_value = 0.4))
  spawn_primitive(app, .SPHERE, pbr, {0, 1.0, -3.0})

  return .READY
}

spawn_primitive :: proc(app: ^App, shape: render.Primitive, material: render.MaterialHandle, position: [3]f32) {
  mjolnir.spawn_mesh(&app.scene, &app.renderer, render.primitive(&app.renderer, shape, material), position)
}

shutdown :: proc(app: ^App) {
  delete(app.materials)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.platform)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  render.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  for h in app.materials {
    m := render.material(&app.renderer, h) or_continue
    m.params[0] = {bands, rim, shade, 0}
  }
  mjolnir.update(&app.scene, &app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Toon", {700, 20, 280, 230}, {.RIGHT, .TOP}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Bands"); mu.slider(ctx, &bands, 1, 8, 1)
    mu.label(ctx, "Rim"); mu.slider(ctx, &rim, 0, 1)
    mu.label(ctx, "Shade"); mu.slider(ctx, &shade, 0, 1)
  }
}
