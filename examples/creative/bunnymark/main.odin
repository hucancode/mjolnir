// Bunnymark: hold the mouse to spawn bouncing sprites and see how many the engine can move.
package main

import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math/rand"
import mu "vendor:microui"

VIEW_HEIGHT :: 10.0
BUNNY_SIZE :: 0.5
GRAVITY :: 9.0
SPAWN_PER_TICK :: 100
SPAWN_SPEED :: 4.0
BOUNCE_DAMPING :: 0.85
FPS_SMOOTHING :: 0.05

SPRITE_SIZE :: 16
SPRITE_ART :: [SPRITE_SIZE]string {
  "................",
  "...##......##...",
  "..#ww#....#ww#..",
  "..#wp#....#wp#..",
  "..#wp#....#wp#..",
  "..#wp#....#wp#..",
  "..#ww######ww#..",
  "...#wwwwwwww#...",
  "..#wwwwwwwwww#..",
  "..#wwkwwwwkww#..",
  "..#wwwwppwwww#..",
  "..#wwwwwwwwww#..",
  "...#wwwwwwww#...",
  "....########....",
  "................",
  "................",
}

TINTS :: [?][4]f32 {
  {1, 1, 1, 1},
  {1, 0.5, 0.5, 1},
  {0.5, 1, 0.5, 1},
  {0.5, 0.7, 1, 1},
  {1, 1, 0.5, 1},
  {1, 0.6, 1, 1},
}

Bunny :: struct {
  node:     world.NodeHandle,
  position: [2]f32,
  velocity: [2]f32,
}

App :: struct {
  platform:  platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  input:     input.State,
  debug:     debugui.Context,
  materials: [len(TINTS)]render.MaterialHandle,
  bunnies:   [dynamic]Bunny,
  half:      [2]f32,
  fps:       f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Bunnymark") do return
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

shutdown :: proc(app: ^App) {
  delete(app.bunnies)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL

  pixels: [SPRITE_SIZE * SPRITE_SIZE * 4]u8
  art := SPRITE_ART
  for row, y in art {
    for c, x in row {
      color: [4]u8
      switch c {
      case '#': color = {70, 50, 60, 255}
      case 'w': color = {245, 240, 235, 255}
      case 'p': color = {250, 160, 180, 255}
      case 'k': color = {20, 20, 30, 255}
      }
      i := (y * SPRITE_SIZE + x) * 4
      copy(pixels[i:i + 4], color[:])
    }
  }
  tex, tex_ok := render.texture_create(&app.renderer, pixels[:], {SPRITE_SIZE, SPRITE_SIZE})
  if !tex_ok do return .FAIL

  tints := TINTS
  for tint, i in tints {
    ok: bool
    app.materials[i], ok = render.material_create(
      &app.renderer,
      render.make_material(.SPRITE, albedo_texture = tex, base_color_factor = tint),
    )
    if !ok do return .FAIL
  }
  return .READY
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  app.fps += (1 / max(dt, 1e-4) - app.fps) * FPS_SMOOTHING

  size := platform.framebuffer_size(&app.platform)
  aspect := f32(size.x) / f32(max(size.y, 1))
  app.half = {VIEW_HEIGHT * aspect, VIEW_HEIGHT} / 2
  cam := render.main_camera(&app.renderer)
  cam.projection = render.OrthographicProjection{VIEW_HEIGHT}
  render.camera_look_at(cam, {0, 0, 10}, {0, 0, 0})

  if input.mouse_down(&app.input, .LEFT) && !app.input.mouse_captured {
    if ray, ok := render.cursor_ray(&app.renderer, app.input.cursor); ok {
      spawn(app, ray.origin.xy)
    }
  }
  limit := app.half - BUNNY_SIZE / 2
  for &b in app.bunnies {
    b.velocity.y -= GRAVITY * dt
    b.position += b.velocity * dt
    if b.position.x < -limit.x || b.position.x > limit.x {
      b.position.x = clamp(b.position.x, -limit.x, limit.x)
      b.velocity.x = -b.velocity.x
    }
    if b.position.y < -limit.y {
      b.position.y = -limit.y
      b.velocity.y = -b.velocity.y * BOUNCE_DAMPING
      if rand.float32() < 0.1 do b.velocity.y += rand.float32_range(2, 8)
    } else if b.position.y > limit.y {
      b.position.y = limit.y
      b.velocity.y = 0
    }
    world.translate(&app.scene, b.node, {b.position.x, b.position.y, 0})
  }
  mjolnir.update(&app.scene, &app.renderer, dt)
}

spawn :: proc(app: ^App, at: [2]f32) {
  for _ in 0 ..< SPAWN_PER_TICK {
    node, ok := world.spawn(&app.scene, {at.x, at.y, 0})
    if !ok do return
    material := app.materials[rand.int_max(len(app.materials))]
    render.attach(&app.renderer, node, render.primitive(&app.renderer, .QUAD_XY, material, cast_shadow = false))
    world.scale(&app.scene, node, BUNNY_SIZE)
    append(
      &app.bunnies,
      Bunny{node = node, position = at, velocity = {rand.float32_range(-SPAWN_SPEED, SPAWN_SPEED), rand.float32_range(0, SPAWN_SPEED)}},
    )
  }
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "Bunnymark", {20, 20, 200, 120}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Bunnies %d", len(app.bunnies)))
    mu.label(ctx, fmt.tprintf("FPS %.0f", app.fps))
    if .SUBMIT in mu.button(ctx, "Clear") {
      for b in app.bunnies do world.destroy(&app.scene, b.node)
      clear(&app.bunnies)
    }
  }
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}
