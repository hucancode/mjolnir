// Detour crowd agents navigating a navmesh.
package main

import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import nav "../../mjolnir/navigation"
import "../../mjolnir/navigation/bake"
import "../../mjolnir/navigation/crowd"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import mu "vendor:microui"

AGENT_COUNT :: 20
AGENT_RADIUS :: f32(0.45)
AGENT_HEIGHT :: f32(1.6)
AGENT_SPEED :: f32(3.2)
WORLD_HALF :: f32(50)
SPAWN_RADIUS :: f32(38)
GOAL_MIN_DIST :: f32(20)
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
  id:     crowd.AgentHandle,
  placed: bool,
  color:  [4]f32,
  node:   world.NodeHandle,
}

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  orbit:    render.Orbit,
  navmesh:  nav.NavMesh,
  crowd:    crowd.Crowd,
  agents:   [AGENT_COUNT]Agent,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1000, 700, "Crowd Navigation") do return
  if !render.init(&app.renderer, "Crowd Navigation", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  render.camera_look_at(render.main_camera(&app.renderer), {32, 28, 32}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer))
  light := world.spawn(&app.scene, {15, 25, 15})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_directional_light({1, 0.97, 0.92})))
  if !build_level(app) {
    log.error("navmesh build failed")
    return .FAIL
  }
  show_navmesh(app)
  if !crowd.init(&app.crowd, AGENT_COUNT, AGENT_RADIUS, &app.navmesh) {
    log.error("crowd creation failed")
    return .FAIL
  }
  spawn_agents(app)
  send_to_random_goals(app)
  return .READY
}

shutdown :: proc(app: ^App) {
  crowd.shutdown(&app.crowd)
  nav.destroy(&app.navmesh)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

build_level :: proc(app: ^App) -> bool {
  builder: bake.NavGeometryBuilder
  defer bake.destroy(&builder)
  ground_material := render.material_create(&app.renderer, render.make_material(type = .PBR, base_color_factor = {0.25, 0.6, 0.25, 1}, roughness_value = 0.8))
  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.MeshAttachment{mesh = app.renderer.builtin_meshes[.QUAD_XZ], material = ground_material})
  world.scale(&app.scene, ground, WORLD_HALF * 2)
  bake_shape(&builder, render.make_quad(), {}, {WORLD_HALF * 2, 1, WORLD_HALF * 2}, is_obstacle = false)
  obstacle_material := render.material_create(&app.renderer, render.make_material(type = .PBR, base_color_factor = {0.7, 0.2, 0.2, 1}, roughness_value = 0.6))
  for box in OBSTACLES {
    obstacle := world.spawn(&app.scene, box.center)
    render.attach(&app.renderer, render.SlotHandle(obstacle.index), render.MeshAttachment{mesh = app.renderer.builtin_meshes[.CUBE], material = obstacle_material, cast_shadow = true})
    world.scale(&app.scene, obstacle, box.half_extents)
    bake_shape(&builder, render.make_cube(), box.center, box.half_extents, is_obstacle = true)
  }
  data := bake.build(&builder, allocator = context.temp_allocator) or_return
  return nav.init(&app.navmesh, data)
}

bake_shape :: proc(builder: ^bake.NavGeometryBuilder, shape: render.Geometry, center, scale: [3]f32, is_obstacle: bool) {
  defer render.destroy(shape)
  positions := render.positions(shape, context.temp_allocator)
  for &p in positions do p *= scale
  bake.append_triangles(builder, positions, shape.indices, center, is_obstacle)
}

show_navmesh :: proc(app: ^App) {
  positions, indices := nav.debug_triangles(&app.navmesh, context.temp_allocator)
  mesh := render.mesh_create(&app.renderer, render.make_geometry_from_triangles(positions, indices))
  material := render.material_create(&app.renderer, render.make_material(type = .RANDOM_COLOR, base_color_factor = {1, 0.8, 0.3, 0.7}))
  overlay := world.spawn(&app.scene, {0, NAVMESH_OVERLAY_LIFT, 0})
  render.attach(&app.renderer, render.SlotHandle(overlay.index), render.MeshAttachment{mesh = mesh, material = material})
}

spawn_agents :: proc(app: ^App) {
  params := crowd.DEFAULT_AGENT_PARAMS
  params.radius = AGENT_RADIUS
  params.height = AGENT_HEIGHT
  params.max_speed = AGENT_SPEED
  capsule := render.mesh_create(&app.renderer, render.make_capsule(12, 6, AGENT_HEIGHT, AGENT_RADIUS))
  materials: [len(PALETTE)]render.MaterialHandle
  for color, i in PALETTE {
    materials[i] = render.material_create(&app.renderer, render.make_material(type = .PBR, base_color_factor = color, emissive_value = 0.4))
  }
  for &a, i in app.agents {
    angle := f32(i) / AGENT_COUNT * math.TAU
    position := (SPAWN_RADIUS - 4) * [3]f32{math.cos(angle), 0, math.sin(angle)}
    a.id, a.placed = crowd.agent_create(&app.crowd, position, params)
    a.color = PALETTE[i % len(PALETTE)]
    a.node = world.spawn(&app.scene, position + {0, AGENT_HEIGHT * 0.5, 0})
    render.attach(&app.renderer, render.SlotHandle(a.node.index), render.MeshAttachment{mesh = capsule, material = materials[i % len(PALETTE)], cast_shadow = true})
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
    if a.placed do crowd.move_to(&app.crowd, a.id, random_goal(app, crowd.agent(&app.crowd, a.id).position))
  }
}

send_all_to :: proc(app: ^App, goal: [3]f32) {
  for a in app.agents {
    if a.placed do crowd.move_to(&app.crowd, a.id, goal)
  }
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
    if input.mouse_pressed(&app.input, .RIGHT) {
      ray, _ := render.cursor_ray(&app.renderer, app.input.cursor)
      if goal, on_navmesh := nav.raycast(&app.navmesh, ray); on_navmesh do send_all_to(app, goal)
    }
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  crowd.update(&app.crowd, dt)
  for a in app.agents {
    if !a.placed do continue
    ag := crowd.agent(&app.crowd, a.id)
    world.translate(&app.scene, a.node, ag.position + {0, AGENT_HEIGHT * 0.5, 0})
    if linalg.length2(ag.velocity.xz) > 0.01 {
      world.rotate(&app.scene, a.node, math.atan2(ag.velocity.x, ag.velocity.z), linalg.VECTOR3F32_Y_AXIS)
    }
    draw_corners(app, ag, a.color)
  }
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

draw_corners :: proc(app: ^App, ag: crowd.Agent, color: [4]f32) {
  ag := ag
  lift := [3]f32{0, 0.15, 0}
  prev := ag.position + lift
  for p in ag.corners[:ag.corner_count] {
    render.debug_segment(&app.renderer, prev, p + lift, color)
    prev = p + lift
  }
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Crowd", {720, 20, 260, 200}, {.NO_CLOSE}) {
    mu.label(ctx, fmt.tprintf("Agents: %d", AGENT_COUNT))
    mu.label(ctx, "Right-click: set all goals")
    mu.layout_row(ctx, {-1}, 0)
    if .SUBMIT in mu.button(ctx, "Reassign targets") do send_to_random_goals(app)
  }
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
