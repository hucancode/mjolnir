// Snake game in 3D.
package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "mjolnir"
import "mjolnir/audio"
import "mjolnir/font"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

GRID :: 15
CELL :: 1.0
TICK :: 0.18

SEGMENT_SCALE :: 0.45 * CELL
FOOD_SCALE :: 0.4 * CELL
SEGMENT_Y :: SEGMENT_SCALE
FOOD_Y :: FOOD_SCALE

SAMPLE_RATE :: 48000
eat_samples: [SAMPLE_RATE / 8]f32
crash_samples: [SAMPLE_RATE * 2 / 5]f32

Cell :: [2]i32

Game :: struct {
  body:        [dynamic]Cell,
  head_node:   world.NodeHandle,
  body_nodes:  [dynamic]world.NodeHandle,
  dir:         Cell,
  pending_dir: Cell,
  food:        Cell,
  food_node:   world.NodeHandle,
  timer:       f32,
  score:       int,
  best:        int,
  alive:       bool,
}

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  font:     font.Font,
  orbit:    render.Orbit,
  mixer:    audio.Audio,
  eat:      audio.Sound,
  crash:    audio.Sound,
  game:     Game,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Snake 3D") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
  if !audio.init(&app.mixer) do return
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
  delete(app.game.body)
  delete(app.game.body_nodes)
  font.destroy(&app.font)
  audio.shutdown(&app.mixer)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

draw_hud :: proc(app: ^App) {
  hud := [?]render.OverlayCommand {
    {shape = render.OverlayText{text = fmt.tprintf("Score: %d", app.game.score), position = {20, 20}, size = 28, color = {255, 255, 255, 255}}},
    {shape = render.OverlayText{text = fmt.tprintf("Best: %d", app.game.best), position = {20, 60}, size = 24, color = {255, 220, 100, 255}}},
  }
  render.stage_overlay(&app.renderer, hud[:], &app.font)
}

spawn_primitive :: proc(app: ^App, shape: render.Primitive, color: render.Color, pos: [3]f32 = {}) -> world.NodeHandle {
  return mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, shape, color), pos)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  if !font.init(&app.font, #load("assets/Outfit-Regular.ttf")) do return .FAIL
  app.renderer.skybox_intensity = 0
  half := f32(GRID) * CELL * 0.5
  wall_t :: 0.2
  wall_h :: 0.5

  floor := spawn_primitive(app, .CUBE, .GRAY, {0, -0.5, 0})
  world.transform(&app.scene, floor).scale = {half, 0.5, half}

  spawn_wall(app, {0, wall_h, half + wall_t}, half + wall_t * 2, wall_h, wall_t)
  spawn_wall(app, {0, wall_h, -(half + wall_t)}, half + wall_t * 2, wall_h, wall_t)
  spawn_wall(app, {half + wall_t, wall_h, 0}, wall_t, wall_h, half + wall_t * 2)
  spawn_wall(app, {-(half + wall_t), wall_h, 0}, wall_t, wall_h, half + wall_t * 2)

  app.orbit = render.make_orbit({0, 12, 3}, {0, 0, 0})

  app.game.head_node = spawn_primitive(app, .CUBE, .YELLOW)
  world.transform(&app.scene, app.game.head_node).scale = SEGMENT_SCALE
  app.game.food_node = spawn_primitive(app, .SPHERE, .RED)
  world.transform(&app.scene, app.game.food_node).scale = FOOD_SCALE

  sweep(eat_samples[:], 600, 1200)
  sweep(crash_samples[:], 220, 55)
  app.eat = audio.sound_create(&app.mixer, eat_samples[:], 1, SAMPLE_RATE)
  app.crash = audio.sound_create(&app.mixer, crash_samples[:], 1, SAMPLE_RATE)

  reset_game(app)
  log.info("Controls: WASD or arrows. Auto-restart on game over.")
  return .READY
}

sweep :: proc(samples: []f32, from, to: f32) {
  phase: f32
  for &s, i in samples {
    t := f32(i) / f32(len(samples))
    phase += math.TAU * math.lerp(from, to, t) / SAMPLE_RATE
    s = 0.3 * math.sin(phase) * (1 - t)
  }
}

spawn_wall :: proc(app: ^App, pos: [3]f32, sx, sy, sz: f32) {
  h := spawn_primitive(app, .CUBE, .WHITE, pos)
  world.transform(&app.scene, h).scale = {sx, sy, sz}
}

reset_game :: proc(app: ^App) {
  for h in app.game.body_nodes do world.destroy(&app.scene, h)
  clear(&app.game.body_nodes); clear(&app.game.body)

  mid: i32 = GRID / 2
  append(&app.game.body, Cell{mid, mid})
  append(&app.game.body, Cell{mid - 1, mid})
  append(&app.game.body, Cell{mid - 2, mid})
  for i in 1 ..< len(app.game.body) {
    append(&app.game.body_nodes, spawn_body_node(app, app.game.body[i]))
  }
  place_node(app, app.game.head_node, app.game.body[0], SEGMENT_Y)

  app.game.dir = {1, 0}; app.game.pending_dir = {1, 0}
  app.game.timer = 0; app.game.score = 0; app.game.alive = true

  place_food(app)
}

spawn_body_node :: proc(app: ^App, c: Cell) -> world.NodeHandle {
  h := spawn_primitive(app, .CUBE, .GREEN, cell_to_world(c, SEGMENT_Y))
  world.transform(&app.scene, h).scale = SEGMENT_SCALE
  return h
}

place_node :: proc(app: ^App, h: world.NodeHandle, c: Cell, y: f32) {
  world.transform(&app.scene, h).position = cell_to_world(c, y)
}

place_food :: proc(app: ^App) {
  for {
    c := Cell{i32(rand.int31_max(GRID)), i32(rand.int31_max(GRID))}
    occupied := false
    for b in app.game.body do if b == c { occupied = true; break }
    if !occupied { app.game.food = c; break }
  }
  place_node(app, app.game.food_node, app.game.food, FOOD_Y)
}

cell_to_world :: proc(c: Cell, y: f32) -> [3]f32 {
  half := f32(GRID) * CELL * 0.5
  x := (f32(c.x) + 0.5) * CELL - half
  z := (f32(c.y) + 0.5) * CELL - half
  return {x, y, z}
}

on_key :: proc(app: ^App, key: input.Key) {
  #partial switch key {
  case .W, .UP:    if app.game.dir.y != 1  do app.game.pending_dir = {0, -1}
  case .S, .DOWN:  if app.game.dir.y != -1 do app.game.pending_dir = {0, 1}
  case .A, .LEFT:  if app.game.dir.x != 1  do app.game.pending_dir = {-1, 0}
  case .D, .RIGHT: if app.game.dir.x != -1 do app.game.pending_dir = {1, 0}
  }
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input, rotate_with = {})
  step_game(app, dt)
  draw_hud(app)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

step_game :: proc(app: ^App, dt: f32) {
  if !app.input.keyboard_captured {
    it := 0
    for key, pressed in input.next_key_edge(&app.input, &it) do if pressed do on_key(app, key)
  }
  app.game.timer += dt
  if app.game.timer < TICK do return
  app.game.timer = 0

  if !app.game.alive {
    if app.game.score > app.game.best do app.game.best = app.game.score
    reset_game(app)
    return
  }

  app.game.dir = app.game.pending_dir
  head := app.game.body[0]
  next := Cell{head.x + app.game.dir.x, head.y + app.game.dir.y}

  ate := next == app.game.food
  limit := len(app.game.body) if ate else len(app.game.body) - 1
  hit := next.x < 0 || next.x >= GRID || next.y < 0 || next.y >= GRID
  for i in 0 ..< limit do hit ||= app.game.body[i] == next
  if hit {
    app.game.alive = false
    audio.play(&app.mixer, app.crash)
    return
  }

  old_head := app.game.body[0]
  if ate {
    new_node := spawn_body_node(app, old_head)
    inject_at(&app.game.body_nodes, 0, new_node)
    inject_at(&app.game.body, 0, next)
    app.game.score += 1
    audio.play(&app.mixer, app.eat, pitch = 1 + 0.03 * f32(app.game.score))
    place_food(app)
  } else if len(app.game.body_nodes) > 0 {
    tail_node := pop(&app.game.body_nodes)
    place_node(app, tail_node, old_head, SEGMENT_Y)
    inject_at(&app.game.body_nodes, 0, tail_node)
    pop(&app.game.body)
    inject_at(&app.game.body, 0, next)
  } else {
    app.game.body[0] = next
  }
  place_node(app, app.game.head_node, next, SEGMENT_Y)
}
