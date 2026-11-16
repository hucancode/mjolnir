// Sprite atlas: packed sprite frames walking an isometric field; point at one to see its health, click to hit it.
package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

ATLAS :: 32
PIXEL :: f32(1.0 / 16.0)
PITCH :: math.PI / 6
VIEW_HEIGHT :: 12
FIELD :: 7
WALKERS :: 24
SPEED :: 1.5
PICK_RADIUS :: 0.6
HEAD :: 1.6
HP :: 5
WALK :: render.SpriteClip{first = 0, count = 2, fps = 4}
HAT :: 2

BODY_ART :: [16]string {
  "....kkkkkk..",
  "...kssssssk.",
  "...kswsswsk.",
  "...kssssssk.",
  "....kkkkkk..",
  "..kbbbbbbbbk",
  ".kbbbbbbbbbk",
  ".kbbkbbbbkbk",
  ".kbbkbbbbkbk",
  ".kssk....ksk",
  "..kbbbbbbbk.",
  "..kbbbbbbbk.",
  "..kbbk.kbbk.",
  "..kbbk.kbbk.",
  "..kkkk.kkkk.",
  "............",
}

HAT_ART :: [6]string {
  "....rrrr....",
  "...rrrrrr...",
  "...ryyyyr...",
  "..rrrrrrrr..",
  "krrrrrrrrrrk",
  ".kkkkkkkkkk.",
}

Walker :: struct {
  body:   world.NodeHandle,
  hat:    world.NodeHandle,
  pos:    [2]f32,
  goal:   [2]f32,
  hp:     int,
  facing: f32,
  time:   f32,
}

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  walkers:  [WALKERS]Walker,
  hovered:  int,
  time:     f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Sprite atlas") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
  mjolnir.run(mjolnir.Loop(App){app = app, setup = setup, shutdown = shutdown, update = update, render = draw})
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

color_of :: proc(c: u8) -> [4]u8 {
  switch c {
  case 'k': return {30, 24, 36, 255}
  case 's': return {242, 196, 160, 255}
  case 'w': return {20, 20, 30, 255}
  case 'b': return {70, 110, 200, 255}
  case 'r': return {200, 50, 60, 255}
  case 'y': return {250, 210, 80, 255}
  }
  return {}
}

paint :: proc(pixels: ^[ATLAS * ATLAS * 4]u8, x, y: int, c: u8) {
  i := (y * ATLAS + x) * 4
  color := color_of(c)
  copy(pixels[i:i + 4], color[:])
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  pixels: [ATLAS * ATLAS * 4]u8
  body := BODY_ART
  hat := HAT_ART
  for row, y in body {
    for x in 0 ..< len(row) {
      paint(&pixels, x, y, row[x])
      bob := body[y - 1][x] if y > 0 else '.'
      paint(&pixels, 12 + x, y, bob)
    }
  }
  for row, y in hat {
    for x in 0 ..< len(row) do paint(&pixels, 24 + 5 - y, x, row[x])
  }
  texture := render.texture_create(&app.renderer, pixels[:], {ATLAS, ATLAS})
  if texture == 0 do return .FAIL
  uv :: proc(x, y: f32) -> [2]f32 {return {x, y} / ATLAS}
  frames := [?]render.SpriteFrame {
    {uv = {uv(0, 0), uv(12, 0), uv(12, 16), uv(0, 16)}, offset = {0, 8}, size = {12, 16}},
    {uv = {uv(12, 0), uv(24, 0), uv(24, 16), uv(12, 16)}, offset = {0, 8}, size = {12, 16}},
    {uv = {uv(30, 0), uv(30, 12), uv(24, 12), uv(24, 0)}, offset = {0, 18}, size = {12, 6}},
  }
  set := render.sprite_frames_create(&app.renderer, frames[:])
  if set == 0 do return .FAIL
  material := render.material_create(&app.renderer, render.make_material(.SPRITE, albedo_texture = texture, sprite_frames = set))
  if material == 0 do return .FAIL

  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GREEN), scale = FIELD + 1)
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.3, -1, -0.4}, [3]f32{0, 1, 0}))
  for &w in app.walkers {
    w.pos = {rand.float32_range(-FIELD, FIELD), rand.float32_range(-FIELD, FIELD)}
    w.goal, w.hp, w.facing, w.time = w.pos, HP, 1, rand.float32()
    sprite := render.primitive(&app.renderer, .QUAD_XY, material, no_shadow = true)
    w.body = mjolnir.spawn(&app.scene, &app.renderer, sprite, scale = PIXEL)
    sprite.frame, sprite.depth_offset = HAT, 0.01
    w.hat = mjolnir.spawn(&app.scene, &app.renderer, sprite, parent = w.body)
  }
  app.hovered = -1
  return .READY
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  app.time += dt
  cam := render.main_camera(&app.renderer)
  cam.projection = render.OrthographicProjection{VIEW_HEIGHT}
  render.camera_look_at(cam, {0, math.sin(f32(PITCH)), math.cos(f32(PITCH))} * 30, {0, 0, 0})

  cursor: [2]f32
  aimed := false
  if ray, ok := render.cursor_ray(&app.renderer, app.input.cursor); ok {
    hit: [3]f32
    hit, aimed = geometry.ray_plane_intersection(ray, {}, {0, 1, 0})
    cursor = hit.xz
  }
  app.hovered = -1
  best := f32(PICK_RADIUS)
  for &w, i in app.walkers {
    if w.hp > 0 && aimed && linalg.distance(w.pos, cursor) < best do app.hovered, best = i, linalg.distance(w.pos, cursor)
    to := w.goal - w.pos
    if linalg.length(to) < 0.1 {
      w.goal = {rand.float32_range(-FIELD, FIELD), rand.float32_range(-FIELD, FIELD)}
      continue
    }
    if w.hp <= 0 do continue
    step := linalg.normalize(to) * SPEED * dt
    w.pos += step
    if abs(step.x) > 1e-4 do w.facing = math.sign(step.x)
    w.time += dt
    frame, _ := render.sprite_clip_frame(WALK, w.time)
    render.sprite_frame(&app.renderer, w.body, frame)
    t := world.transform(&app.scene, w.body)
    t.position = {w.pos.x, 0, w.pos.y}
    t.scale = {w.facing * PIXEL, PIXEL, PIXEL}
  }
  if app.hovered >= 0 && input.mouse_pressed(&app.input, .LEFT) {
    w := &app.walkers[app.hovered]
    w.hp -= 1
    if w.hp <= 0 do world.transform(&app.scene, w.body).scale = {w.facing * PIXEL, PIXEL * 0.3, PIXEL}
  }
  hud(app)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

hud :: proc(app: ^App) {
  if app.hovered < 0 {
    render.stage_overlay(&app.renderer, nil)
    return
  }
  w := app.walkers[app.hovered]
  head, ok := render.world_to_screen(&app.renderer, {w.pos.x, HEAD, w.pos.y})
  if !ok do return
  BAR :: [2]f32{60, 8}
  top := head - {BAR.x / 2, BAR.y}
  commands := [?]render.OverlayCommand {
    {shape = render.OverlayQuad{position = top - 1, size = BAR + 2, color = {20, 20, 24, 220}}},
    {shape = render.OverlayQuad{position = top, size = {BAR.x * f32(w.hp) / HP, BAR.y}, color = {220, 60, 50, 255}}, z_order = 1},
  }
  render.stage_overlay(&app.renderer, commands[:])
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}
