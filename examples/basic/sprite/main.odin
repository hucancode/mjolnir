// Sprite sheets with frame animation.
package main

import "mjolnir"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:log"

SHEET_COLUMNS :: 6
SHEET_ROWS :: 17
FRAME_COUNT :: 99
FPS :: 24.0

Mode :: enum {
  LOOP,
  PINGPONG,
  ONCE,
}

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  orbit:    render.Orbit,
  sprites:  [Mode]render.MaterialHandle,
  elapsed:  f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 800, 600, "Sprite") do return
  if !render.init(&app.renderer, "Sprite", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  render.camera_look_at(render.main_camera(&app.renderer), {0, 1.5, 6}, {0, 1.5, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 1.5, 0})

  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 6.0)

  tex, tex_ok := render.texture_create(&app.renderer, #load("assets/Warrior_Sheet-Effect.png"))
  if !tex_ok {
    log.error("failed to load warrior sheet")
    return .FAIL
  }

  xs := [Mode]f32{.LOOP = -3.0, .PINGPONG = 0.0, .ONCE = 3.0}
  for x, mode in xs {
    sprite := render.material_create(&app.renderer, render.make_material(.SPRITE, albedo_texture = tex, frame_columns = SHEET_COLUMNS, frame_rows = SHEET_ROWS)) or_continue
    node := world.spawn(&app.scene, {x, 1.5, 0}) or_continue
    render.attach(&app.renderer, render.SlotHandle(node.index), render.primitive(&app.renderer, .QUAD_XY, sprite, cast_shadow = false))
    app.sprites[mode] = sprite
    world.scale(&app.scene, node, 2.5)
  }

  return .READY
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured do render.orbit_drag(&app.orbit, 0, app.input.scroll.y)
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  app.elapsed += dt
  frames := sheet_frames(app.elapsed)
  for sprite, mode in app.sprites do render.set_sprite_frame(&app.renderer, sprite, frames[mode])
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

sheet_frames :: proc(elapsed: f32) -> [Mode]u32 {
  step := u32(elapsed * FPS)
  cycle := u32(2 * (FRAME_COUNT - 1))
  bounce := step % cycle
  return {
    .LOOP     = step % FRAME_COUNT,
    .PINGPONG = bounce if bounce < FRAME_COUNT else cycle - bounce,
    .ONCE     = min(step, FRAME_COUNT - 1),
  }
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
