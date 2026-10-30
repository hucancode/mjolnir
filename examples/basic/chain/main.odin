// Chain: a blocky dragon on a rope. Grab it and drag; the body follows, the whiskers swing after.
package main

import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/geometry"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

MAX_BODY :: 40
MAX_WHISKER :: 10
BODY_HEIGHT :: f32(0.22)
TAIL_SIZE :: f32(0.15)
TAPER_SPAN :: f32(0.7)
GAP :: f32(0.92)
WHISKER_FAN :: f32(145 * math.PI / 180)
WHISKER_Y :: f32(0.4)
WHISKER_THICKNESS :: f32(0.035)
HEAD_Y :: f32(0.35)
HEAD_SCALE :: f32(0.6)
GRAB_RADIUS :: f32(0.4)
PLANE_Y :: f32(0.3)
FLY_SPEED :: f32(16)
DRAG_SPEED :: f32(30)

auto_move := true
auto_speed: f32 = 2.5
propagation: f32 = 0.6
max_bend: f32 = 60
body_links: f32 = 20
body_length: f32 = 10
whisker_links: f32 = 6
whisker_length: f32 = 3

Shape :: struct {
  body_links:    int,
  body_length:   f32,
  whisker_links: int,
  whisker_length: f32,
}

App :: struct {
  platform:      platform.Platform,
  scene:         world.World,
  renderer:      render.Renderer,
  input:         input.State,
  debug:         debugui.Context,
  orbit:         render.Orbit,
  chain:         geometry.Chain([2]f32),
  whiskers:      [2]geometry.Chain([2]f32),
  shape:         Shape,
  head:          world.NodeHandle,
  body_nodes:    [MAX_BODY]world.NodeHandle,
  whisker_nodes: [2][MAX_WHISKER]world.NodeHandle,
  phase:         f32,
  time:          f32,
  grabbed:       bool,
  grab_offset:   [2]f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Chain") do return
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

course :: proc(phase: f32) -> [2]f32 {
  return {6 * math.sin(phase), 4 * math.sin(2 * phase)}
}

rotate :: proc(v: [2]f32, angle: f32) -> [2]f32 {
  c, s := math.cos(angle), math.sin(angle)
  return {v.x * c - v.y * s, v.x * s + v.y * c}
}

yaw :: proc(direction: [2]f32) -> f32 {
  return math.atan2(-direction.y, direction.x)
}

add_box :: proc(parts: ^[dynamic]geometry.Mesh, places: ^[dynamic]geometry.Transform, center, half: [3]f32, color: [4]f32) {
  append(parts, geometry.make_cube(color))
  append(places, geometry.Transform{position = center, rotation = 1, scale = half})
}

build_head :: proc() -> geometry.Mesh {
  parts := make([dynamic]geometry.Mesh, context.temp_allocator)
  places := make([dynamic]geometry.Transform, context.temp_allocator)
  defer for p in parts do geometry.destroy(p)
  ink := [4]f32{0.07, 0.08, 0.1, 1}
  jade := [4]f32{0.12, 0.3, 0.28, 1}
  gold := [4]f32{0.95, 0.75, 0.2, 1}
  white := [4]f32{0.95, 0.95, 0.9, 1}
  add_box(&parts, &places, {0, 0.1, 0}, {0.45, 0.4, 0.5}, ink)
  add_box(&parts, &places, {0.75, 0, 0}, {0.4, 0.25, 0.35}, jade)
  add_box(&parts, &places, {0.65, -0.3, 0}, {0.45, 0.1, 0.3}, ink)
  add_box(&parts, &places, {-0.5, 0.4, 0}, {0.1, 0.15, 0.2}, jade)
  for side in ([2]f32{-1, 1}) {
    add_box(&parts, &places, {1.12, 0.12, side * 0.15}, {0.05, 0.05, 0.05}, white)
    add_box(&parts, &places, {0.35, 0.42, side * 0.28}, {0.15, 0.08, 0.15}, jade)
    add_box(&parts, &places, {0.42, 0.3, side * 0.5}, {0.07, 0.07, 0.04}, gold)
    add_box(&parts, &places, {-0.25, 0.65, side * 0.3}, {0.12, 0.2, 0.1}, gold)
    add_box(&parts, &places, {-0.5, 0.95, side * 0.3}, {0.1, 0.18, 0.08}, gold)
    add_box(&parts, &places, {0.95, -0.15, side * 0.2}, {0.05, 0.1, 0.04}, white)
  }
  return geometry.mesh_merge(parts[:], places[:])
}

spawn_box :: proc(app: ^App, mesh: render.MeshHandle, material: render.MaterialHandle) -> world.NodeHandle {
  return mjolnir.spawn(&app.scene, &app.renderer, render.MeshAttachment{mesh = mesh, material = material, cast_shadow = true})
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  r := &app.renderer
  if !render.ready(r) do return .WAIT
  sun := render.light_create(r, render.make_directional_light())
  mjolnir.spawn(&app.scene, r, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  if !debugui.init(&app.debug, r) do return .FAIL

  mjolnir.spawn(&app.scene, r, render.primitive(r, .QUAD_XZ, .GRAY, cast_shadow = false), {0, -0.01, 0}, scale = 20)

  cube := render.mesh_create(r, geometry.make_cube())
  head := render.mesh_create(r, build_head())
  ink := render.material_create(r, render.make_material(base_color_factor = {0.08, 0.1, 0.12, 1}, roughness_factor = 0.6))
  gold := render.material_create(r, render.make_material(base_color_factor = {0.95, 0.75, 0.2, 1}, metallic_factor = 0.6, roughness_factor = 0.3))
  paint := render.material_create(r, render.make_material(roughness_factor = 0.5))
  app.head = spawn_box(app, head, paint)
  for &n in app.body_nodes do n = spawn_box(app, cube, ink)
  for &side in app.whisker_nodes do for &n in side do n = spawn_box(app, cube, gold)

  start := course(0)
  forward := linalg.normalize(start - course(-0.01))
  app.shape = read_shape()
  shape_build(app, start, forward)

  app.orbit = render.make_orbit({0, 10, 3}, {0, 0, 0})
  return .READY
}

read_shape :: proc() -> Shape {
  return {
    body_links = int(body_links),
    body_length = body_length,
    whisker_links = int(whisker_links),
    whisker_length = whisker_length,
  }
}

hang :: proc(chain: ^geometry.Chain([2]f32), head, direction: [2]f32, links: int, length: f32) {
  step := length / f32(links)
  geometry.chain_init(chain, head, direction, (f32(links) - 1.5) * step, step)
  geometry.chain_hang(chain, head, direction)
}

shape_build :: proc(app: ^App, head, forward: [2]f32) {
  s := app.shape
  hang(&app.chain, head, -forward, s.body_links, s.body_length)
  for &w, i in app.whiskers {
    side := f32(1 - 2 * i)
    hang(&w, head, rotate(forward, side * WHISKER_FAN), s.whisker_links, s.whisker_length)
  }
}

shape_destroy :: proc(app: ^App) {
  geometry.destroy(&app.chain)
  for &w in app.whiskers do geometry.destroy(&w)
}

shutdown :: proc(app: ^App) {
  shape_destroy(app)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "Chain", {20, 20, 260, 370}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "You can grab dragon head and drag")
    mu.checkbox(ctx, "Auto move", &auto_move)
    mu.label(ctx, "Auto speed")
    mu.slider(ctx, &auto_speed, 0.5, 6)
    mu.label(ctx, "Propagation speed")
    mu.slider(ctx, &propagation, 0.01, 1)
    mu.label(ctx, "Max bend (degrees)")
    mu.slider(ctx, &max_bend, 0, 180, 1, "%.0f")
    mu.label(ctx, "Body links")
    mu.slider(ctx, &body_links, 3, MAX_BODY, 1, "%.0f")
    mu.label(ctx, "Body length")
    mu.slider(ctx, &body_length, 1, 20)
    mu.label(ctx, "Whisker links")
    mu.slider(ctx, &whisker_links, 2, MAX_WHISKER, 1, "%.0f")
    mu.label(ctx, "Whisker length")
    mu.slider(ctx, &whisker_length, 0.5, 10)
  }
}

approach :: proc(from, to: [2]f32, distance: f32) -> [2]f32 {
  gap := linalg.distance(from, to)
  if gap <= distance do return to
  return from + (to - from) * (distance / gap)
}

ground_hit :: proc(ray: geometry.Ray) -> (at: [2]f32, ok: bool) {
  p := geometry.ray_plane_intersection(ray, {0, PLANE_Y, 0}, {0, 1, 0}) or_return
  return {p.x, p.z}, true
}

touches_dragon :: proc(app: ^App, ray: geometry.Ray) -> bool {
  head := app.chain.head
  hit, _ := geometry.ray_sphere_intersection(ray, {center = {head.x, HEAD_Y, head.y}, radius = 0.7})
  if hit do return true
  for p in app.chain.points {
    hit, _ = geometry.ray_sphere_intersection(ray, {center = {p.x, BODY_HEIGHT, p.y}, radius = GRAB_RADIUS})
    if hit do return true
  }
  return false
}

update :: proc(app: ^App, dt: f32) {
  r := &app.renderer
  render.lock(r)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)

  free_mouse := !app.input.mouse_captured
  ray, has_ray := render.cursor_ray(r, app.input.cursor)
  if free_mouse && has_ray && input.mouse_pressed(&app.input, .LEFT) && touches_dragon(app, ray) {
    if at, ok := ground_hit(ray); ok {
      app.grabbed = true
      auto_move = false
      app.grab_offset = app.chain.head - at
    }
  }
  if !input.mouse_down(&app.input, .LEFT) do app.grabbed = false
  if !app.grabbed do mjolnir.orbit_drag(&app.orbit, render.main_camera(r), &app.input)

  heading := linalg.normalize0(app.chain.head - app.chain.points[0])
  if heading == {} do heading = {1, 0}
  if shape := read_shape(); shape != app.shape {
    shape_destroy(app)
    app.shape = shape
    shape_build(app, app.chain.head, heading)
  }

  app.time += dt
  target: [2]f32
  if at, ok := ground_hit(ray); app.grabbed && ok {
    target = approach(app.chain.head, at + app.grab_offset, DRAG_SPEED * dt)
  } else if auto_move {
    app.phase += dt * auto_speed * (0.5 + 0.3 * math.sin(app.time))
    target = approach(app.chain.head, course(app.phase), FLY_SPEED * dt)
  } else {
    target = app.chain.head
  }
  geometry.chain_follow(&app.chain, target, propagation, math.to_radians(max_bend))

  heading = linalg.normalize0(app.chain.head - app.chain.points[0])
  if heading == {} do heading = {1, 0}
  for &w, i in app.whiskers {
    side := f32(1 - 2 * i)
    anchor := app.chain.head + heading * 0.6 + rotate(heading, side * math.PI / 2) * 0.2
    geometry.chain_swing(&w, anchor, rotate(heading, side * WHISKER_FAN), 0.88, 0.1, 0.8)
  }
  pose(app, heading)

  mjolnir.update(&app.scene, r, dt)
}

size :: proc(t: f32) -> f32 {
  x := clamp(t / TAPER_SPAN, 0, 1)
  return BODY_HEIGHT * (TAIL_SIZE + (1 - TAIL_SIZE) * x * x * (3 - 2 * x))
}

place :: proc(app: ^App, node: world.NodeHandle, from, to: [2]f32, y, half_height, half_width: f32) {
  direction := to - from
  mid := (from + to) * 0.5
  world.translate(&app.scene, node, {mid.x, y, mid.y})
  world.rotate(&app.scene, node, yaw(direction), [3]f32{0, 1, 0})
  world.scale(&app.scene, node, {linalg.length(direction) * 0.5 * GAP, half_height, half_width})
}

pose :: proc(app: ^App, heading: [2]f32) {
  head := app.chain.head
  world.translate(&app.scene, app.head, {head.x, HEAD_Y, head.y})
  world.rotate(&app.scene, app.head, yaw(heading), [3]f32{0, 1, 0})
  world.scale(&app.scene, app.head, HEAD_SCALE)

  count := len(app.chain.points)
  from := head
  for node, i in app.body_nodes {
    world.set_visible(&app.scene, node, i < count)
    if i >= count do continue
    h := size(1 - f32(i + 1) / f32(count))
    to := app.chain.points[i]
    place(app, node, from, to, h, h, h)
    from = to
  }
  for w, side in app.whiskers {
    links := len(w.points)
    for node, i in app.whisker_nodes[side] {
      world.set_visible(&app.scene, node, i < links)
      if i >= links do continue
      thickness := WHISKER_THICKNESS * (1 - 0.6 * f32(i) / f32(links))
      a := w.head if i == 0 else w.points[i - 1]
      place(app, node, a, w.points[i], WHISKER_Y, thickness, thickness)
    }
  }
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}
