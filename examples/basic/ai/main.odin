// Guards with a behavior tree for a brain and a state machine for a body: patrol, chase, search, return. Right-click to move the intruder.
package main

import "core:log"
import "core:math/linalg"
import "core:math/rand"
import "mjolnir"
import bt "mjolnir/behavior_tree"
import "mjolnir/fsm"
import "mjolnir/geometry"
import "mjolnir/input"
import nav "mjolnir/navigation"
import "mjolnir/navigation/bake"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

ARENA :: 20
HALF_HEIGHT :: 0.8
SIGHT :: 9
CATCH :: 1.2
SEARCH_TIME :: 2.5
REPATH :: 0.4
WAYPOINT_REACHED :: 0.3

Box :: struct {
  center, half_extents: [3]f32,
}

WALLS := [?]Box {
  {{-8, 1.5, -6}, {1, 1.5, 5}},
  {{8, 1.5, 6}, {1, 1.5, 5}},
  {{0, 1.5, 12}, {5, 1.5, 1}},
  {{0, 1.5, -12}, {5, 1.5, 1}},
  {{0, 1.5, 0}, {2, 1.5, 2}},
}

ROUTES := [?][2][3]f32 {
  {{-15, 0, -15}, {-15, 0, 15}},
  {{15, 0, 15}, {15, 0, -15}},
  {{-10, 0, 16}, {10, 0, 16}},
  {{10, 0, -16}, {-10, 0, -16}},
}

Mode :: enum {
  PATROL,
  CHASE,
  SEARCH,
  RETURN,
}

MODE_COLORS := [Mode]render.Color {
  .PATROL = .GREEN,
  .CHASE  = .RED,
  .SEARCH = .YELLOW,
  .RETURN = .CYAN,
}

SIGHT_COLORS := [Mode][4]f32 {
  .PATROL = render.COLOR_RGB[.GREEN],
  .CHASE  = render.COLOR_RGB[.RED],
  .SEARCH = render.COLOR_RGB[.YELLOW],
  .RETURN = render.COLOR_RGB[.CYAN],
}

MODES := [Mode]fsm.State(Guard, Mode) {
  .PATROL = {enter = enter_patrol, update = update_patrol},
  .CHASE  = {enter = enter_chase, update = update_chase},
  .SEARCH = {enter = enter_search, update = update_search},
  .RETURN = {enter = enter_return, update = update_return},
}

Condition :: bt.Condition(Guard)
Action :: bt.Action(Guard)
Sequence :: bt.Sequence(Guard)
Behavior :: bt.Behavior(Guard)

BRAIN := Behavior(Sequence{{
  Condition{"sees_intruder", sees_intruder, {Action{"chase", chase}}},
  Condition{"has_lead", has_lead, {Action{"search", search}}},
  Condition{"off_route", off_route, {Action{"go_back", go_back}}},
  Action{"patrol", patrol},
}})

Walker :: struct {
  node:     world.NodeHandle,
  position: [3]f32,
  path:     [][3]f32,
  next:     int,
}

Guard :: struct {
  using walker: Walker,
  app:          ^App,
  machine:      fsm.Machine(Mode),
  wants:        Mode,
  route:        [2][3]f32,
  leg:          int,
  last_seen:    [3]f32,
  has_lead:     bool,
  repath:       f32,
}

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  orbit:    render.Orbit,
  navmesh:  nav.NavMesh,
  intruder: Walker,
  guards:   [len(ROUTES)]Guard,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "AI") do return
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  app.orbit = render.make_orbit({0, 24, 17}, {0, 0, 0})

  builder: bake.NavGeometryBuilder
  defer bake.destroy(&builder)
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, no_shadow = true), scale = ARENA)
  bake.append_box(&builder, {0, -0.5, 0}, {ARENA, 0.5, ARENA})
  for wall in WALLS {
    mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, .WHITE), wall.center, scale = wall.half_extents)
    bake.append_box(&builder, wall.center, wall.half_extents, area = bake.AREA_BLOCKED)
  }
  data, baked := bake.build(&builder, allocator = context.temp_allocator)
  if !baked || !nav.navmesh_init(&app.navmesh, data) {
    log.error("Failed to build navmesh")
    return .FAIL
  }

  app.intruder.node = mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .SPHERE, .MAGENTA), scale = 0.6)

  for &g, i in app.guards {
    g.app = app
    g.route = ROUTES[i]
    g.position = g.route[0]
    g.node = world.spawn(&app.scene, g.position + {0, HALF_HEIGHT, 0}, scale = {0.5, HALF_HEIGHT, 0.5})
    fsm.start(&g.machine, MODES, &g, .PATROL)
  }
  respawn_intruder(app)
  return .READY
}

shutdown :: proc(app: ^App) {
  delete(app.intruder.path)
  for &g in app.guards do delete(g.path)
  nav.destroy(&app.navmesh)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  if !app.input.mouse_captured && input.mouse_pressed(&app.input, .RIGHT) {
    ray, _ := render.cursor_ray(&app.renderer, app.input.cursor)
    if goal, on_navmesh := nav.raycast(&app.navmesh, ray); on_navmesh do walk_to(app, &app.intruder, goal)
  }
  if !walk(app, &app.intruder, 5, dt, 0.6) do walk_to(app, &app.intruder, random_point(app))
  for &g in app.guards {
    bt.tick(BRAIN, &g)
    fsm.update(&g.machine, MODES, &g, dt)
    color := SIGHT_COLORS[g.machine.current]
    render.debug_circle(&app.renderer, g.position + {0, 0.05, 0}, {0, 1, 0}, SIGHT, color)
    if g.has_lead do render.debug_segment(&app.renderer, g.position + {0, 0.1, 0}, g.last_seen + {0, 0.1, 0}, color)
    if linalg.length(g.position - app.intruder.position) < CATCH do caught(app)
  }
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

caught :: proc(app: ^App) {
  respawn_intruder(app)
  for &g in app.guards {
    if g.machine.current == .PATROL do continue
    g.has_lead = false
    g.wants = .RETURN
    fsm.change(&g.machine, MODES, &g, .RETURN)
  }
}

respawn_intruder :: proc(app: ^App) {
  app.intruder.position = random_point(app)
  for _ in 0 ..< 32 {
    if !in_sight_of_any(app, app.intruder.position) do break
    app.intruder.position = random_point(app)
  }
  delete(app.intruder.path)
  app.intruder.path = nil
  world.transform(&app.scene, app.intruder.node).position = app.intruder.position + {0, 0.6, 0}
}

random_point :: proc(app: ^App) -> [3]f32 {
  for _ in 0 ..< 32 {
    p := [3]f32{rand.float32_range(-ARENA, ARENA), 0, rand.float32_range(-ARENA, ARENA)} * 0.9
    if point, ok := nav.nearest_point(&app.navmesh, p, {1, 4, 1}); ok do return point
  }
  return {}
}

in_sight_of_any :: proc(app: ^App, point: [3]f32) -> bool {
  for g in app.guards do if linalg.length(g.position - point) < SIGHT + 2 do return true
  return false
}

walk_to :: proc(app: ^App, w: ^Walker, goal: [3]f32) {
  path := nav.find_path(&app.navmesh, w.position, goal)
  if len(path) == 0 do return
  delete(w.path)
  w.path = path
  w.next = 0
}

walk :: proc(app: ^App, w: ^Walker, speed, dt: f32, lift: f32 = HALF_HEIGHT) -> (moving: bool) {
  nav.follow(w.path, &w.next, &w.position, speed * dt, WAYPOINT_REACHED) or_return
  world.transform(&app.scene, w.node).position = w.position + {0, lift, 0}
  return true
}

paint :: proc(g: ^Guard, mode: Mode) {
  app := g.app
  render.attach(&app.renderer, g.node, render.primitive(&app.renderer, .CYLINDER, MODE_COLORS[mode]))
}

sees_intruder :: proc(g: ^Guard) -> bool {
  eye := g.position + {0, 1, 0}
  to_target := g.app.intruder.position + {0, 1, 0} - eye
  distance := linalg.length(to_target)
  if distance > SIGHT do return false
  inv_dir := 1 / (to_target / distance)
  for wall in WALLS {
    near, far := geometry.ray_aabb_intersection(eye, inv_dir, {wall.center - wall.half_extents, wall.center + wall.half_extents})
    if near <= far && far > 0 && near < distance do return false
  }
  return true
}

chase :: proc(g: ^Guard) -> bt.Status {
  g.last_seen = g.app.intruder.position
  g.has_lead = true
  g.wants = .CHASE
  return .RUNNING
}

has_lead :: proc(g: ^Guard) -> bool {
  return g.has_lead
}

search :: proc(g: ^Guard) -> bt.Status {
  if g.machine.current == .SEARCH && g.machine.time > SEARCH_TIME && g.next >= len(g.path) {
    g.has_lead = false
    return .SUCCESS
  }
  g.wants = .SEARCH
  return .RUNNING
}

off_route :: proc(g: ^Guard) -> bool {
  return g.machine.current != .PATROL && g.machine.current != .RETURN || g.machine.current == .RETURN && g.next < len(g.path)
}

go_back :: proc(g: ^Guard) -> bt.Status {
  g.wants = .RETURN
  return .RUNNING
}

patrol :: proc(g: ^Guard) -> bt.Status {
  g.wants = .PATROL
  return .RUNNING
}

enter_patrol :: proc(g: ^Guard) {
  paint(g, .PATROL)
  walk_to(g.app, g, g.route[g.leg])
}

update_patrol :: proc(g: ^Guard, dt: f32) -> Mode {
  if !walk(g.app, g, 3, dt) {
    g.leg = 1 - g.leg
    walk_to(g.app, g, g.route[g.leg])
  }
  return g.wants
}

enter_chase :: proc(g: ^Guard) {
  paint(g, .CHASE)
  g.repath = 0
}

update_chase :: proc(g: ^Guard, dt: f32) -> Mode {
  g.repath -= dt
  if g.repath <= 0 {
    g.repath = REPATH
    walk_to(g.app, g, g.last_seen)
  }
  walk(g.app, g, 4.5, dt)
  return g.wants
}

enter_search :: proc(g: ^Guard) {
  paint(g, .SEARCH)
  walk_to(g.app, g, g.last_seen)
}

update_search :: proc(g: ^Guard, dt: f32) -> Mode {
  walk(g.app, g, 3.5, dt)
  return g.wants
}

enter_return :: proc(g: ^Guard) {
  paint(g, .RETURN)
  g.leg = linalg.length(g.route[0] - g.position) < linalg.length(g.route[1] - g.position) ? 0 : 1
  walk_to(g.app, g, g.route[g.leg])
}

update_return :: proc(g: ^Guard, dt: f32) -> Mode {
  walk(g.app, g, 3, dt)
  return g.wants
}
