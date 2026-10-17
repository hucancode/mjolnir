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

// Scene-side view of a crowd agent; steering, avoidance and path following
// run in navigation/crowd.
Agent :: struct {
  id:     crowd.AgentHandle,
  placed: bool, // agent_create found room on the mesh
  color: [4]f32,
  node:  world.NodeHandle,
}

agents: [AGENT_COUNT]Agent
nav_builder: bake.NavGeometryBuilder
navmesh_node_handle: world.NodeHandle
navmesh: nav.NavMesh
agent_crowd: ^crowd.Crowd

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
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

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {32, 28, 32}, {0, 0, 0})

  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  light := world.spawn(&app.scene, {15, 25, 15})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_directional_light({1, 0.97, 0.92, 1}, 10.0, true)))
  build_scene(app)
  build_navmesh(app)
  visualize_navmesh(app)
  spawn_agents(app)
  assign_swap_targets(app)
  return true
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
  if agent_crowd != nil do crowd.shutdown(agent_crowd)
  free(agent_crowd)
  nav.destroy(&navmesh)
  bake.builder_destroy(&nav_builder)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

build_scene :: proc(app: ^App) {
  ground_geom := render.make_quad({0.25, 0.55, 0.25, 1})
  for &v in ground_geom.vertices { v.position.x *= WORLD_HALF * 2; v.position.z *= WORLD_HALF * 2 }
  bake.append_triangles(&nav_builder, render.positions(ground_geom, context.temp_allocator), ground_geom.indices)
  gm := render.mesh_create(&app.renderer, ground_geom)
  gmat := render.material_create(&app.renderer, render.make_material(type = .PBR, base_color_factor = {0.25, 0.6, 0.25, 1}, roughness_value = 0.8))
  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.MeshAttachment{mesh = gm, material = gmat, cast_shadow = false})

  obstacles := [?]struct{pos, size: [3]f32}{
    {{-18, 1.5, -14}, {3, 3, 3}}, {{18, 1.5, -14}, {3, 3, 3}}, {{-18, 1.5, 14}, {3, 3, 3}}, {{18, 1.5, 14}, {3, 3, 3}},
    {{0, 2, 0}, {6, 4, 6}}, {{-6, 1, 22}, {4, 2, 2}}, {{25, 1.5, 0}, {2, 3, 8}}, {{-25, 1.5, 0}, {2, 3, 8}},
    {{32, 1.5, 28}, {3, 3, 3}}, {{-32, 1.5, -28}, {3, 3, 3}}, {{12, 1, -32}, {6, 2, 2}}, {{-12, 1, 32}, {6, 2, 2}},
    {{38, 1.5, -22}, {2, 3, 4}}, {{-38, 1.5, 22}, {2, 3, 4}},
  }
  for o in obstacles {
    g := render.make_cube({0.7, 0.2, 0.2, 1})
    for &v in g.vertices { v.position.x *= o.size.x; v.position.y *= o.size.y; v.position.z *= o.size.z }
    bake.append_triangles(&nav_builder, render.positions(g, context.temp_allocator), g.indices, o.pos, true)
    mh := render.mesh_create(&app.renderer, g)
    mat := render.material_create(&app.renderer, render.make_material(type = .PBR, base_color_factor = {0.7, 0.2, 0.2, 1}, roughness_value = 0.6))
    n := world.spawn(&app.scene, o.pos)
    render.attach(&app.renderer, render.SlotHandle(n.index), render.MeshAttachment{mesh = mh, material = mat, cast_shadow = true})
  }
}

build_navmesh :: proc(app: ^App) {
  data, ok := bake.build(&nav_builder, allocator = context.temp_allocator)
  if !ok || !nav.init(&navmesh, data) do log.error("navmesh build failed")
}

visualize_navmesh :: proc(app: ^App) {
  world.destroy(&app.scene, navmesh_node_handle)
  positions, indices := nav.debug_triangles(&navmesh, context.temp_allocator)
  for &p in positions do p.y += 0.2 // lift above the ground to avoid z-fighting
  nm_geom := render.make_geometry_from_triangles(positions, indices)
  nm_mesh, mesh_ok := render.mesh_create(&app.renderer, nm_geom)
  if !mesh_ok do return
  nm_mat, mat_ok := render.material_create(&app.renderer, render.make_material(type = .RANDOM_COLOR, base_color_factor = {1, 0.8, 0.3, 0.7}))
  if !mat_ok do return
  navmesh_node_handle = world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(navmesh_node_handle.index), render.MeshAttachment{mesh = nm_mesh, material = nm_mat, cast_shadow = true})
}

random_goal :: proc(app: ^App, away_from: [3]f32) -> [3]f32 {
  extents := [3]f32{4, 6, 4}
  best: [3]f32; best_ok: bool
  for attempt in 0 ..< 32 {
    p := [3]f32{rand.float32_range(-SPAWN_RADIUS, SPAWN_RADIUS), 0, rand.float32_range(-SPAWN_RADIUS, SPAWN_RADIUS)}
    snap, ok := nav.nearest_point(&navmesh, p, extents)
    if !ok do continue
    best = snap; best_ok = true
    if attempt >= 16 || linalg.length(snap - away_from) >= GOAL_MIN_DIST do return snap
  }
  if best_ok do return best
  return away_from
}

palette := [6][4]f32{{1, 0.25, 0.25, 1}, {0.25, 1, 0.25, 1}, {0.4, 0.4, 1, 1}, {1, 0.95, 0.2, 1}, {0.25, 0.95, 0.95, 1}, {1, 0.3, 0.95, 1}}

spawn_agents :: proc(app: ^App) {
  agent_crowd = new(crowd.Crowd)
  if !crowd.init(agent_crowd, AGENT_COUNT, AGENT_RADIUS, &navmesh.detour_mesh) {
    log.error("crowd creation failed")
    free(agent_crowd)
    agent_crowd = nil
    return
  }
  params := crowd.DEFAULT_AGENT_PARAMS
  params.radius = AGENT_RADIUS
  params.height = AGENT_HEIGHT
  params.max_speed = AGENT_SPEED
  for i in 0 ..< AGENT_COUNT {
    angle := f32(i) / f32(AGENT_COUNT) * math.PI * 2
    r := SPAWN_RADIUS - 4.0
    pos := [3]f32{math.cos(angle) * r, 0, math.sin(angle) * r}
    // -1 when off the mesh: the agent is skipped
    agents[i].id, agents[i].placed = crowd.agent_create(agent_crowd, pos, params)
    agents[i].color = palette[i % len(palette)]
    cap_geom := render.make_capsule(12, 6, AGENT_HEIGHT, AGENT_RADIUS)
    mh := render.mesh_create(&app.renderer, cap_geom)
    mat := render.material_create(&app.renderer, render.make_material(type = .PBR, base_color_factor = agents[i].color, emissive_value = 0.4))
    agents[i].node = world.spawn(&app.scene, pos + {0, AGENT_HEIGHT * 0.5, 0})
    render.attach(&app.renderer, render.SlotHandle(agents[i].node.index), render.MeshAttachment{mesh = mh, material = mat, cast_shadow = true})
  }
}

assign_swap_targets :: proc(app: ^App) {
  if agent_crowd == nil do return
  for a in agents {
    if !a.placed do continue
    crowd.move_to(agent_crowd, a.id, random_goal(app, crowd.agent(agent_crowd, a.id).position))
  }
}

assign_all_to :: proc(app: ^App, goal: [3]f32) {
  if agent_crowd == nil do return
  for a in agents {
    if a.placed do crowd.move_to(agent_crowd, a.id, goal)
  }
}

pick_navmesh_point :: proc(app: ^App) -> ([3]f32, bool) {
  ray, ok := render.cursor_ray(&app.renderer, app.input.cursor)
  if !ok do return {}, false
  return nav.raycast(&navmesh, ray)
}

on_mouse_press :: proc(app: ^App) {
  if app.input.mouse_captured || !input.mouse_pressed(&app.input, .RIGHT) do return
  pos, ok := pick_navmesh_point(app)
  if !ok { log.warn("No navmesh point under cursor"); return }
  assign_all_to(app, pos)
  log.infof("All agents -> %v", pos)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  on_mouse_press(app)
  if agent_crowd != nil {
    crowd.update(agent_crowd, dt)
    for a in agents {
      if !a.placed do continue
      ag := crowd.agent(agent_crowd, a.id)
      world.translate(&app.scene, a.node, ag.position + {0, AGENT_HEIGHT * 0.5, 0})
      if linalg.length2(ag.velocity.xz) > 0.01 {
        world.rotate(&app.scene, a.node, math.atan2(ag.velocity.x, ag.velocity.z), linalg.VECTOR3F32_Y_AXIS)
      }
      draw_agent_corners(app, ag, a.color)
    }
  }
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

// The agent's next steering corners along its corridor.
draw_agent_corners :: proc(app: ^App, ag: crowd.Agent, color: [4]f32) {
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
    if .SUBMIT in mu.button(ctx, "Reassign targets") {
      assign_swap_targets(app)
    }
  }
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
