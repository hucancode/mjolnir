// Navmesh baking and pathfinding: the agent keeps walking to random goals; right-click to pick one.
package main

import "mjolnir"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import nav "mjolnir/navigation"
import "mjolnir/navigation/bake"
import "core:log"
import "core:math/linalg"
import "core:math/rand"

GROUND_HALF_SIZE :: 50
AGENT_SPEED :: 5
AGENT_HALF_HEIGHT :: 1
WAYPOINT_REACHED :: 0.5
MAX_PATH_POINTS :: 256

Box :: struct {
  center, half_extents: [3]f32,
}

OBSTACLES := [?]Box {
  {{-10, 1.5, -10}, {2, 3, 2}},
  {{10, 1.5, -10}, {2, 3, 2}},
  {{-10, 1.5, 10}, {2, 3, 2}},
  {{10, 1.5, 10}, {2, 3, 2}},
  {{0, 2, 0}, {4, 4, 4}},
}

App :: struct {
  platform:       platform.Platform,
  scene:          world.World,
  renderer:       render.Renderer,
  input:          input.State,
  orbit:          render.Orbit,
  navmesh:        nav.NavMesh,
  agent:          world.NodeHandle,
  agent_position: [3]f32,
  goal_marker:    world.NodeHandle,
  path:           [][3]f32,
  next_waypoint:  int,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 800, 600, "Navigation Mesh") do return
  if !render.init(&app.renderer, app.platform.window) do return
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

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.platform)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.platform)
  return render.frame(&app.renderer)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  app.orbit = render.make_orbit({35, 25, 35}, {0, 0, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

  builder: bake.NavGeometryBuilder
  defer bake.destroy(&builder)
  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GREEN, cast_shadow = false))
  world.scale(&app.scene, ground, GROUND_HALF_SIZE)
  bake.append_box(&builder, {0, -0.5, 0}, {GROUND_HALF_SIZE, 0.5, GROUND_HALF_SIZE})
  for box in OBSTACLES {
    obstacle := world.spawn(&app.scene, box.center)
    render.attach(&app.renderer, render.SlotHandle(obstacle.index), render.primitive(&app.renderer, .CUBE, .RED))
    world.scale(&app.scene, obstacle, box.half_extents)
    bake.append_box(&builder, box.center, box.half_extents, is_obstacle = true)
  }
  data, baked := bake.build(&builder, allocator = context.temp_allocator)
  if !baked || !nav.init(&app.navmesh, data) {
    log.error("Failed to build navmesh")
    return .FAIL
  }
  show_navmesh(app)

  app.agent_position = {-20, 0, -20}
  app.agent = world.spawn(&app.scene, app.agent_position + {0, AGENT_HALF_HEIGHT, 0})
  render.attach(&app.renderer, render.SlotHandle(app.agent.index), render.primitive(&app.renderer, .CYLINDER, .BLUE))
  world.scale(&app.scene, app.agent, [3]f32{0.5, AGENT_HALF_HEIGHT, 0.5})
  app.goal_marker = world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(app.goal_marker.index), render.primitive(&app.renderer, .SPHERE, .YELLOW))
  world.scale(&app.scene, app.goal_marker, 0.3)
  go_to(app, {20, 0, 20})
  return .READY
}


show_navmesh :: proc(app: ^App) {
  positions, indices := nav.debug_triangles(&app.navmesh, context.temp_allocator)
  mesh := render.mesh_create(&app.renderer, render.make_geometry_from_triangles(positions, indices))
  material := render.material_create(&app.renderer, render.make_material(type = .RANDOM_COLOR, base_color_factor = {1.0, 0.8, 0.3, 0.3}))
  overlay := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(overlay.index), render.MeshAttachment{mesh = mesh, material = material})
}

shutdown :: proc(app: ^App) {
  delete(app.path)
  nav.destroy(&app.navmesh)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

go_to :: proc(app: ^App, goal: [3]f32) {
  world.translate(&app.scene, app.goal_marker, goal)
  path := nav.find_path(&app.navmesh, app.agent_position, goal, MAX_PATH_POINTS)
  if len(path) == 0 do return
  delete(app.path)
  app.path = path
  app.next_waypoint = 0
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  render.orbit_drag(&app.orbit, &app.input)
  if !app.input.mouse_captured && input.mouse_pressed(&app.input, .RIGHT) {
    ray, _ := render.cursor_ray(&app.renderer, app.input.cursor)
    if goal, on_navmesh := nav.raycast(&app.navmesh, ray); on_navmesh do go_to(app, goal)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  follow_path(app, dt)
  if app.next_waypoint >= len(app.path) do go_to(app, random_goal(app))
  draw_path(app)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

random_goal :: proc(app: ^App) -> [3]f32 {
  for _ in 0 ..< 32 {
    p := [3]f32{rand.float32_range(-GROUND_HALF_SIZE, GROUND_HALF_SIZE), 0, rand.float32_range(-GROUND_HALF_SIZE, GROUND_HALF_SIZE)}
    if goal, ok := nav.nearest_point(&app.navmesh, p, {4, 6, 4}); ok do return goal
  }
  return app.agent_position
}

follow_path :: proc(app: ^App, dt: f32) {
  if app.next_waypoint >= len(app.path) do return
  to_waypoint := app.path[app.next_waypoint] - app.agent_position
  distance := linalg.length(to_waypoint)
  if distance < WAYPOINT_REACHED {
    app.next_waypoint += 1
    return
  }
  app.agent_position += to_waypoint / distance * min(AGENT_SPEED * dt, distance)
  world.translate(&app.scene, app.agent, app.agent_position + {0, AGENT_HALF_HEIGHT, 0})
}

draw_path :: proc(app: ^App) {
  lift := [3]f32{0, 0.15, 0}
  for i in max(app.next_waypoint, 1) ..< len(app.path) {
    render.debug_segment(&app.renderer, app.path[i - 1] + lift, app.path[i] + lift, {1.0, 0.8, 0.0, 1.0})
  }
}
