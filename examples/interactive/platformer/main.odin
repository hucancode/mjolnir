// 2D pixel platformer: run, jump through one-way platforms, collect coins, stomp enemies.
// Art: Pixel Platformer by Kenney (www.kenney.nl, CC0). Physics: vendor:box2d.
package main

import "mjolnir"
import "mjolnir/font"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import b2 "vendor:box2d"

LEVEL := [?]string {
  "..........................................................................",
  "..........................................................................",
  "..............................ccc.......................................F.",
  ".............................=====.......................ccc...........##.",
  "......................................................=======.........###.",
  "..........ccc.........................ccc............................####.",
  ".........=====...........ccc.........=====...................cc.....#####.",
  ".........................===..................................==...######.",
  ".................c.............e.............e...................e.#######",
  "................===..........#####......#########.........#########.######",
  "..P....c.c.c........e.............^^^^..................^^..........######",
  "##########################.....############################...############",
  "##########################.....############################...############",
  "##########################.....############################...############",
}
ROWS :: len(LEVEL)
COLUMNS :: 74

TILE_PIXELS :: 18
CHARACTER_SIZE :: 24.0 / TILE_PIXELS
BACKGROUND_SIZE :: 24.0 / TILE_PIXELS
VIEW_TILES :: 12
CAMERA_RISE_LINE :: 0.7
PARALLAX :: 0.5

STEP :: 1.0 / 60.0
GRAVITY :: -30.0
RUN_SPEED :: 7.0
JUMP_SPEED :: 14.5
JUMP_CUT :: 0.5
STOMP_BOUNCE :: 10.0
COYOTE_TIME :: 0.1
JUMP_BUFFER_TIME :: 0.1
ENEMY_SPEED :: 1.5
SQUASH_TIME :: 0.5
FALL_LIMIT :: -3.0
ANIMATION_FPS :: 8.0

PLAYER_HALF :: [2]f32{0.4, 0.6}
ENEMY_HALF :: [2]f32{0.4, 0.35}

Z_BACKGROUND :: -2.0
Z_TILES :: 0.0
Z_ITEMS :: 0.5
Z_CHARACTERS :: 1.0

GROUND :: u64(1 << 0)
ONE_WAY :: u64(1 << 1)
PLAYER :: u64(1 << 2)
TRIGGER :: u64(1 << 3)

Sheet :: struct {
  texture: render.TextureHandle,
  columns: u32,
  rows:    u32,
}

Tile :: enum {
  GRASS_LEFT,
  GRASS,
  GRASS_RIGHT,
  DIRT_LEFT,
  DIRT,
  DIRT_RIGHT,
  ONE_WAY_LEFT,
  ONE_WAY,
  ONE_WAY_RIGHT,
  SPIKES,
}
TILE_FRAMES := [Tile]u32 {
  .GRASS_LEFT    = 21,
  .GRASS         = 22,
  .GRASS_RIGHT   = 23,
  .DIRT_LEFT     = 121,
  .DIRT          = 122,
  .DIRT_RIGHT    = 123,
  .ONE_WAY_LEFT  = 90,
  .ONE_WAY       = 91,
  .ONE_WAY_RIGHT = 92,
  .SPIKES        = 68,
}
COIN_FRAMES := [2]u32{151, 152}
FLAG_FRAMES := [2]u32{111, 112}

Backdrop :: enum {
  SKY,
  HILLS,
  MEADOW,
}
BACKDROP_FRAMES := [Backdrop]u32 {
  .SKY    = 6,
  .HILLS  = 14,
  .MEADOW = 22,
}
HORIZON :: 4

PLAYER_STAND :: 0
PLAYER_STEP :: 1
ENEMY_WALK := [2]u32{18, 19}
ENEMY_SQUASHED :: 20

Player :: struct {
  node:        world.NodeHandle,
  body:        b2.BodyId,
  shape:       b2.ShapeId,
  look:        render.MaterialHandle,
  start:       [2]f32,
  facing:      f32,
  air_time:    f32,
  jump_buffer: f32,
}

Coin :: struct {
  node:  world.NodeHandle,
  body:  b2.BodyId,
  shape: b2.ShapeId,
}

Enemy :: struct {
  node:        world.NodeHandle,
  body:        b2.BodyId,
  shape:       b2.ShapeId,
  look:        render.MaterialHandle,
  left, right: f32,
  squash_time: f32,
  alive:       bool,
}

App :: struct {
  platform:   platform.Platform,
  scene:      world.World,
  renderer:   render.Renderer,
  input:      input.State,
  font:       font.Font,
  phys:       b2.WorldId,
  tiles:      [Tile]render.MaterialHandle,
  coin_look:  render.MaterialHandle,
  flag_look:  render.MaterialHandle,
  backdrop:   world.NodeHandle,
  player:     Player,
  coins:      [dynamic]Coin,
  enemies:    [dynamic]Enemy,
  spikes:     [dynamic]b2.ShapeId,
  flag:       b2.ShapeId,
  run:        f32,
  step_time:  f32,
  time:       f32,
  coin_count: int,
  score:      int,
  won:        bool,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Platformer") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
  world_def := b2.DefaultWorldDef()
  world_def.gravity = {0, GRAVITY}
  app.phys = b2.CreateWorld(world_def)
  b2.World_SetPreSolveCallback(app.phys, keep_one_way_contact, nil)
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
  delete(app.coins)
  delete(app.enemies)
  delete(app.spikes)
  font.destroy(&app.font)
  b2.DestroyWorld(app.phys)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !font.init(&app.font, #load("assets/Outfit-Regular.ttf")) do return .FAIL
  tile_sheet := load_sheet(app, #load("assets/kenney_pixel_platformer/Tilemap/tilemap_packed.png"), 20, 9)
  character_sheet := load_sheet(app, #load("assets/kenney_pixel_platformer/Tilemap/tilemap-characters_packed.png"), 9, 3)
  backdrop_sheet := load_sheet(app, #load("assets/kenney_pixel_platformer/Tilemap/tilemap-backgrounds_packed.png"), 8, 3)

  for frame, tile in TILE_FRAMES do app.tiles[tile] = sprite_look(app, tile_sheet, frame)
  app.coin_look = sprite_look(app, tile_sheet, COIN_FRAMES[0])
  app.flag_look = sprite_look(app, tile_sheet, FLAG_FRAMES[0])
  build_backdrop(app, backdrop_sheet)
  build_level(app, character_sheet)
  app.coin_count = len(app.coins)
  return .READY
}

load_sheet :: proc(app: ^App, png: []u8, columns, rows: u32) -> Sheet {
  return {render.texture_create(&app.renderer, png), columns, rows}
}

sprite_look :: proc(app: ^App, sheet: Sheet, frame: u32) -> render.MaterialHandle {
  return render.material_create(&app.renderer, render.make_material(.SPRITE, albedo_texture = sheet.texture, frame_columns = sheet.columns, frame_rows = sheet.rows, frame_index = frame))
}

spawn_sprite :: proc(app: ^App, look: render.MaterialHandle, position: [3]f32, size: f32 = 1, parent: world.NodeHandle = {}) -> world.NodeHandle {
  node := mjolnir.spawn_mesh(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XY, look, cast_shadow = false), position, parent = parent, scale = size / 2)
  return node
}

build_backdrop :: proc(app: ^App, sheet: Sheet) {
  looks: [Backdrop]render.MaterialHandle
  for frame, backdrop in BACKDROP_FRAMES do looks[backdrop] = sprite_look(app, sheet, frame)
  app.backdrop = world.spawn(&app.scene, {0, 0, Z_BACKGROUND})
  for x := -f32(COLUMNS); x < f32(COLUMNS) * 1.5; x += BACKGROUND_SIZE {
    for row in -2 ..< 16 {
      backdrop: Backdrop = .SKY if row > HORIZON else .HILLS if row == HORIZON else .MEADOW
      spawn_sprite(app, looks[backdrop], {x, f32(row) * BACKGROUND_SIZE, 0}, BACKGROUND_SIZE, app.backdrop)
    }
  }
}

cell_center :: proc(column, row: int) -> [2]f32 {
  return {f32(column) + 0.5, f32(ROWS - 1 - row) + 0.5}
}

cell :: proc(column, row: int) -> u8 {
  if row < 0 || row >= ROWS || column < 0 || column >= COLUMNS do return '.'
  return LEVEL[row][column]
}

build_level :: proc(app: ^App, characters: Sheet) {
  for row in 0 ..< ROWS {
    for column in 0 ..< COLUMNS {
      center := cell_center(column, row)
      switch cell(column, row) {
      case '#':
        spawn_sprite(app, app.tiles[ground_tile(column, row)], {center.x, center.y, Z_TILES})
      case '=':
        tile: Tile = .ONE_WAY_LEFT if cell(column - 1, row) != '=' else .ONE_WAY_RIGHT if cell(column + 1, row) != '=' else .ONE_WAY
        spawn_sprite(app, app.tiles[tile], {center.x, center.y, Z_TILES})
      case '^':
        spawn_sprite(app, app.tiles[.SPIKES], {center.x, center.y, Z_TILES})
        _, spike := sensor_create(app, .staticBody, center - {0, 0.25}, {0.4, 0.25})
        append(&app.spikes, spike)
      case 'c':
        body, shape := sensor_create(app, .staticBody, center, {0.3, 0.3})
        append(&app.coins, Coin{spawn_sprite(app, app.coin_look, {center.x, center.y, Z_ITEMS}), body, shape})
      case 'F':
        spawn_sprite(app, app.flag_look, {center.x, center.y, Z_ITEMS})
        _, app.flag = sensor_create(app, .staticBody, center, {0.4, 0.5})
      case 'e':
        spawn_enemy(app, characters, column, row)
      case 'P':
        spawn_player(app, characters, center)
      }
    }
  }
  build_colliders(app, '#', GROUND, 0.5)
  build_colliders(app, '=', ONE_WAY, 0.25)
}

ground_tile :: proc(column, row: int) -> Tile {
  top := cell(column, row - 1) != '#'
  left := cell(column - 1, row) != '#'
  right := cell(column + 1, row) != '#'
  if top do return .GRASS_LEFT if left else .GRASS_RIGHT if right else .GRASS
  return .DIRT_LEFT if left else .DIRT_RIGHT if right else .DIRT
}

build_colliders :: proc(app: ^App, solid: u8, category: u64, half_height: f32) {
  for row in 0 ..< ROWS {
    start := -1
    for column in 0 ..= COLUMNS {
      inside := cell(column, row) == solid
      if inside && start < 0 do start = column
      if inside || start < 0 do continue
      left, right := cell_center(start, row), cell_center(column - 1, row)
      center := (left + right) / 2 + {0, 0.5 - half_height}
      box := b2.MakeBox((right.x - left.x + 1) / 2, half_height)
      shape := b2.DefaultShapeDef()
      shape.material.friction = 0
      shape.filter = {categoryBits = category, maskBits = PLAYER}
      _ = b2.CreatePolygonShape(body_create(app, .staticBody, center), shape, &box)
      start = -1
    }
  }
}

body_create :: proc(app: ^App, type: b2.BodyType, position: [2]f32) -> b2.BodyId {
  body := b2.DefaultBodyDef()
  body.type = type
  body.position = position
  body.fixedRotation = true
  return b2.CreateBody(app.phys, body)
}

sensor_create :: proc(app: ^App, type: b2.BodyType, position, half: [2]f32) -> (b2.BodyId, b2.ShapeId) {
  body := body_create(app, type, position)
  box := b2.MakeBox(half.x, half.y)
  shape := b2.DefaultShapeDef()
  shape.isSensor = true
  shape.enableSensorEvents = true
  shape.filter = {categoryBits = TRIGGER, maskBits = PLAYER}
  return body, b2.CreatePolygonShape(body, shape, &box)
}

spawn_player :: proc(app: ^App, characters: Sheet, position: [2]f32) {
  p := &app.player
  p.start = position
  p.facing = 1
  p.look = sprite_look(app, characters, PLAYER_STAND)
  p.node = spawn_sprite(app, p.look, {position.x, position.y, Z_CHARACTERS}, CHARACTER_SIZE)
  p.body = body_create(app, .dynamicBody, position)
  box := b2.MakeBox(PLAYER_HALF.x, PLAYER_HALF.y)
  shape := b2.DefaultShapeDef()
  shape.material.friction = 0
  shape.filter = {categoryBits = PLAYER, maskBits = GROUND | ONE_WAY | TRIGGER}
  shape.enableSensorEvents = true
  shape.enablePreSolveEvents = true
  p.shape = b2.CreatePolygonShape(p.body, shape, &box)
}

spawn_enemy :: proc(app: ^App, characters: Sheet, column, row: int) {
  left, right := column, column
  for cell(left - 1, row) == '.' && cell(left - 1, row + 1) == '#' do left -= 1
  for cell(right + 1, row) == '.' && cell(right + 1, row + 1) == '#' do right += 1
  position := cell_center(column, row) - {0, 0.5 - ENEMY_HALF.y}
  enemy := Enemy {
    look  = sprite_look(app, characters, ENEMY_WALK[0]),
    left  = cell_center(left, row).x,
    right = cell_center(right, row).x,
    alive = true,
  }
  enemy.node = spawn_sprite(app, enemy.look, {position.x, position.y, Z_CHARACTERS}, CHARACTER_SIZE)
  enemy.body, enemy.shape = sensor_create(app, .kinematicBody, position, ENEMY_HALF)
  b2.Body_SetLinearVelocity(enemy.body, {ENEMY_SPEED, 0})
  append(&app.enemies, enemy)
}

keep_one_way_contact :: proc "c" (shape_a, shape_b: b2.ShapeId, manifold: ^b2.Manifold, ctx: rawptr) -> bool {
  up_from_platform: f32
  if b2.Shape_GetFilter(shape_a).categoryBits == ONE_WAY do up_from_platform = 1
  else if b2.Shape_GetFilter(shape_b).categoryBits == ONE_WAY do up_from_platform = -1
  else do return true
  return manifold.normal.y * up_from_platform > 0.95 && manifold.points[0].separation > -0.1
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  read_controls(app)
  app.time += dt
  app.step_time = min(app.step_time + dt, 0.25)
  for app.step_time >= STEP {
    app.step_time -= STEP
    step_game(app)
  }
  animate(app)
  follow_player(app)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  draw_hud(app)
  render.update(&app.renderer, dt)
}

read_controls :: proc(app: ^App) {
  app.run = clamp(input.axis(&app.input, .A, .D) + input.axis(&app.input, .LEFT, .RIGHT), -1, 1)
  if app.won do app.run = 0
  jump_pressed := input.key_pressed(&app.input, .SPACE) || input.key_pressed(&app.input, .W) || input.key_pressed(&app.input, .UP)
  jump_released := input.key_released(&app.input, .SPACE) || input.key_released(&app.input, .W) || input.key_released(&app.input, .UP)
  if jump_pressed && !app.won do app.player.jump_buffer = JUMP_BUFFER_TIME
  velocity := b2.Body_GetLinearVelocity(app.player.body)
  if jump_released && velocity.y > 0 do b2.Body_SetLinearVelocity(app.player.body, {velocity.x, velocity.y * JUMP_CUT})
}

step_game :: proc(app: ^App) {
  step_player(app)
  for &enemy in app.enemies do step_enemy(&enemy)
  b2.World_Step(app.phys, STEP, 4)
  events := b2.World_GetSensorEvents(app.phys)
  for event in events.beginEvents[:events.beginCount] {
    if event.visitorShapeId == app.player.shape do touch(app, event.sensorShapeId)
  }
  if b2.Body_GetPosition(app.player.body).y < FALL_LIMIT do respawn(app)
}

step_player :: proc(app: ^App) {
  p := &app.player
  velocity := b2.Body_GetLinearVelocity(p.body)
  p.air_time = 0 if velocity.y <= 0.01 && on_ground(app) else p.air_time + STEP
  p.jump_buffer -= STEP
  if p.jump_buffer > 0 && p.air_time < COYOTE_TIME {
    velocity.y = JUMP_SPEED
    p.jump_buffer = 0
    p.air_time = COYOTE_TIME
  }
  velocity.x = app.run * RUN_SPEED
  if app.run != 0 do p.facing = math.sign(app.run)
  b2.Body_SetLinearVelocity(p.body, velocity)
}

on_ground :: proc(app: ^App) -> bool {
  feet := b2.Body_GetPosition(app.player.body) - {0, PLAYER_HALF.y - 0.05}
  floors := b2.QueryFilter{categoryBits = PLAYER, maskBits = GROUND | ONE_WAY}
  for side in ([2]f32{-1, 1}) {
    origin := feet + {side * PLAYER_HALF.x * 0.9, 0}
    if b2.World_CastRayClosest(app.phys, origin, {0, -0.15}, floors).hit do return true
  }
  return false
}

step_enemy :: proc(enemy: ^Enemy) {
  if !enemy.alive {
    enemy.squash_time -= STEP
    return
  }
  x := b2.Body_GetPosition(enemy.body).x
  velocity := b2.Body_GetLinearVelocity(enemy.body)
  if x <= enemy.left do velocity.x = ENEMY_SPEED
  if x >= enemy.right do velocity.x = -ENEMY_SPEED
  b2.Body_SetLinearVelocity(enemy.body, velocity)
}

touch :: proc(app: ^App, sensor: b2.ShapeId) {
  for coin, i in app.coins {
    if coin.shape != sensor do continue
    b2.DestroyBody(coin.body)
    world.destroy(&app.scene, coin.node)
    unordered_remove(&app.coins, i)
    app.score += 1
    return
  }
  for &enemy in app.enemies {
    if enemy.shape != sensor || !enemy.alive do continue
    if b2.Body_GetLinearVelocity(app.player.body).y < 0 {
      stomp(app, &enemy)
    } else {
      respawn(app)
    }
    return
  }
  for spike in app.spikes do if spike == sensor do respawn(app)
  if sensor == app.flag do app.won = true
}

stomp :: proc(app: ^App, enemy: ^Enemy) {
  enemy.alive = false
  enemy.squash_time = SQUASH_TIME
  b2.DestroyBody(enemy.body)
  render.set_sprite_frame(&app.renderer, enemy.look, ENEMY_SQUASHED)
  velocity := b2.Body_GetLinearVelocity(app.player.body)
  b2.Body_SetLinearVelocity(app.player.body, {velocity.x, STOMP_BOUNCE})
}

respawn :: proc(app: ^App) {
  b2.Body_SetTransform(app.player.body, app.player.start, b2.Rot_identity)
  b2.Body_SetLinearVelocity(app.player.body, {})
  app.player.air_time = COYOTE_TIME
}

animate :: proc(app: ^App) {
  tick := int(app.time * ANIMATION_FPS)
  render.set_sprite_frame(&app.renderer, app.coin_look, COIN_FRAMES[tick / 2 % 2])
  render.set_sprite_frame(&app.renderer, app.flag_look, FLAG_FRAMES[tick / 2 % 2])

  p := &app.player
  position := b2.Body_GetPosition(p.body)
  grounded := p.air_time < COYOTE_TIME
  stepping := !grounded || (app.run != 0 && tick % 2 == 0)
  render.set_sprite_frame(&app.renderer, p.look, PLAYER_STEP if stepping else PLAYER_STAND)
  place_character(app, p.node, position - {0, PLAYER_HALF.y}, -p.facing)

  #reverse for &enemy, i in app.enemies {
    if !enemy.alive {
      if enemy.squash_time <= 0 {
        world.destroy(&app.scene, enemy.node)
        unordered_remove(&app.enemies, i)
      }
      continue
    }
    feet := b2.Body_GetPosition(enemy.body) - {0, ENEMY_HALF.y}
    render.set_sprite_frame(&app.renderer, enemy.look, ENEMY_WALK[tick % 2])
    place_character(app, enemy.node, feet, math.sign(b2.Body_GetLinearVelocity(enemy.body).x))
  }
}

place_character :: proc(app: ^App, node: world.NodeHandle, feet: [2]f32, facing: f32) {
  world.translate(&app.scene, node, feet.x, feet.y + CHARACTER_SIZE / 2, Z_CHARACTERS)
  world.scale(&app.scene, node, facing * CHARACTER_SIZE / 2, CHARACTER_SIZE / 2, 1)
}

follow_player :: proc(app: ^App) {
  size := platform.framebuffer_size(&app.platform)
  dpi_scale := platform.dpi_scale(&app.platform)
  zoom := max(1, math.round(f32(size.y) / dpi_scale / (TILE_PIXELS * VIEW_TILES)))
  pixels_per_unit := TILE_PIXELS * math.round(zoom * dpi_scale)
  view := [2]f32{f32(size.x), f32(size.y)} / pixels_per_unit
  target := b2.Body_GetPosition(app.player.body)
  center := [2]f32 {
    clamp(target.x, view.x / 2, f32(COLUMNS) - view.x / 2),
    clamp(target.y - view.y * (CAMERA_RISE_LINE - 0.5), view.y / 2, f32(ROWS) + 4 - view.y / 2),
  }
  center = linalg.round(center * pixels_per_unit) / pixels_per_unit
  camera := render.main_camera(&app.renderer)
  render.camera_set_orthographic(camera, view.y)
  render.camera_look_at(camera, {center.x, center.y, 10}, {center.x, center.y, 0}, {0, 1, 0})
  world.translate(&app.scene, app.backdrop, math.round(center.x * PARALLAX * pixels_per_unit) / pixels_per_unit, 0, Z_BACKGROUND)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

draw_hud :: proc(app: ^App) {
  white :: [4]u8{255, 255, 255, 255}
  hud := [?]render.RenderCommand {
    {shape = render.DrawTextCommand{text = fmt.tprintf("Coins: %d / %d", app.score, app.coin_count), position = {20, 20}, size = 28, color = white}},
    {shape = render.DrawTextCommand{text = "You made it!" if app.won else "Arrows/WASD run, Space jumps", position = {20, 60}, size = 22, color = white}},
  }
  render.stage_overlay(&app.renderer, hud[:], &app.font)
}
