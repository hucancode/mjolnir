package main

import "../../mjolnir"
import "../../mjolnir/ui"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "vendor:glfw"

GRID :: 15
CELL :: 1.0
TICK :: 0.18

SEGMENT_SCALE :: 0.45 * CELL
FOOD_SCALE :: 0.4 * CELL
SEGMENT_Y :: SEGMENT_SCALE
FOOD_Y :: FOOD_SCALE

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
  score_label: ui.Text2DHandle,
  best_label:  ui.Text2DHandle,
}

g: Game

main :: proc() {
  mjolnir.run_app({
    title     = "Snake 3D",
    width     = 1024,
    height    = 768,
    setup     = setup,
    update    = update,
    key_press = on_key,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  half := f32(GRID) * CELL * 0.5
  wall_t :: 0.2
  wall_h :: 0.5

  floor := world.spawn_primitive_mesh(&engine.world, .CUBE, .GRAY, {0, -0.5, 0})
  world.scale_xyz(&engine.world, floor, half, 0.5, half)

  spawn_wall(engine, {0, wall_h, half + wall_t}, half + wall_t * 2, wall_h, wall_t)
  spawn_wall(engine, {0, wall_h, -(half + wall_t)}, half + wall_t * 2, wall_h, wall_t)
  spawn_wall(engine, {half + wall_t, wall_h, 0}, wall_t, wall_h, half + wall_t * 2)
  spawn_wall(engine, {-(half + wall_t), wall_h, 0}, wall_t, wall_h, half + wall_t * 2)

  world.main_camera_look_at(&engine.world, {0, 18, 13}, {0, 0, 0})

  spot := world.spawn_light_spot(&engine.world, {0, 10, 4}, {0.2, 0.95, 0.85, 1.0}, 12.0, math.PI * 0.35, true)
  world.rotate(&engine.world, spot, math.PI * 0.55, linalg.VECTOR3F32_X_AXIS)

  g.score_label, _ = ui.create_text2d(&engine.ui, position = {20, 20}, text = "Score: 0", font_size = 28, color = {255, 255, 255, 255})
  g.best_label, _  = ui.create_text2d(&engine.ui, position = {20, 60}, text = "Best: 0",  font_size = 24, color = {255, 220, 100, 255})

  g.head_node = world.spawn_primitive_mesh(&engine.world, .CUBE, .YELLOW)
  world.scale(&engine.world, g.head_node, SEGMENT_SCALE)
  g.food_node = world.spawn_primitive_mesh(&engine.world, .SPHERE, .RED)
  world.scale(&engine.world, g.food_node, FOOD_SCALE)

  reset_game(engine)
  log.info("Controls: WASD or arrows. Auto-restart on game over.")
}

spawn_wall :: proc(engine: ^mjolnir.Engine, pos: [3]f32, sx, sy, sz: f32) {
  h := world.spawn_primitive_mesh(&engine.world, .CUBE, .WHITE, pos)
  world.scale_xyz(&engine.world, h, sx, sy, sz)
}

reset_game :: proc(engine: ^mjolnir.Engine) {
  for h in g.body_nodes do world.despawn(&engine.world, h)
  clear(&g.body_nodes); clear(&g.body)

  mid: i32 = GRID / 2
  append(&g.body, Cell{mid, mid})
  append(&g.body, Cell{mid - 1, mid})
  append(&g.body, Cell{mid - 2, mid})
  for i in 1 ..< len(g.body) {
    append(&g.body_nodes, spawn_body_node(engine, g.body[i]))
  }
  place_node(engine, g.head_node, g.body[0], SEGMENT_Y)

  g.dir = {1, 0}; g.pending_dir = {1, 0}
  g.timer = 0; g.score = 0; g.alive = true

  place_food(engine)
  refresh_score_ui(engine)
}

spawn_body_node :: proc(engine: ^mjolnir.Engine, c: Cell) -> world.NodeHandle {
  h := world.spawn_primitive_mesh(&engine.world, .CUBE, .GREEN, cell_to_world(c, SEGMENT_Y))
  world.scale(&engine.world, h, SEGMENT_SCALE)
  return h
}

place_node :: proc(engine: ^mjolnir.Engine, h: world.NodeHandle, c: Cell, y: f32) {
  world.translate(&engine.world, h, cell_to_world(c, y))
}

place_food :: proc(engine: ^mjolnir.Engine) {
  for {
    c := Cell{i32(rand.int31_max(GRID)), i32(rand.int31_max(GRID))}
    occupied := false
    for b in g.body do if b == c { occupied = true; break }
    if !occupied { g.food = c; break }
  }
  place_node(engine, g.food_node, g.food, FOOD_Y)
}

cell_to_world :: proc(c: Cell, y: f32) -> [3]f32 {
  half := f32(GRID) * CELL * 0.5
  x := (f32(c.x) + 0.5) * CELL - half
  z := (f32(c.y) + 0.5) * CELL - half
  return {x, y, z}
}

on_key :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
  if action == glfw.RELEASE do return
  switch key {
  case glfw.KEY_W, glfw.KEY_UP:    if g.dir.y != 1  do g.pending_dir = {0, -1}
  case glfw.KEY_S, glfw.KEY_DOWN:  if g.dir.y != -1 do g.pending_dir = {0, 1}
  case glfw.KEY_A, glfw.KEY_LEFT:  if g.dir.x != 1  do g.pending_dir = {-1, 0}
  case glfw.KEY_D, glfw.KEY_RIGHT: if g.dir.x != -1 do g.pending_dir = {1, 0}
  }
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  g.timer += dt
  if g.timer < TICK do return
  g.timer = 0

  if !g.alive {
    if g.score > g.best do g.best = g.score
    reset_game(engine)
    return
  }

  g.dir = g.pending_dir
  head := g.body[0]
  next := Cell{head.x + g.dir.x, head.y + g.dir.y}

  if next.x < 0 || next.x >= GRID || next.y < 0 || next.y >= GRID {
    g.alive = false; return
  }
  ate := next == g.food
  limit := len(g.body) if ate else len(g.body) - 1
  for i in 0 ..< limit do if g.body[i] == next { g.alive = false; return }

  old_head := g.body[0]
  if ate {
    new_node := spawn_body_node(engine, old_head)
    inject_at(&g.body_nodes, 0, new_node)
    inject_at(&g.body, 0, next)
    g.score += 1
    place_food(engine)
    refresh_score_ui(engine)
  } else if len(g.body_nodes) > 0 {
    tail_node := pop(&g.body_nodes)
    place_node(engine, tail_node, old_head, SEGMENT_Y)
    inject_at(&g.body_nodes, 0, tail_node)
    pop(&g.body)
    inject_at(&g.body, 0, next)
  } else {
    g.body[0] = next
  }
  place_node(engine, g.head_node, next, SEGMENT_Y)
}

refresh_score_ui :: proc(engine: ^mjolnir.Engine) {
  ui.set_text(&engine.ui, g.score_label, fmt.tprintf("Score: %d", g.score))
  ui.set_text(&engine.ui, g.best_label,  fmt.tprintf("Best: %d",  g.best))
}
