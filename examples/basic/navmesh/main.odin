// Navmesh baking and pathfinding: the agent keeps walking to random goals; right-click to pick one.
package main

import "core:log"
import "core:math/linalg"
import "core:math/rand"
import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/input"
import nav "mjolnir/navigation"
import "mjolnir/navigation/bake"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

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
  if !platform.init(&app.platform, 1280, 720, "Navigation Mesh") do return
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

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  app.orbit = render.make_orbit({35, 25, 35}, {0, 0, 0})

  builder: bake.NavGeometryBuilder
  defer bake.destroy(&builder)
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GREEN, cast_shadow = false), scale = GROUND_HALF_SIZE)
  bake.append_box(&builder, {0, -0.5, 0}, {GROUND_HALF_SIZE, 0.5, GROUND_HALF_SIZE})
  for box in OBSTACLES {
    mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, .RED), box.center, scale = box.half_extents)
    bake.append_box(&builder, box.center, box.half_extents, area = bake.AREA_BLOCKED)
  }
  data, baked := bake.build(&builder, allocator = context.temp_allocator)
  if !baked || !nav.navmesh_init(&app.navmesh, data) {
    log.error("Failed to build navmesh")
    return .FAIL
  }
  show_navmesh(app)

  app.agent_position = {-20, 0, -20}
  app.agent = mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CYLINDER, .BLUE), app.agent_position + {0, AGENT_HALF_HEIGHT, 0}, scale = {0.5, AGENT_HALF_HEIGHT, 0.5})
  app.goal_marker = mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .SPHERE, .YELLOW), scale = 0.3)
  go_to(app, {20, 0, 20})
  return .READY
}

show_navmesh :: proc(app: ^App) {
  positions, indices := nav.debug_triangles(&app.navmesh, context.temp_allocator)
  mesh := render.mesh_create(&app.renderer, geometry.make_mesh_from_triangles(positions, indices))
  material := render.material_create(&app.renderer, render.make_material(type = .RANDOM_COLOR, base_color_factor = {1.0, 0.8, 0.3, 0.3}))
  mjolnir.spawn(&app.scene, &app.renderer, render.MeshAttachment{mesh = mesh, material = material})
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
  platform.read_input(&app.platform, &app.input)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  if !app.input.mouse_captured && input.mouse_pressed(&app.input, .RIGHT) {
    ray, _ := render.cursor_ray(&app.renderer, app.input.cursor)
    if goal, on_navmesh := nav.raycast(&app.navmesh, ray); on_navmesh do go_to(app, goal)
  }
  follow_path(app, dt)
  if app.next_waypoint >= len(app.path) do go_to(app, random_goal(app))
  draw_path(app)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

random_goal :: proc(app: ^App) -> [3]f32 {
  for _ in 0 ..< 32 {
    p := [3]f32{rand.float32_range(-GROUND_HALF_SIZE, GROUND_HALF_SIZE), 0, rand.float32_range(-GROUND_HALF_SIZE, GROUND_HALF_SIZE)}
    if goal, ok := nav.nearest_point(&app.navmesh, p, {4, 6, 4}); ok do return goal
  }
  return app.agent_position
}

follow_path :: proc(app: ^App, dt: f32) {
  if !nav.follow(app.path, &app.next_waypoint, &app.agent_position, AGENT_SPEED * dt, WAYPOINT_REACHED) do return
  world.translate(&app.scene, app.agent, app.agent_position + {0, AGENT_HALF_HEIGHT, 0})
}

draw_path :: proc(app: ^App) {
  lift := [3]f32{0, 0.15, 0}
  for i in max(app.next_waypoint, 1) ..< len(app.path) {
    render.debug_segment(&app.renderer, app.path[i - 1] + lift, app.path[i] + lift, {1.0, 0.8, 0.0, 1.0})
  }
}
