package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/ui"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:os"

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
  score_label:          ui.Text2DHandle,
  high_label:           ui.Text2DHandle,
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
  renderer: render.Manager,
  camera:   render.CameraController,
  input:    input.State,
  gui:      ui.System,
}

state: State

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 1024, 768, "Torus Tetris") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Torus Tetris", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  app.camera = render.orbit_controller()
  font, err := os.read_entire_file("assets/Outfit-Regular.ttf", context.allocator)
  if err != nil do return
  defer delete(font)
  if !ui.init(&app.gui, font) do return
  defer ui.shutdown(&app.gui)
  setup(app)
  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  render.stage_ui(&app.renderer, ui.draw_list(&app.gui))
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

wrap_col :: proc(c: i32) -> i32 { return c %% GRID_W }
col_angle :: proc(col: i32) -> f32 { return (f32(col) + 0.5) / f32(GRID_W) * 2.0 * math.PI }
cell_world_pos :: proc(col: i32, row: i32) -> [3]f32 {
  a := col_angle(col)
  return {RADIUS * math.cos(a), f32(row) * CELL + 0.5 * CELL, RADIUS * math.sin(a)}
}

setup :: proc(app: ^App) {
  ground := app.renderer.builtin_meshes[.QUAD_XZ]
  dark_mat := render.create_material(&app.renderer, type = .PBR, base_color_factor = {0.05, 0.05, 0.06, 1.0})
  floor := world.spawn(&app.scene)
  render.attach(&app.renderer, floor.index, render.MeshAttachment{handle = ground, material = dark_mat, cast_shadow = false})
  world.scale(&app.scene, floor, RADIUS * 6.0)
  spot := world.spawn(&app.scene, {0, 10, 0})
  render.attach(&app.renderer, spot.index, render.spot_light_attachment({1, 1, 1, 1}, 12.0, math.PI * 0.35, true))
  world.rotate(&app.scene, spot, math.PI * 0.55, {1, 0, 0})
  render.main_camera_look_at(&app.renderer, {0, 14, 14}, {0, 8, 0})
  for c, i in COLOR_RGB {
    state.transparent_material[i] = render.create_material(&app.renderer, type = .TRANSPARENT, base_color_factor = {c.x, c.y, c.z, PIECE_ALPHA})
    state.opaque_material[i] = render.create_material(&app.renderer, type = .PBR, base_color_factor = {c.x, c.y, c.z, 1.0})
  }
  state.fall_period = FALL_PERIOD
  state.score_label, _ = ui.create_text2d(&app.gui, position = {20, 20}, text = "Score: 0", font_size = 32, color = {255, 255, 255, 255})
  state.high_label, _ = ui.create_text2d(&app.gui, position = {20, 60}, text = "High: 0", font_size = 24, color = {255, 220, 100, 255})
  reset_game(app)
  refresh_score_ui(app)
}

reset_game :: proc(app: ^App) {
  for col in 0 ..< GRID_W do for row in 0 ..< GRID_H do if state.occupied[col][row] {
    world.despawn(&app.scene, state.board[col][row])
    state.board[col][row] = {}; state.occupied[col][row] = false
  }
  if state.has_active {
    for h in state.active_cells do world.despawn(&app.scene, h)
    state.has_active = false
  }
  state.score = 0; state.fall_timer = 0
  state.fall_period = FALL_PERIOD; state.game_over = false
  spawn_piece(app)
}

spawn_piece :: proc(app: ^App) {
  state.active_piece = rand.choice(PIECES[:])
  max_dr := i32(0)
  for c in state.active_piece.cells do if c[1] > max_dr do max_dr = c[1]
  state.active_pos = {0, i32(GRID_H) - 1 - max_dr}
  if collides(state.active_piece, state.active_pos) { state.game_over = true; return }
  cube := app.renderer.builtin_meshes[.CUBE]
  mat := state.transparent_material[state.active_piece.color]
  for i in 0 ..< PIECE_LEN {
    h := world.spawn(&app.scene)
    render.attach(&app.renderer, h.index, render.MeshAttachment{handle = cube, material = mat, cast_shadow = true})
    state.active_cells[i] = h
    world.scale(&app.scene, h, 0.5 * CELL)
  }
  state.has_active = true
  refresh_active_visuals(app)
}

collides :: proc(piece: Piece, pos: [2]i32) -> bool {
  for c in piece.cells {
    col := wrap_col(pos[0] + c[0])
    row := pos[1] + c[1]
    if row < 0 || row >= GRID_H do return true
    if state.occupied[col][row] do return true
  }
  return false
}

refresh_active_visuals :: proc(app: ^App) {
  for c, i in state.active_piece.cells {
    col := wrap_col(state.active_pos[0] + c[0])
    row := state.active_pos[1] + c[1]
    world.translate(&app.scene, state.active_cells[i], cell_world_pos(col, row))
    world.rotate(&app.scene, state.active_cells[i], -col_angle(col), {0, 1, 0})
  }
}

try_move :: proc(app: ^App, dcol, drow: i32) -> bool {
  np := [2]i32{state.active_pos[0] + dcol, state.active_pos[1] + drow}
  if collides(state.active_piece, np) do return false
  state.active_pos = np
  refresh_active_visuals(app)
  return true
}

try_rotate :: proc(app: ^App) -> bool {
  rotated := state.active_piece
  for &c in rotated.cells { c = {c[1], -c[0]} }
  if collides(rotated, state.active_pos) do return false
  state.active_piece = rotated
  refresh_active_visuals(app)
  return true
}

lock_piece :: proc(app: ^App) {
  opaque := state.opaque_material[state.active_piece.color]
  for c, i in state.active_piece.cells {
    col := wrap_col(state.active_pos[0] + c[0])
    row := state.active_pos[1] + c[1]
    state.board[col][row] = state.active_cells[i]
    state.occupied[col][row] = true
    if a, ok := render.attachment(&app.renderer, state.active_cells[i].index, render.MeshAttachment); ok {
      a.material = opaque
      render.attach(&app.renderer, state.active_cells[i].index, a)
    }
  }
  state.has_active = false
  cleared := clear_lines(app)
  if cleared > 0 do state.score += u32(cleared * cleared * 100)
}

clear_lines :: proc(app: ^App) -> int {
  cleared := 0
  r := 0
  for r < GRID_H {
    full := true
    for col in 0 ..< GRID_W do if !state.occupied[col][r] { full = false; break }
    if !full { r += 1; continue }
    for col in 0 ..< GRID_W {
      world.despawn(&app.scene, state.board[col][r])
      state.board[col][r] = {}; state.occupied[col][r] = false
    }
    for r2 := r; r2 < GRID_H - 1; r2 += 1 {
      for col in 0 ..< GRID_W {
        state.board[col][r2] = state.board[col][r2 + 1]
        state.occupied[col][r2] = state.occupied[col][r2 + 1]
        if state.occupied[col][r2] do world.translate(&app.scene, state.board[col][r2], cell_world_pos(i32(col), i32(r2)))
      }
    }
    for col in 0 ..< GRID_W { state.board[col][GRID_H - 1] = {}; state.occupied[col][GRID_H - 1] = false }
    cleared += 1
  }
  return cleared
}

drop_step :: proc(app: ^App) {
  if try_move(app, 0, -1) do return
  lock_piece(app)
  spawn_piece(app)
  refresh_score_ui(app)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  ui.process_input(&app.gui, &app.input)
  render.camera_controller_update(&app.camera, &app.renderer, &app.input, dt)
  step_game(app, dt)
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  for n in world.changed_nodes(&app.scene) do render.stage_transform(&app.renderer, n.index, n.world_matrix, n.visible)
  render.update(&app.renderer, dt)
}

step_game :: proc(app: ^App, dt: f32) {
  if !app.input.keyboard_captured {
    it := 0
    for key, pressed in input.next_key_edge(&app.input, &it) do if pressed do on_key(app, key)
  }
  if state.game_over {
    if state.score > state.high_score do state.high_score = state.score
    log.infof("game over - score %d high %d - restarting", state.score, state.high_score)
    reset_game(app)
    refresh_score_ui(app)
    return
  }
  state.fall_timer += dt
  period := state.fall_period
  if !app.input.keyboard_captured && input.key_down(&app.input, .DOWN) do period = SOFT_FALL_PERIOD
  for state.fall_timer >= period {
    state.fall_timer -= period
    drop_step(app)
    if state.game_over do return
  }
}

on_key :: proc(app: ^App, key: input.Key) {
  if state.game_over do return
  #partial switch key {
  case .LEFT:  try_move(app, 1, 0)
  case .RIGHT: try_move(app, -1, 0)
  case .UP:    try_rotate(app)
  case .SPACE:
    for try_move(app, 0, -1) {}
    state.fall_timer = state.fall_period
  }
}

refresh_score_ui :: proc(app: ^App) {
  ui.set_text(&app.gui, state.score_label, fmt.tprintf("Score: %d", state.score))
  ui.set_text(&app.gui, state.high_label,  fmt.tprintf("High: %d",  state.high_score))
}
