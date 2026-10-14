// Snake game in 3D.
package main

import "../../mjolnir"
import "../../mjolnir/font"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:os"

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
}

g: Game

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  font:     font.Font,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 1024, 768, "Snake 3D") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Snake 3D", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  font_data, err := os.read_entire_file("assets/Outfit-Regular.ttf", context.allocator)
  if err != nil do return
  defer delete(font_data)
  if !font.init(&app.font, font_data) do return
  defer font.destroy(&app.font)
  setup(app)
  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  // score labels: glyph runs of the font, drawn by render's 2D overlay
  commands := make([dynamic]render.RenderCommand, context.temp_allocator)
  label(app, &commands, fmt.tprintf("Score: %d", g.score), {20, 20}, 28, {255, 255, 255, 255})
  label(app, &commands, fmt.tprintf("Best: %d", g.best), {20, 60}, 24, {255, 220, 100, 255})
  pixels, size, changed := font.atlas(&app.font)
  render.stage_overlay(&app.renderer, {commands = commands[:], atlas = pixels if changed else nil, atlas_size = size})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

spawn_primitive :: proc(app: ^App, shape: render.Primitive, color: render.Color, pos: [3]f32 = {}) -> world.NodeHandle {
  n := world.spawn(&app.scene, pos)
  render.attach(&app.renderer, n.index, render.primitive(&app.renderer, shape, color))
  return n
}

setup :: proc(app: ^App) {
  half := f32(GRID) * CELL * 0.5
  wall_t :: 0.2
  wall_h :: 0.5

  floor := spawn_primitive(app, .CUBE, .GRAY, {0, -0.5, 0})
  world.scale_xyz(&app.scene, floor, half, 0.5, half)

  spawn_wall(app, {0, wall_h, half + wall_t}, half + wall_t * 2, wall_h, wall_t)
  spawn_wall(app, {0, wall_h, -(half + wall_t)}, half + wall_t * 2, wall_h, wall_t)
  spawn_wall(app, {half + wall_t, wall_h, 0}, wall_t, wall_h, half + wall_t * 2)
  spawn_wall(app, {-(half + wall_t), wall_h, 0}, wall_t, wall_h, half + wall_t * 2)

  render.main_camera_look_at(&app.renderer, {0, 18, 13}, {0, 0, 0})

  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))

  spot := world.spawn(&app.scene, {0, 10, 4})
  render.attach(&app.renderer, spot.index, render.spot_light_attachment({0.2, 0.95, 0.85, 1.0}, 12.0, math.PI * 0.35, true))
  world.rotate(&app.scene, spot, math.PI * 0.55, linalg.VECTOR3F32_X_AXIS)


  g.head_node = spawn_primitive(app, .CUBE, .YELLOW)
  world.scale(&app.scene, g.head_node, SEGMENT_SCALE)
  g.food_node = spawn_primitive(app, .SPHERE, .RED)
  world.scale(&app.scene, g.food_node, FOOD_SCALE)

  reset_game(app)
  log.info("Controls: WASD or arrows. Auto-restart on game over.")
}

spawn_wall :: proc(app: ^App, pos: [3]f32, sx, sy, sz: f32) {
  h := spawn_primitive(app, .CUBE, .WHITE, pos)
  world.scale_xyz(&app.scene, h, sx, sy, sz)
}

reset_game :: proc(app: ^App) {
  for h in g.body_nodes do world.despawn(&app.scene, h)
  clear(&g.body_nodes); clear(&g.body)

  mid: i32 = GRID / 2
  append(&g.body, Cell{mid, mid})
  append(&g.body, Cell{mid - 1, mid})
  append(&g.body, Cell{mid - 2, mid})
  for i in 1 ..< len(g.body) {
    append(&g.body_nodes, spawn_body_node(app, g.body[i]))
  }
  place_node(app, g.head_node, g.body[0], SEGMENT_Y)

  g.dir = {1, 0}; g.pending_dir = {1, 0}
  g.timer = 0; g.score = 0; g.alive = true

  place_food(app)
}

spawn_body_node :: proc(app: ^App, c: Cell) -> world.NodeHandle {
  h := spawn_primitive(app, .CUBE, .GREEN, cell_to_world(c, SEGMENT_Y))
  world.scale(&app.scene, h, SEGMENT_SCALE)
  return h
}

place_node :: proc(app: ^App, h: world.NodeHandle, c: Cell, y: f32) {
  world.translate(&app.scene, h, cell_to_world(c, y))
}

place_food :: proc(app: ^App) {
  for {
    c := Cell{i32(rand.int31_max(GRID)), i32(rand.int31_max(GRID))}
    occupied := false
    for b in g.body do if b == c { occupied = true; break }
    if !occupied { g.food = c; break }
  }
  place_node(app, g.food_node, g.food, FOOD_Y)
}

cell_to_world :: proc(c: Cell, y: f32) -> [3]f32 {
  half := f32(GRID) * CELL * 0.5
  x := (f32(c.x) + 0.5) * CELL - half
  z := (f32(c.y) + 0.5) * CELL - half
  return {x, y, z}
}

on_key :: proc(key: input.Key) {
  #partial switch key {
  case .W, .UP:    if g.dir.y != 1  do g.pending_dir = {0, -1}
  case .S, .DOWN:  if g.dir.y != -1 do g.pending_dir = {0, 1}
  case .A, .LEFT:  if g.dir.x != 1  do g.pending_dir = {-1, 0}
  case .D, .RIGHT: if g.dir.x != -1 do g.pending_dir = {1, 0}
  }
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured do app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  render.main_camera_orbit(&app.renderer, app.yaw, app.pitch, app.dist)
  step_game(app, dt)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

step_game :: proc(app: ^App, dt: f32) {
  if !app.input.keyboard_captured {
    it := 0
    for key, pressed in input.next_key_edge(&app.input, &it) do if pressed do on_key(key)
  }
  g.timer += dt
  if g.timer < TICK do return
  g.timer = 0

  if !g.alive {
    if g.score > g.best do g.best = g.score
    reset_game(app)
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
    new_node := spawn_body_node(app, old_head)
    inject_at(&g.body_nodes, 0, new_node)
    inject_at(&g.body, 0, next)
    g.score += 1
    place_food(app)
  } else if len(g.body_nodes) > 0 {
    tail_node := pop(&g.body_nodes)
    place_node(app, tail_node, old_head, SEGMENT_Y)
    inject_at(&g.body_nodes, 0, tail_node)
    pop(&g.body)
    inject_at(&g.body, 0, next)
  } else {
    g.body[0] = next
  }
  place_node(app, g.head_node, next, SEGMENT_Y)
}

label :: proc(app: ^App, commands: ^[dynamic]render.RenderCommand, text: string, pos: [2]f32, size: f32, color: [4]u8) {
  glyphs := make([dynamic]font.Glyph, context.temp_allocator)
  font.glyphs(&app.font, text, pos, size, &glyphs)
  append(commands, render.RenderCommand{shape = render.DrawTextCommand{glyphs = glyphs[:], color = color}})
}
