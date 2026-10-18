// Tetris in 3D.
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
import "core:math/rand"

GRID_W :: 20
GRID_H :: 20
PIECE_LEN :: 4
CELL :: f32(1.0)
RADIUS :: f32(GRID_W) * CELL / (2.0 * math.PI)
FALL_PERIOD :: f32(0.6)
SOFT_FALL_PERIOD :: f32(0.05)

Piece :: struct {
  cells: [PIECE_LEN][2]i32,
  color: render.Color,
}

PIECES := [?]Piece {
  {cells = {{-1, 0}, {0, 0}, {1, 0}, {2, 0}}, color = .CYAN},
  {cells = {{0, 0}, {1, 0}, {0, 1}, {1, 1}}, color = .YELLOW},
  {cells = {{-1, 0}, {0, 0}, {1, 0}, {0, 1}}, color = .MAGENTA},
  {cells = {{-1, 0}, {0, 0}, {0, 1}, {1, 1}}, color = .GREEN},
  {cells = {{1, 0}, {2, 0}, {0, 1}, {1, 1}}, color = .RED},
  {cells = {{-1, 0}, {0, 0}, {1, 0}, {-1, 1}}, color = .BLUE},
  {cells = {{-1, 0}, {0, 0}, {1, 0}, {1, 1}}, color = .WHITE},
}

State :: struct {
  board:                [GRID_W][GRID_H]world.NodeHandle,
  occupied:             [GRID_W][GRID_H]bool,
  active_cells:         [PIECE_LEN]world.NodeHandle,
  active_piece:         Piece,
  active_pos:           [2]i32,
  fall_timer:           f32,
  fall_period:          f32,
  score:                u32,
  high_score:           u32,
  game_over:            bool,
  has_active:           bool,
  transparent_material: [len(render.Color)]render.MaterialHandle,
  opaque_material:      [len(render.Color)]render.MaterialHandle,
}

PIECE_ALPHA :: f32(0.5)

COLOR_RGB := [len(render.Color)][3]f32 {
  {1, 1, 1}, {0, 0, 0}, {0.3, 0.3, 0.3},
  {1, 0, 0}, {0, 1, 0}, {0, 0, 1},
  {1, 1, 0}, {0, 1, 1}, {1, 0, 1},
}

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  font:     font.Font,
  orbit:    render.Orbit,
  state:    State,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1024, 768, "Torus Tetris") do return
  if !render.init(&app.renderer, "Torus Tetris", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  font.destroy(&app.font)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  hud := [?]render.RenderCommand {
    {shape = render.DrawTextCommand{text = fmt.tprintf("Score: %d", app.state.score), position = {20, 20}, size = 32, color = {255, 255, 255, 255}}},
    {shape = render.DrawTextCommand{text = fmt.tprintf("High: %d", app.state.high_score), position = {20, 60}, size = 24, color = {255, 220, 100, 255}}},
  }
  render.stage_overlay(&app.renderer, hud[:], &app.font)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

wrap_col :: proc(c: i32) -> i32 { return c %% GRID_W }
col_angle :: proc(col: i32) -> f32 { return (f32(col) + 0.5) / f32(GRID_W) * 2.0 * math.PI }
cell_world_pos :: proc(col: i32, row: i32) -> [3]f32 {
  a := col_angle(col)
  return {RADIUS * math.cos(a), f32(row) * CELL + 0.5 * CELL, RADIUS * math.sin(a)}
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !font.init(&app.font, #load("../../assets/Outfit-Regular.ttf")) do return .FAIL
  ground := app.renderer.builtin_meshes[.QUAD_XZ]
  dark_mat := render.material_create(&app.renderer, render.make_material(type = .PBR, base_color_factor = {0.05, 0.05, 0.06, 1.0}))
  floor := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(floor.index), render.MeshAttachment{mesh = ground, material = dark_mat, cast_shadow = false})
  world.scale(&app.scene, floor, RADIUS * 6.0)
  spot := world.spawn(&app.scene, {0, 10, 0})
  render.attach(&app.renderer, render.SlotHandle(spot.index), render.light_create(&app.renderer, render.make_spot_light({1, 1, 1}, 500, 16.0, math.PI * 0.35)))
  world.rotate(&app.scene, spot, math.PI * 0.55, {1, 0, 0})
  render.camera_look_at(render.main_camera(&app.renderer), {0, 14, 14}, {0, 8, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 8, 0})
  for c, i in COLOR_RGB {
    app.state.transparent_material[i] = render.material_create(&app.renderer, render.make_material(type = .TRANSPARENT, base_color_factor = {c.x, c.y, c.z, PIECE_ALPHA}))
    app.state.opaque_material[i] = render.material_create(&app.renderer, render.make_material(type = .PBR, base_color_factor = {c.x, c.y, c.z, 1.0}))
  }
  app.state.fall_period = FALL_PERIOD
  reset_game(app)
  return .READY
}

reset_game :: proc(app: ^App) {
  for col in 0 ..< GRID_W do for row in 0 ..< GRID_H do if app.state.occupied[col][row] {
    world.destroy(&app.scene, app.state.board[col][row])
    app.state.board[col][row] = {}; app.state.occupied[col][row] = false
  }
  if app.state.has_active {
    for h in app.state.active_cells do world.destroy(&app.scene, h)
    app.state.has_active = false
  }
  app.state.score = 0; app.state.fall_timer = 0
  app.state.fall_period = FALL_PERIOD; app.state.game_over = false
  spawn_piece(app)
}

spawn_piece :: proc(app: ^App) {
  app.state.active_piece = rand.choice(PIECES[:])
  max_dr := i32(0)
  for c in app.state.active_piece.cells do if c[1] > max_dr do max_dr = c[1]
  app.state.active_pos = {0, i32(GRID_H) - 1 - max_dr}
  if collides(app, app.state.active_piece, app.state.active_pos) { app.state.game_over = true; return }
  cube := app.renderer.builtin_meshes[.CUBE]
  mat := app.state.transparent_material[app.state.active_piece.color]
  for i in 0 ..< PIECE_LEN {
    h := world.spawn(&app.scene)
    render.attach(&app.renderer, render.SlotHandle(h.index), render.MeshAttachment{mesh = cube, material = mat, cast_shadow = true})
    app.state.active_cells[i] = h
    world.scale(&app.scene, h, 0.5 * CELL)
  }
  app.state.has_active = true
  refresh_active_visuals(app)
}

collides :: proc(app: ^App, piece: Piece, pos: [2]i32) -> bool {
  for c in piece.cells {
    col := wrap_col(pos[0] + c[0])
    row := pos[1] + c[1]
    if row < 0 || row >= GRID_H do return true
    if app.state.occupied[col][row] do return true
  }
  return false
}

refresh_active_visuals :: proc(app: ^App) {
  for c, i in app.state.active_piece.cells {
    col := wrap_col(app.state.active_pos[0] + c[0])
    row := app.state.active_pos[1] + c[1]
    world.translate(&app.scene, app.state.active_cells[i], cell_world_pos(col, row))
    world.rotate(&app.scene, app.state.active_cells[i], -col_angle(col), {0, 1, 0})
  }
}

try_move :: proc(app: ^App, dcol, drow: i32) -> bool {
  np := [2]i32{app.state.active_pos[0] + dcol, app.state.active_pos[1] + drow}
  if collides(app, app.state.active_piece, np) do return false
  app.state.active_pos = np
  refresh_active_visuals(app)
  return true
}

try_rotate :: proc(app: ^App) -> bool {
  rotated := app.state.active_piece
  for &c in rotated.cells { c = {c[1], -c[0]} }
  if collides(app, rotated, app.state.active_pos) do return false
  app.state.active_piece = rotated
  refresh_active_visuals(app)
  return true
}

lock_piece :: proc(app: ^App) {
  opaque := app.state.opaque_material[app.state.active_piece.color]
  for c, i in app.state.active_piece.cells {
    col := wrap_col(app.state.active_pos[0] + c[0])
    row := app.state.active_pos[1] + c[1]
    app.state.board[col][row] = app.state.active_cells[i]
    app.state.occupied[col][row] = true
    render.attach(&app.renderer, render.SlotHandle(app.state.active_cells[i].index), render.MeshAttachment{mesh = app.renderer.builtin_meshes[.CUBE], material = opaque, cast_shadow = true})
  }
  app.state.has_active = false
  cleared := clear_lines(app)
  if cleared > 0 do app.state.score += u32(cleared * cleared * 100)
}

clear_lines :: proc(app: ^App) -> int {
  cleared := 0
  r := 0
  for r < GRID_H {
    full := true
    for col in 0 ..< GRID_W do if !app.state.occupied[col][r] { full = false; break }
    if !full { r += 1; continue }
    for col in 0 ..< GRID_W {
      world.destroy(&app.scene, app.state.board[col][r])
      app.state.board[col][r] = {}; app.state.occupied[col][r] = false
    }
    for r2 := r; r2 < GRID_H - 1; r2 += 1 {
      for col in 0 ..< GRID_W {
        app.state.board[col][r2] = app.state.board[col][r2 + 1]
        app.state.occupied[col][r2] = app.state.occupied[col][r2 + 1]
        if app.state.occupied[col][r2] do world.translate(&app.scene, app.state.board[col][r2], cell_world_pos(i32(col), i32(r2)))
      }
    }
    for col in 0 ..< GRID_W { app.state.board[col][GRID_H - 1] = {}; app.state.occupied[col][GRID_H - 1] = false }
    cleared += 1
  }
  return cleared
}

drop_step :: proc(app: ^App) {
  if try_move(app, 0, -1) do return
  lock_piece(app)
  spawn_piece(app)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  step_game(app, dt)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

step_game :: proc(app: ^App, dt: f32) {
  if !app.input.keyboard_captured {
    it := 0
    for key, pressed in input.next_key_edge(&app.input, &it) do if pressed do on_key(app, key)
  }
  if app.state.game_over {
    if app.state.score > app.state.high_score do app.state.high_score = app.state.score
    log.infof("game over - score %d high %d - restarting", app.state.score, app.state.high_score)
    reset_game(app)
    return
  }
  app.state.fall_timer += dt
  period := app.state.fall_period
  if !app.input.keyboard_captured && input.key_down(&app.input, .DOWN) do period = SOFT_FALL_PERIOD
  for app.state.fall_timer >= period {
    app.state.fall_timer -= period
    drop_step(app)
    if app.state.game_over do return
  }
}

on_key :: proc(app: ^App, key: input.Key) {
  if app.state.game_over do return
  #partial switch key {
  case .LEFT:  try_move(app, 1, 0)
  case .RIGHT: try_move(app, -1, 0)
  case .UP:    try_rotate(app)
  case .SPACE:
    for try_move(app, 0, -1) {}
    app.state.fall_timer = app.state.fall_period
  }
}

