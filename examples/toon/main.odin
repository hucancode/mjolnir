// A user material shader: cel-shaded meshes beside PBR ones.
package main

import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import mu "vendor:microui"

App :: struct {
  window:    platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  debug:     debugui.Context,
  input:     input.State,
  orbit:     render.Orbit,
  toon:      render.MaterialShader,
  materials: [dynamic]render.MaterialHandle,
}

bands: mu.Real = 3
rim: mu.Real = 0.35
shade: mu.Real = 0.35

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1000, 700, "Toon Material") do return
  if !render.init(&app.renderer, "Toon Material", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  render.camera_look_at(render.main_camera(&app.renderer), {0, 4, 10}, {0, 1, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 1, 0})

  when render.RENDER_BACKEND == "vulkan" {
    toon_spirv, toon_wgsl := #load("toon.frag.spv"), ""
  } else {
    toon_spirv, toon_wgsl := ([]u8)(nil), #load("toon.wgsl", string)
  }
  ok: bool
  app.toon, ok = render.material_shader_create(&app.renderer, toon_spirv, toon_wgsl, blend = .NONE)
  if !ok {
    log.error("Failed to create the toon shader")
    return .FAIL
  }

  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 20.0)

  colors := [?][4]f32{{1.0, 0.45, 0.3, 1}, {0.35, 0.8, 0.45, 1}, {0.35, 0.55, 1.0, 1}, {1.0, 0.85, 0.3, 1}}
  shapes := [?]render.Primitive{.SPHERE, .CUBE, .SPHERE, .CUBE}
  for color, i in colors {
    mat := render.material_create(&app.renderer, render.make_material(.CUSTOM, base_color_factor = color, shader = app.toon))
    append(&app.materials, mat)
    spawn_mesh(app, shapes[i], mat, {f32(i) * 2.5 - 3.75, 1.0, 0})
  }
  pbr := render.material_create(&app.renderer, render.make_material(base_color_factor = {0.9, 0.9, 0.95, 1}, roughness_value = 0.4))
  spawn_mesh(app, .SPHERE, pbr, {0, 1.0, -3.0})

  return .READY
}

spawn_mesh :: proc(app: ^App, shape: render.Primitive, material: render.MaterialHandle, position: [3]f32) {
  n := world.spawn(&app.scene, position)
  render.attach(&app.renderer, render.SlotHandle(n.index), render.primitive(&app.renderer, shape, material))
}

shutdown :: proc(app: ^App) {
  delete(app.materials)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  for h in app.materials {
    m := render.material(&app.renderer, h) or_continue
    m.params[0] = {f32(bands), f32(rim), f32(shade), 0}
  }
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Toon", {700, 20, 280, 230}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Bands"); mu.slider(ctx, &bands, 1, 8, 1)
    mu.label(ctx, "Rim"); mu.slider(ctx, &rim, 0, 1)
    mu.label(ctx, "Shade"); mu.slider(ctx, &shade, 0, 1)
  }
}
