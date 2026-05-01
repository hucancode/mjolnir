package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import "../../mjolnir/ui"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "vendor:glfw"

GRID_W :: 20
GRID_H :: 20
PIECE_LEN :: 4
CELL :: f32(1.0)
RADIUS :: f32(GRID_W) * CELL / (2.0 * math.PI)
FALL_PERIOD :: f32(0.6)
SOFT_FALL_PERIOD :: f32(0.05)

Piece :: struct {
  cells: [PIECE_LEN][2]i32,
  color: world.Color,
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
  transparent_material: [len(world.Color)]world.MaterialHandle,
  opaque_material:      [len(world.Color)]world.MaterialHandle,
  score_label:          ui.Text2DHandle,
  high_label:           ui.Text2DHandle,
}

PIECE_ALPHA :: f32(0.5)

COLOR_RGB := [len(world.Color)][3]f32 {
  {1, 1, 1},
  {0, 0, 0},
  {0.3, 0.3, 0.3},
  {1, 0, 0},
  {0, 1, 0},
  {0, 0, 1},
  {1, 1, 0},
  {0, 1, 1},
  {1, 0, 1},
}

state: State

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.key_press_proc = on_key
  mjolnir.run(engine, 1024, 768, "Torus Tetris")
}

wrap_col :: proc(c: i32) -> i32 {
  r := c %% GRID_W
  return r
}

col_angle :: proc(col: i32) -> f32 {
  return (f32(col) + 0.5) / f32(GRID_W) * 2.0 * math.PI
}

cell_world_pos :: proc(col: i32, row: i32) -> [3]f32 {
  a := col_angle(col)
  return {RADIUS * math.cos(a), f32(row) * CELL + 0.5 * CELL, RADIUS * math.sin(a)}
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.debug_ui_enabled = false
  // floor ring
  ground := engine.world.builtin_meshes[world.Primitive.QUAD_XZ]
  dark_mat, _ := world.create_material(
    &engine.world,
    type = .PBR,
    base_color_factor = {0.05, 0.05, 0.06, 1.0},
  )
  floor_handle, _ := world.spawn(
    &engine.world,
    {0, 0, 0},
    world.MeshAttachment{handle = ground, material = dark_mat, cast_shadow = false},
  )
  world.scale(&engine.world, floor_handle, RADIUS * 6.0)
  // single spot light, slightly diagonal
  spot_handle, _ := world.spawn(
    &engine.world,
    {0, 10, 0},
    world.create_spot_light_attachment({1, 1, 1, 1}, 12.0, math.PI * 0.35, true),
  )
  world.rotate(&engine.world, spot_handle, math.PI * 0.55, {1, 0, 0})
  world.main_camera_look_at(&engine.world, {0, 14, 14}, {0, 8, 0})
  for c, i in COLOR_RGB {
    th, _ := world.create_material(
      &engine.world,
      type = .TRANSPARENT,
      base_color_factor = {c.x, c.y, c.z, PIECE_ALPHA},
    )
    state.transparent_material[i] = th
    oh, _ := world.create_material(
      &engine.world,
      type = .PBR,
      base_color_factor = {c.x, c.y, c.z, 1.0},
    )
    state.opaque_material[i] = oh
  }
  state.fall_period = FALL_PERIOD
  state.score_label, _ = ui.create_text2d(
    &engine.ui,
    position = {20, 20},
    text = "Score: 0",
    font_size = 32,
    color = {255, 255, 255, 255},
  )
  state.high_label, _ = ui.create_text2d(
    &engine.ui,
    position = {20, 60},
    text = "High: 0",
    font_size = 24,
    color = {255, 220, 100, 255},
  )
  reset_game(engine)
  refresh_score_ui(engine)
}

reset_game :: proc(engine: ^mjolnir.Engine) {
  for col in 0 ..< GRID_W {
    for row in 0 ..< GRID_H {
      if state.occupied[col][row] {
        world.despawn(&engine.world, state.board[col][row])
        state.board[col][row] = {}
        state.occupied[col][row] = false
      }
    }
  }
  if state.has_active {
    for h in state.active_cells {
      world.despawn(&engine.world, h)
    }
    state.has_active = false
  }
  state.score = 0
  state.fall_timer = 0
  state.fall_period = FALL_PERIOD
  state.game_over = false
  spawn_piece(engine)
}

spawn_piece :: proc(engine: ^mjolnir.Engine) {
  state.active_piece = rand.choice(PIECES[:])
  max_dr := i32(0)
  for c in state.active_piece.cells {
    if c[1] > max_dr do max_dr = c[1]
  }
  state.active_pos = {0, i32(GRID_H) - 1 - max_dr}
  if collides(state.active_piece, state.active_pos) {
    state.game_over = true
    return
  }
  cube := engine.world.builtin_meshes[world.Primitive.CUBE]
  solid_mat := state.transparent_material[state.active_piece.color]
  for i in 0 ..< PIECE_LEN {
    h, _ := world.spawn(
      &engine.world,
      {0, 0, 0},
      world.MeshAttachment{handle = cube, material = solid_mat, cast_shadow = true},
    )
    state.active_cells[i] = h
    world.scale(&engine.world, h, 0.5 * CELL)
  }
  state.has_active = true
  refresh_active_visuals(&engine.world)
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

refresh_active_visuals :: proc(w: ^world.World) {
  for c, i in state.active_piece.cells {
    col := wrap_col(state.active_pos[0] + c[0])
    row := state.active_pos[1] + c[1]
    p := cell_world_pos(col, row)
    world.translate(w, state.active_cells[i], p.x, p.y, p.z)
    world.rotate(w, state.active_cells[i], -col_angle(col), {0, 1, 0})
  }
}

try_move :: proc(engine: ^mjolnir.Engine, dcol: i32, drow: i32) -> bool {
  np: [2]i32 = {state.active_pos[0] + dcol, state.active_pos[1] + drow}
  if collides(state.active_piece, np) do return false
  state.active_pos = np
  refresh_active_visuals(&engine.world)
  return true
}

try_rotate :: proc(engine: ^mjolnir.Engine) -> bool {
  rotated: Piece = state.active_piece
  for &c in rotated.cells {
    dc := c[0]
    dr := c[1]
    c = {dr, -dc}
  }
  if collides(rotated, state.active_pos) do return false
  state.active_piece = rotated
  refresh_active_visuals(&engine.world)
  return true
}

lock_piece :: proc(engine: ^mjolnir.Engine) {
  opaque_mat := state.opaque_material[state.active_piece.color]
  for c, i in state.active_piece.cells {
    col := wrap_col(state.active_pos[0] + c[0])
    row := state.active_pos[1] + c[1]
    state.board[col][row] = state.active_cells[i]
    state.occupied[col][row] = true
    if node, ok := cont.get(engine.world.nodes, state.active_cells[i]); ok {
      if mesh, has_mesh := &node.attachment.(world.MeshAttachment); has_mesh {
        mesh.material = opaque_mat
        world.stage_node_data(&engine.world.staging, state.active_cells[i])
      }
    }
  }
  state.has_active = false
  cleared := clear_lines(engine)
  if cleared > 0 {
    state.score += u32(cleared * cleared * 100)
  }
}

clear_lines :: proc(engine: ^mjolnir.Engine) -> int {
  cleared := 0
  r := 0
  for r < GRID_H {
    full := true
    for col in 0 ..< GRID_W {
      if !state.occupied[col][r] {
        full = false
        break
      }
    }
    if !full {
      r += 1
      continue
    }
    for col in 0 ..< GRID_W {
      world.despawn(&engine.world, state.board[col][r])
      state.board[col][r] = {}
      state.occupied[col][r] = false
    }
    for r2 := r; r2 < GRID_H - 1; r2 += 1 {
      for col in 0 ..< GRID_W {
        state.board[col][r2] = state.board[col][r2 + 1]
        state.occupied[col][r2] = state.occupied[col][r2 + 1]
        if state.occupied[col][r2] {
          p := cell_world_pos(i32(col), i32(r2))
          world.translate(&engine.world, state.board[col][r2], p.x, p.y, p.z)
        }
      }
    }
    for col in 0 ..< GRID_W {
      state.board[col][GRID_H - 1] = {}
      state.occupied[col][GRID_H - 1] = false
    }
    cleared += 1
  }
  return cleared
}

drop_step :: proc(engine: ^mjolnir.Engine) {
  if try_move(engine, 0, -1) do return
  lock_piece(engine)
  spawn_piece(engine)
  refresh_score_ui(engine)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  if state.game_over {
    if state.score > state.high_score do state.high_score = state.score
    log.infof("game over - score %d high %d - restarting", state.score, state.high_score)
    reset_game(engine)
    refresh_score_ui(engine)
    return
  }
  state.fall_timer += dt
  period := state.fall_period
  if glfw.GetKey(engine.window, glfw.KEY_DOWN) == glfw.PRESS {
    period = SOFT_FALL_PERIOD
  }
  for state.fall_timer >= period {
    state.fall_timer -= period
    drop_step(engine)
    if state.game_over do return
  }
}

on_key :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
  if action != glfw.PRESS do return
  if state.game_over do return
  switch key {
  case glfw.KEY_LEFT:
    try_move(engine, 1, 0)
  case glfw.KEY_RIGHT:
    try_move(engine, -1, 0)
  case glfw.KEY_UP:
    try_rotate(engine)
  case glfw.KEY_SPACE:
    for try_move(engine, 0, -1) {}
    state.fall_timer = state.fall_period
  }
}

refresh_score_ui :: proc(engine: ^mjolnir.Engine) {
  ui.set_text(&engine.ui, state.score_label, fmt.tprintf("Score: %d", state.score))
  ui.set_text(&engine.ui, state.high_label, fmt.tprintf("High: %d", state.high_score))
}
