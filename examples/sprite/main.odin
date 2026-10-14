// Sprite sheets with frame animation.
package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"

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
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

sprites: [Mode]render.MaterialHandle
elapsed: f32

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 800, 600, "Sprite") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Sprite", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")

  setup(app)

  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

setup :: proc(app: ^App) {
  render.main_camera_look_at(&app.renderer, {0, 1.5, 6}, {0, 1.5, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))

  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, ground.index, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 6.0)

  tex, tex_ok := render.create_texture_from_path(&app.renderer, "assets/Warrior_Sheet-Effect.png")
  if !tex_ok {
    log.error("failed to load warrior sheet")
    return
  }

  xs := [Mode]f32{.LOOP = -3.0, .PINGPONG = 0.0, .ONCE = 3.0}
  for x, mode in xs {
    sprite := render.material_sprite(&app.renderer, tex, 6, 17) or_continue
    node := world.spawn(&app.scene, {x, 1.5, 0}) or_continue
    render.attach(&app.renderer, node.index, render.MeshAttachment {
      handle   = app.renderer.builtin_meshes[.QUAD_XY],
      material = sprite,
    })
    sprites[mode] = sprite
    world.scale(&app.scene, node, 2.5)
  }

  light := world.spawn(&app.scene, {2, 6, 4})
  render.attach(&app.renderer, light.index, render.directional_light_attachment(color = {1, 1, 1, 1}, shadow_radius = 8))
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

// Pick each sprite's sheet cell from elapsed time.
update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured do app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  render.main_camera_orbit(&app.renderer, app.yaw, app.pitch, app.dist)
  elapsed += dt
  step := u32(elapsed * FPS)
  cycle := u32(2 * (FRAME_COUNT - 1))
  bounce := step % cycle
  frames := [Mode]u32 {
    .LOOP     = step % FRAME_COUNT,
    .PINGPONG = bounce if bounce < FRAME_COUNT else cycle - bounce,
    .ONCE     = min(step, FRAME_COUNT - 1),
  }
  for sprite, mode in sprites do render.set_sprite_frame(&app.renderer, sprite, frames[mode])
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
