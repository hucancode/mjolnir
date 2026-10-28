// Crowd agents steering along navmesh paths around each other, each picking a new goal on arrival.
package main

import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import nav "mjolnir/navigation"
import "mjolnir/navigation/bake"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import mu "vendor:microui"
import "mjolnir/geometry"

AGENT_COUNT :: 20
AGENT_RADIUS :: f32(0.45)
AGENT_HEIGHT :: f32(1.6)
AGENT_SPEED :: f32(3.2)
WORLD_HALF :: f32(50)
SPAWN_RADIUS :: f32(38)
GOAL_MIN_DIST :: f32(20)
GOAL_REACHED :: f32(1.5)
NAVMESH_OVERLAY_LIFT :: f32(0.2)

Box :: struct {
  center, half_extents: [3]f32,
}

OBSTACLES := [?]Box {
  {{-18, 1.5, -14}, {3, 3, 3}}, {{18, 1.5, -14}, {3, 3, 3}}, {{-18, 1.5, 14}, {3, 3, 3}}, {{18, 1.5, 14}, {3, 3, 3}},
  {{0, 2, 0}, {6, 4, 6}}, {{-6, 1, 22}, {4, 2, 2}}, {{25, 1.5, 0}, {2, 3, 8}}, {{-25, 1.5, 0}, {2, 3, 8}},
  {{32, 1.5, 28}, {3, 3, 3}}, {{-32, 1.5, -28}, {3, 3, 3}}, {{12, 1, -32}, {6, 2, 2}}, {{-12, 1, 32}, {6, 2, 2}},
  {{38, 1.5, -22}, {2, 3, 4}}, {{-38, 1.5, 22}, {2, 3, 4}},
}

PALETTE := [?][4]f32{{1, 0.25, 0.25, 1}, {0.25, 1, 0.25, 1}, {0.4, 0.4, 1, 1}, {1, 0.95, 0.2, 1}, {0.25, 0.95, 0.95, 1}, {1, 0.3, 0.95, 1}}

Agent :: struct {
  handle: nav.AgentHandle,
  placed: bool,
  color:  [4]f32,
}

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  orbit:    render.Orbit,
  navmesh:  nav.NavMesh,
  crowd:    nav.Crowd,
  agents:   [AGENT_COUNT]Agent,
  wander:   bool,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.wander = true
  if !platform.init(&app.platform, 1280, 720, "Crowd Navigation") do return
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
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.orbit = render.make_orbit({32, 28, 32}, {0, 0, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  if !build_level(app) {
    log.error("navmesh build failed")
    return .FAIL
  }
  show_navmesh(app)
  if !nav.crowd_init(&app.crowd, AGENT_COUNT, AGENT_RADIUS, &app.navmesh) {
    log.error("crowd creation failed")
    return .FAIL
  }
  spawn_agents(app)
  send_to_random_goals(app)
  return .READY
}

shutdown :: proc(app: ^App) {
  nav.crowd_destroy(&app.crowd)
  nav.destroy(&app.navmesh)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

build_level :: proc(app: ^App) -> bool {
  builder: bake.NavGeometryBuilder
  defer bake.destroy(&builder)
  ground_material := render.material_create(&app.renderer, render.make_material(type = .PBR, base_color_factor = {0.25, 0.6, 0.25, 1}, roughness_value = 0.8))
  mjolnir.spawn_mesh(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, ground_material, cast_shadow = false), scale = WORLD_HALF * 2)
  bake.append_box(&builder, {0, -0.5, 0}, {WORLD_HALF * 2, 0.5, WORLD_HALF * 2})
  obstacle_material := render.material_create(&app.renderer, render.make_material(type = .PBR, base_color_factor = {0.7, 0.2, 0.2, 1}, roughness_value = 0.6))
  for box in OBSTACLES {
    mjolnir.spawn_mesh(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, obstacle_material), box.center, scale = box.half_extents)
    bake.append_box(&builder, box.center, box.half_extents, area = bake.AREA_BLOCKED)
  }
  data := bake.build(&builder, allocator = context.temp_allocator) or_return
  return nav.navmesh_init(&app.navmesh, data)
}

show_navmesh :: proc(app: ^App) {
  positions, indices := nav.debug_triangles(&app.navmesh, context.temp_allocator)
  mesh := render.mesh_create(&app.renderer, geometry.make_mesh_from_triangles(positions, indices))
  material := render.material_create(&app.renderer, render.make_material(type = .RANDOM_COLOR, base_color_factor = {1, 0.8, 0.3, 0.7}))
  overlay := world.spawn(&app.scene, {0, NAVMESH_OVERLAY_LIFT, 0})
  render.attach(&app.renderer, overlay, render.MeshAttachment{mesh = mesh, material = material})
}

spawn_agents :: proc(app: ^App) {
  params := nav.DEFAULT_AGENT_PARAMS
  params.radius = AGENT_RADIUS
  params.height = AGENT_HEIGHT
  params.max_speed = AGENT_SPEED
  capsule := render.mesh_create(&app.renderer, geometry.make_capsule(12, 6, AGENT_HEIGHT, AGENT_RADIUS))
  materials: [len(PALETTE)]render.MaterialHandle
  for color, i in PALETTE {
    materials[i] = render.material_create(&app.renderer, render.make_material(type = .PBR, base_color_factor = color, emissive_value = 0.4))
  }
  for &a, i in app.agents {
    angle := f32(i) / AGENT_COUNT * math.TAU
    position := (SPAWN_RADIUS - 4) * [3]f32{math.cos(angle), 0, math.sin(angle)}
    node := world.spawn(&app.scene, position)
    body := world.spawn(&app.scene, {0, AGENT_HEIGHT * 0.5, 0}, parent = node)
    render.attach(&app.renderer, body, render.MeshAttachment{mesh = capsule, material = materials[i % len(PALETTE)], cast_shadow = true})
    a.handle, a.placed = nav.agent_create(&app.crowd, position, params, user = world.Handle(node))
    a.color = PALETTE[i % len(PALETTE)]
  }
}

random_goal :: proc(app: ^App, away_from: [3]f32) -> [3]f32 {
  goal := away_from
  for attempt in 0 ..< 32 {
    p := [3]f32{rand.float32_range(-SPAWN_RADIUS, SPAWN_RADIUS), 0, rand.float32_range(-SPAWN_RADIUS, SPAWN_RADIUS)}
    snapped := nav.nearest_point(&app.navmesh, p, {4, 6, 4}) or_continue
    goal = snapped
    if attempt >= 16 || linalg.length(snapped - away_from) >= GOAL_MIN_DIST do break
  }
  return goal
}

send_to_random_goals :: proc(app: ^App) {
  for a in app.agents {
    if a.placed do nav.move_to(&app.crowd, a.handle, random_goal(app, nav.agent(&app.crowd, a.handle).position))
  }
}

reassign_arrived :: proc(app: ^App) {
  for a in app.agents {
    if !a.placed do continue
    ag := nav.agent(&app.crowd, a.handle)
    if linalg.length(ag.target - ag.position) < GOAL_REACHED do nav.move_to(&app.crowd, a.handle, random_goal(app, ag.position))
  }
}

send_all_to :: proc(app: ^App, goal: [3]f32) {
  for a in app.agents {
    if a.placed do nav.move_to(&app.crowd, a.handle, goal)
  }
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  render.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  if !app.input.mouse_captured && input.mouse_pressed(&app.input, .RIGHT) {
    ray, _ := render.cursor_ray(&app.renderer, app.input.cursor)
    if goal, on_navmesh := nav.raycast(&app.navmesh, ray); on_navmesh do send_all_to(app, goal)
  }
  if app.wander do reassign_arrived(app)
  nav.crowd_update(&app.crowd, dt)
  world.set_world_poses(&app.scene, nav.agent_poses(&app.crowd))
  for a in app.agents do if a.placed do draw_corners(app, nav.agent(&app.crowd, a.handle), a.color)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw_corners :: proc(app: ^App, ag: nav.Agent, color: [4]f32) {
  ag := ag
  lift := [3]f32{0, 0.15, 0}
  prev := ag.position + lift
  for p in ag.corners[:ag.corner_count] {
    render.debug_segment(&app.renderer, prev, p + lift, color)
    prev = p + lift
  }
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Crowd", {20, 20, 260, 230}, {}) {
    mu.label(ctx, fmt.tprintf("Agents: %d", AGENT_COUNT))
    mu.label(ctx, "Right-click: set all goals")
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Pick new goal on arrival", &app.wander)
    if .SUBMIT in mu.button(ctx, "Reassign targets") do send_to_random_goals(app)
  }
}
