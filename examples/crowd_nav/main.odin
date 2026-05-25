package main

import "../../mjolnir"
import "../../mjolnir/geometry"
import "../../mjolnir/world"
import nav "../../mjolnir/navigation"
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
SEPARATION_RADIUS :: AGENT_RADIUS * 4
WAYPOINT_TOLERANCE :: f32(0.6)
WORLD_HALF :: f32(50)
SPAWN_RADIUS :: f32(38)
GOAL_MIN_DIST :: f32(20)

Agent :: struct {
  pos, velocity:     [3]f32,
  path:              [][3]f32,
  waypoint_idx:      int,
  goal:              [3]f32,
  color:             [4]f32,
  node:              world.NodeHandle,
}

agents: [AGENT_COUNT]Agent
nav_builder: nav.NavGeometryBuilder
navmesh_node_handle: world.NodeHandle
repath_phase, total_time: f32

main :: proc() {
  mjolnir.run_app({
    title = "Crowd Navigation", width = 1000, height = 700,
    debug_ui = true, setup = setup, update = update, pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(&engine.world, {32, 28, 32}, {0, 0, 0})
  world.spawn_light_directional(&engine.world, {15, 25, 15}, {1, 0.97, 0.92, 1}, 10.0, true)
  build_scene(engine)
  build_navmesh(engine)
  visualize_navmesh(engine)
  spawn_agents(engine)
  assign_swap_targets(engine)
}

build_scene :: proc(engine: ^mjolnir.Engine) {
  ground_geom := geometry.make_quad({0.25, 0.55, 0.25, 1})
  for &v in ground_geom.vertices { v.position.x *= WORLD_HALF * 2; v.position.z *= WORLD_HALF * 2 }
  nav.append_geometry(&nav_builder, ground_geom, {0, 0, 0}, false)
  gm := world.create_mesh(&engine.world, ground_geom)
  gmat := world.create_material(&engine.world, type = .PBR, base_color_factor = {0.25, 0.6, 0.25, 1}, roughness_value = 0.8)
  world.spawn(&engine.world, {0, 0, 0}, world.MeshAttachment{handle = gm, material = gmat, cast_shadow = false})

  obstacles := [?]struct{pos, size: [3]f32}{
    {{-18, 1.5, -14}, {3, 3, 3}}, {{18, 1.5, -14}, {3, 3, 3}}, {{-18, 1.5, 14}, {3, 3, 3}}, {{18, 1.5, 14}, {3, 3, 3}},
    {{0, 2, 0}, {6, 4, 6}}, {{-6, 1, 22}, {4, 2, 2}}, {{25, 1.5, 0}, {2, 3, 8}}, {{-25, 1.5, 0}, {2, 3, 8}},
    {{32, 1.5, 28}, {3, 3, 3}}, {{-32, 1.5, -28}, {3, 3, 3}}, {{12, 1, -32}, {6, 2, 2}}, {{-12, 1, 32}, {6, 2, 2}},
    {{38, 1.5, -22}, {2, 3, 4}}, {{-38, 1.5, 22}, {2, 3, 4}},
  }
  for o in obstacles {
    g := geometry.make_cube({0.7, 0.2, 0.2, 1})
    for &v in g.vertices { v.position.x *= o.size.x; v.position.y *= o.size.y; v.position.z *= o.size.z }
    nav.append_geometry(&nav_builder, g, o.pos, true)
    mh := world.create_mesh(&engine.world, g)
    mat := world.create_material(&engine.world, type = .PBR, base_color_factor = {0.7, 0.2, 0.2, 1}, roughness_value = 0.6)
    world.spawn_mesh(&engine.world, mh, mat, o.pos)
  }
}

build_navmesh :: proc(engine: ^mjolnir.Engine) {
  if !mjolnir.build_navmesh(engine, nav.geometry_view(&nav_builder)) do log.error("navmesh build failed")
}

visualize_navmesh :: proc(engine: ^mjolnir.Engine) {
  world.despawn(&engine.world, navmesh_node_handle)
  nm_geom := nav.build_geometry(&engine.nav.nav_mesh)
  for &v in nm_geom.vertices do v.position.y += 0.2
  nm_geom.aabb = geometry.aabb_from_vertices(nm_geom.vertices)  // lift moved verts
  nm_mesh, mesh_ok := world.create_mesh(&engine.world, nm_geom)
  if !mesh_ok do return
  nm_mat, mat_ok := world.create_material(&engine.world, type = .RANDOM_COLOR, base_color_factor = {1, 0.8, 0.3, 0.7})
  if !mat_ok do return
  navmesh_node_handle = world.spawn_mesh(&engine.world, nm_mesh, nm_mat)
}

random_goal :: proc(engine: ^mjolnir.Engine, away_from: [3]f32) -> [3]f32 {
  extents := [3]f32{4, 6, 4}
  best: [3]f32; best_ok: bool
  for attempt in 0 ..< 32 {
    p := [3]f32{rand.float32_range(-SPAWN_RADIUS, SPAWN_RADIUS), 0, rand.float32_range(-SPAWN_RADIUS, SPAWN_RADIUS)}
    snap, ok := nav.find_nearest_point(&engine.nav, p, extents)
    if !ok do continue
    best = snap; best_ok = true
    if attempt >= 16 || linalg.length(snap - away_from) >= GOAL_MIN_DIST do return snap
  }
  if best_ok do return best
  return away_from
}

palette := [6][4]f32{{1, 0.25, 0.25, 1}, {0.25, 1, 0.25, 1}, {0.4, 0.4, 1, 1}, {1, 0.95, 0.2, 1}, {0.25, 0.95, 0.95, 1}, {1, 0.3, 0.95, 1}}

spawn_agents :: proc(engine: ^mjolnir.Engine) {
  for i in 0 ..< AGENT_COUNT {
    angle := f32(i) / f32(AGENT_COUNT) * math.PI * 2
    r := SPAWN_RADIUS - 4.0
    agents[i].pos = {math.cos(angle) * r, 0, math.sin(angle) * r}
    agents[i].color = palette[i % len(palette)]
    cap_geom := geometry.make_capsule(12, 6, AGENT_HEIGHT, AGENT_RADIUS)
    mh := world.create_mesh(&engine.world, cap_geom)
    mat := world.create_material(&engine.world, type = .PBR, base_color_factor = agents[i].color, emissive_value = 0.4)
    agents[i].node = world.spawn(&engine.world, agents[i].pos + {0, AGENT_HEIGHT * 0.5, 0}, world.MeshAttachment{handle = mh, material = mat, cast_shadow = true})
  }
}

assign_swap_targets :: proc(engine: ^mjolnir.Engine) {
  for i in 0 ..< AGENT_COUNT {
    agents[i].goal = random_goal(engine, agents[i].pos)
    replan(engine, &agents[i])
  }
}

replan :: proc(engine: ^mjolnir.Engine, a: ^Agent) {
  delete(a.path)
  a.path = nav.find_path(&engine.nav, a.pos, a.goal, 128)
  a.waypoint_idx = 0
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  total_time += dt
  repath_phase += dt
  if repath_phase >= 8.0 { repath_phase = 0; assign_swap_targets(engine) }

  for i in 0 ..< AGENT_COUNT {
    a := &agents[i]
    desired_dir := [3]f32{0, 0, 0}
    if len(a.path) > 0 && a.waypoint_idx < len(a.path) {
      target := a.path[a.waypoint_idx]
      diff := target - a.pos; diff.y = 0
      dist := linalg.length(diff)
      if dist < WAYPOINT_TOLERANCE do a.waypoint_idx += 1
      else                         do desired_dir = diff / dist
    }

    sep := [3]f32{0, 0, 0}; n_sep := 0
    for j in 0 ..< AGENT_COUNT {
      if i == j do continue
      diff := a.pos - agents[j].pos; diff.y = 0
      d2 := linalg.length2(diff)
      if d2 < 0.0001 || d2 > SEPARATION_RADIUS * SEPARATION_RADIUS do continue
      d := math.sqrt(d2)
      sep += (diff / d) * (1.0 - d / SEPARATION_RADIUS)
      n_sep += 1
    }
    if n_sep > 0 do sep /= f32(n_sep)

    move := desired_dir + sep * 1.5
    if linalg.length2(move) > 0.0001 {
      move = linalg.normalize(move)
      a.velocity = move * AGENT_SPEED
      a.pos += a.velocity * dt
    } else {
      a.velocity = {0, 0, 0}
    }

    world.translate(&engine.world, a.node, a.pos + {0, AGENT_HEIGHT * 0.5, 0})
    if linalg.length2(a.velocity.xz) > 0.01 {
      yaw := math.atan2(a.velocity.x, a.velocity.z)
      world.rotate(&engine.world, a.node, yaw, linalg.VECTOR3F32_Y_AXIS)
    }
    draw_agent_path(engine, a)
  }
}

draw_agent_path :: proc(engine: ^mjolnir.Engine, a: ^Agent) {
  if len(a.path) == 0 || a.waypoint_idx >= len(a.path) do return
  lift := [3]f32{0, 0.15, 0}
  prev := a.pos + lift
  for i in a.waypoint_idx ..< len(a.path) {
    p := a.path[i] + lift
    mjolnir.debug_segment(engine, prev, p, a.color)
    prev = p
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Crowd", {720, 20, 260, 200}, {.NO_CLOSE}) {
    mu.label(ctx, fmt.tprintf("agents: %d", AGENT_COUNT))
    mu.label(ctx, fmt.tprintf("time: %.1f", total_time))
    mu.label(ctx, fmt.tprintf("next repath in %.1f", 8.0 - repath_phase))
    mu.label(ctx, "")
    mu.layout_row(ctx, {-1}, 0)
    if .SUBMIT in mu.button(ctx, "Reassign targets") {
      assign_swap_targets(engine)
      repath_phase = 0
    }
  }
}
