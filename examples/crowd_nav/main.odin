package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/render/mesh"
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
  id:    int, // crowd agent index
  color: [4]f32,
  node:  world.NodeHandle,
}

agents: [AGENT_COUNT]Agent
nav_builder: bake.NavGeometryBuilder
navmesh_node_handle: world.NodeHandle
navmesh: nav.NavMesh
agent_crowd: ^crowd.Crowd

main :: proc() {
  defer {
    crowd.destroy(agent_crowd)
    nav.destroy(&navmesh)
    bake.builder_destroy(&nav_builder)
  }
  mjolnir.run_app({
    title = "Crowd Navigation", width = 1000, height = 700,
    debug_ui = true, setup = setup, update = update, pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  render.main_camera_look_at(&engine.render, {32, 28, 32}, {0, 0, 0})
  mjolnir.spawn(engine, {15, 25, 15}, render.directional_light_attachment({1, 0.97, 0.92, 1}, 10.0, true))
  build_scene(engine)
  build_navmesh(engine)
  visualize_navmesh(engine)
  spawn_agents(engine)
  assign_swap_targets(engine)
}

build_scene :: proc(engine: ^mjolnir.Engine) {
  ground_geom := mesh.make_quad({0.25, 0.55, 0.25, 1})
  for &v in ground_geom.vertices { v.position.x *= WORLD_HALF * 2; v.position.z *= WORLD_HALF * 2 }
  bake.append_triangles(&nav_builder, mesh.positions(ground_geom, context.temp_allocator), ground_geom.indices)
  gm := render.create_mesh(&engine.render, ground_geom)
  gmat := render.create_material(&engine.render, type = .PBR, base_color_factor = {0.25, 0.6, 0.25, 1}, roughness_value = 0.8)
  mjolnir.spawn(engine, {0, 0, 0}, render.MeshAttachment{handle = gm, material = gmat, cast_shadow = false})

  obstacles := [?]struct{pos, size: [3]f32}{
    {{-18, 1.5, -14}, {3, 3, 3}}, {{18, 1.5, -14}, {3, 3, 3}}, {{-18, 1.5, 14}, {3, 3, 3}}, {{18, 1.5, 14}, {3, 3, 3}},
    {{0, 2, 0}, {6, 4, 6}}, {{-6, 1, 22}, {4, 2, 2}}, {{25, 1.5, 0}, {2, 3, 8}}, {{-25, 1.5, 0}, {2, 3, 8}},
    {{32, 1.5, 28}, {3, 3, 3}}, {{-32, 1.5, -28}, {3, 3, 3}}, {{12, 1, -32}, {6, 2, 2}}, {{-12, 1, 32}, {6, 2, 2}},
    {{38, 1.5, -22}, {2, 3, 4}}, {{-38, 1.5, 22}, {2, 3, 4}},
  }
  for o in obstacles {
    g := mesh.make_cube({0.7, 0.2, 0.2, 1})
    for &v in g.vertices { v.position.x *= o.size.x; v.position.y *= o.size.y; v.position.z *= o.size.z }
    bake.append_triangles(&nav_builder, mesh.positions(g, context.temp_allocator), g.indices, o.pos, true)
    mh := render.create_mesh(&engine.render, g)
    mat := render.create_material(&engine.render, type = .PBR, base_color_factor = {0.7, 0.2, 0.2, 1}, roughness_value = 0.6)
    mjolnir.spawn_mesh(engine, mh, mat, o.pos)
  }
}

build_navmesh :: proc(engine: ^mjolnir.Engine) {
  if !bake.build(&navmesh, bake.geometry_view(&nav_builder)) do log.error("navmesh build failed")
}

visualize_navmesh :: proc(engine: ^mjolnir.Engine) {
  world.despawn(&engine.world, navmesh_node_handle)
  positions, indices := nav.debug_triangles(&navmesh, context.temp_allocator)
  for &p in positions do p.y += 0.2 // lift above the ground to avoid z-fighting
  nm_geom := mesh.from_triangles(positions, indices)
  nm_mesh, mesh_ok := render.create_mesh(&engine.render, nm_geom)
  if !mesh_ok do return
  nm_mat, mat_ok := render.create_material(&engine.render, type = .RANDOM_COLOR, base_color_factor = {1, 0.8, 0.3, 0.7})
  if !mat_ok do return
  navmesh_node_handle = mjolnir.spawn_mesh(engine, nm_mesh, nm_mat)
}

random_goal :: proc(engine: ^mjolnir.Engine, away_from: [3]f32) -> [3]f32 {
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

spawn_agents :: proc(engine: ^mjolnir.Engine) {
  ok: bool
  agent_crowd, ok = crowd.create(AGENT_COUNT, AGENT_RADIUS, &navmesh)
  if !ok { log.error("crowd creation failed"); return }
  params := crowd.DEFAULT_AGENT_PARAMS
  params.radius = AGENT_RADIUS
  params.height = AGENT_HEIGHT
  params.max_speed = AGENT_SPEED
  for i in 0 ..< AGENT_COUNT {
    angle := f32(i) / f32(AGENT_COUNT) * math.PI * 2
    r := SPAWN_RADIUS - 4.0
    pos := [3]f32{math.cos(angle) * r, 0, math.sin(angle) * r}
    agents[i].id = crowd.add_agent(agent_crowd, pos, params)
    agents[i].color = palette[i % len(palette)]
    cap_geom := mesh.make_capsule(12, 6, AGENT_HEIGHT, AGENT_RADIUS)
    mh := render.create_mesh(&engine.render, cap_geom)
    mat := render.create_material(&engine.render, type = .PBR, base_color_factor = agents[i].color, emissive_value = 0.4)
    agents[i].node = mjolnir.spawn(engine, pos + {0, AGENT_HEIGHT * 0.5, 0}, render.MeshAttachment{handle = mh, material = mat, cast_shadow = true})
  }
}

assign_swap_targets :: proc(engine: ^mjolnir.Engine) {
  if agent_crowd == nil do return
  for a in agents {
    if a.id < 0 do continue
    crowd.move_to(agent_crowd, a.id, random_goal(engine, crowd.get_agent(agent_crowd, a.id).npos))
  }
}

assign_all_to :: proc(engine: ^mjolnir.Engine, goal: [3]f32) {
  if agent_crowd == nil do return
  for a in agents {
    if a.id >= 0 do crowd.move_to(agent_crowd, a.id, goal)
  }
}

pick_navmesh_point :: proc(engine: ^mjolnir.Engine) -> ([3]f32, bool) {
  ro, rd, ok := mjolnir.cursor_world_ray(engine)
  if !ok do return {}, false
  return nav.raycast(&navmesh, ro, rd)
}

on_mouse_press :: proc(engine: ^mjolnir.Engine) {
  if engine.mouse_captured || !input.mouse_pressed(&engine.input, .RIGHT) do return
  pos, ok := pick_navmesh_point(engine)
  if !ok { log.warn("No navmesh point under cursor"); return }
  assign_all_to(engine, pos)
  log.infof("All agents -> %v", pos)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  on_mouse_press(engine)
  if agent_crowd != nil {
    crowd.update(agent_crowd, dt)
    for a in agents {
      if a.id < 0 do continue
      ag := crowd.get_agent(agent_crowd, a.id)
      world.translate(&engine.world, a.node, ag.npos + {0, AGENT_HEIGHT * 0.5, 0})
      if linalg.length2(ag.vel.xz) > 0.01 {
        world.rotate(&engine.world, a.node, math.atan2(ag.vel.x, ag.vel.z), linalg.VECTOR3F32_Y_AXIS)
      }
      draw_agent_corners(engine, ag, a.color)
    }
  }
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
}

// The agent's next steering corners along its corridor.
draw_agent_corners :: proc(engine: ^mjolnir.Engine, ag: ^crowd.Agent, color: [4]f32) {
  lift := [3]f32{0, 0.15, 0}
  prev := ag.npos + lift
  for p in ag.corner_verts[:ag.ncorners] {
    render.debug_segment(&engine.render, prev, p + lift, color)
    prev = p + lift
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := render.debug_ui(&engine.render)
  if mu.window(ctx, "Crowd", {720, 20, 260, 200}, {.NO_CLOSE}) {
    mu.label(ctx, fmt.tprintf("Agents: %d", AGENT_COUNT))
    mu.label(ctx, "Right-click: set all goals")
    mu.layout_row(ctx, {-1}, 0)
    if .SUBMIT in mu.button(ctx, "Reassign targets") {
      assign_swap_targets(engine)
    }
  }
}
