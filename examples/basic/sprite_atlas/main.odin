// Sprite atlas: packed sprite frames walking an isometric field; point at one to mark it and see its health bar, both sprites in the world, click to hit it.
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
BAR_BACK :: 3
BAR_FILL :: 4
MARK :: 5
BAR :: [2]f32{1, 0.14}

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

MARK_ART :: [8]string {
  "..yyyy..",
  ".y....y.",
  "y......y",
  "y......y",
  "y......y",
  "y......y",
  ".y....y.",
  "..yyyy..",
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
  bar_back: world.NodeHandle,
  bar_fill: world.NodeHandle,
  mark:     world.NodeHandle,
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
  for y in 16 ..< 18 do for x in 0 ..< 4 do paint(&pixels, x, y, 'k' if x < 2 else 'r')
  mark := MARK_ART
  for row, y in mark {
    for x in 0 ..< len(row) do paint(&pixels, x, 18 + y, row[x])
  }
  texture := render.texture_create(&app.renderer, pixels[:], {ATLAS, ATLAS})
  if texture == 0 do return .FAIL
  uv :: proc(x, y: f32) -> [2]f32 {return {x, y} / ATLAS}
  frames := [?]render.SpriteFrame {
    {uv = {uv(0, 0), uv(12, 0), uv(12, 16), uv(0, 16)}, offset = {0, 8}, size = {12, 16}},
    {uv = {uv(12, 0), uv(24, 0), uv(24, 16), uv(12, 16)}, offset = {0, 8}, size = {12, 16}},
    {uv = {uv(30, 0), uv(30, 12), uv(24, 12), uv(24, 0)}, offset = {0, 18}, size = {12, 6}},
    {uv = {uv(0.5, 16.5), uv(1.5, 16.5), uv(1.5, 17.5), uv(0.5, 17.5)}, size = {1, 1}},
    {uv = {uv(2.5, 16.5), uv(3.5, 16.5), uv(3.5, 17.5), uv(2.5, 17.5)}, offset = {0.5, 0}, size = {1, 1}},
    {uv = {uv(0, 18), uv(8, 18), uv(8, 26), uv(0, 26)}, size = {8, 8}},
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
  bar := render.primitive(&app.renderer, .QUAD_XY, material, no_shadow = true)
  bar.frame = BAR_BACK
  app.bar_back = mjolnir.spawn(&app.scene, &app.renderer, bar, scale = {BAR.x + 0.04, BAR.y + 0.04, 1})
  bar.frame, bar.depth_offset = BAR_FILL, 0.01
  app.bar_fill = mjolnir.spawn(&app.scene, &app.renderer, bar)
  ring := render.primitive(&app.renderer, .QUAD_XY, material, no_shadow = true)
  ring.frame, ring.turned = MARK, true
  app.mark = mjolnir.spawn(&app.scene, &app.renderer, ring, scale = PIXEL * 2)
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
  shown := app.hovered >= 0
  for n in ([]world.NodeHandle{app.bar_back, app.bar_fill, app.mark}) do world.set_visible(&app.scene, n, shown)
  if !shown do return
  w := app.walkers[app.hovered]
  world.transform(&app.scene, app.bar_back).position = {w.pos.x, HEAD, w.pos.y}
  fill := world.transform(&app.scene, app.bar_fill)
  fill.position = {w.pos.x - BAR.x / 2, HEAD, w.pos.y}
  fill.scale = {BAR.x * f32(w.hp) / HP, BAR.y, 1}
  mark := world.transform(&app.scene, app.mark)
  mark.position = {w.pos.x, 0.01, w.pos.y}
  mark.rotation = linalg.quaternion_angle_axis(app.time, [3]f32{0, 1, 0}) * linalg.quaternion_angle_axis(-f32(math.PI) / 2, [3]f32{1, 0, 0})
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}
