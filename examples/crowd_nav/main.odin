package main

import "../../mjolnir"
import "../../mjolnir/geometry"
import nav "../../mjolnir/navigation"
import "../../mjolnir/navigation/recast"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import mu "vendor:microui"

// Lightweight multi-agent navigation: each agent owns an independent path
// produced by mjolnir.navigation.find_path and applies local separation against
// neighbours. The full Detour `crowd` module isn't built in this codebase, so
// this layer demonstrates the same idea with the primitives that do compile.

AGENT_COUNT :: 20
AGENT_RADIUS :: f32(0.45)
AGENT_HEIGHT :: f32(1.6)
AGENT_SPEED :: f32(3.2)
SEPARATION_RADIUS :: AGENT_RADIUS * 4
WAYPOINT_TOLERANCE :: f32(0.6)

Agent :: struct {
  pos:           [3]f32,
  velocity:      [3]f32,
  path:          [][3]f32,
  waypoint_idx:  int,
  goal:          [3]f32,
  color:         [4]f32,
  node:          world.NodeHandle,
}

agents: [AGENT_COUNT]Agent
nav_vertices: [dynamic][3]f32
nav_indices: [dynamic]i32
nav_area_types: [dynamic]u8

repath_phase: f32
total_time: f32

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.pre_render_proc = debug_ui
  mjolnir.run(engine, 1000, 700, "Crowd Navigation")
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.debug_ui_enabled = true
  world.main_camera_look_at(&engine.world, {32, 28, 32}, {0, 0, 0})

  world.spawn_light_directional(&engine.world, {15, 25, 15}, {1, 0.97, 0.92, 1}, 10.0, true)

  build_scene(engine)
  build_navmesh(engine)
  spawn_agents(engine)
  assign_swap_targets(engine)
}

build_scene :: proc(engine: ^mjolnir.Engine) {
  ground_geom := geometry.make_quad([4]f32{0.25, 0.55, 0.25, 1})
  size: f32 = 50.0
  for &v in ground_geom.vertices {
    v.position.x *= size
    v.position.z *= size
  }
  append_nav(ground_geom, {0, 0, 0}, false)
  gm, _ := world.create_mesh(&engine.world, ground_geom)
  gmat := world.create_material(
    &engine.world,
    type = .PBR,
    base_color_factor = {0.25, 0.6, 0.25, 1},
    roughness_value = 0.8,
  ) or_else {}
  world.spawn(
    &engine.world,
    {0, 0, 0},
    world.MeshAttachment{handle = gm, material = gmat, cast_shadow = false},
  )

  obstacles := [?]struct{pos, size: [3]f32} {
    {{-8, 1.5, -6}, {2, 3, 2}},
    {{8, 1.5, -6},  {2, 3, 2}},
    {{-8, 1.5, 6},  {2, 3, 2}},
    {{8, 1.5, 6},   {2, 3, 2}},
    {{0, 2, 0},     {4, 4, 4}},
    {{-3, 1, 10},   {3, 2, 1.5}},
  }
  for o in obstacles {
    g := geometry.make_cube([4]f32{0.7, 0.2, 0.2, 1})
    for &v in g.vertices {
      v.position.x *= o.size.x
      v.position.y *= o.size.y
      v.position.z *= o.size.z
    }
    append_nav(g, o.pos, true)
    mh, _ := world.create_mesh(&engine.world, g)
    mat := world.create_material(
      &engine.world,
      type = .PBR,
      base_color_factor = {0.7, 0.2, 0.2, 1},
      roughness_value = 0.6,
    ) or_else {}
    world.spawn(
      &engine.world,
      o.pos,
      world.MeshAttachment{handle = mh, material = mat, cast_shadow = true},
    )
  }
}

append_nav :: proc(geom: geometry.Geometry, offset: [3]f32, is_obstacle: bool) {
  base := i32(len(nav_vertices))
  for v in geom.vertices do append(&nav_vertices, v.position + offset)
  for idx in geom.indices do append(&nav_indices, base + i32(idx))
  area: u8 = u8(recast.RC_NULL_AREA) if is_obstacle else u8(recast.RC_WALKABLE_AREA)
  for _ in 0 ..< len(geom.indices) / 3 do append(&nav_area_types, area)
}

build_navmesh :: proc(engine: ^mjolnir.Engine) {
  geom := nav.NavigationGeometry {
    vertices   = nav_vertices[:],
    indices    = nav_indices[:],
    area_types = nav_area_types[:],
  }
  cfg := recast.config_create()
  if !nav.build_navmesh(&engine.nav.nav_mesh, geom, cfg) {
    log.error("navmesh build failed")
    return
  }
  if !nav.init(&engine.nav) {
    log.error("nav init failed")
  }
}

palette := [6][4]f32 {
  {1, 0.25, 0.25, 1},
  {0.25, 1, 0.25, 1},
  {0.4, 0.4, 1, 1},
  {1, 0.95, 0.2, 1},
  {0.25, 0.95, 0.95, 1},
  {1, 0.3, 0.95, 1},
}

spawn_agents :: proc(engine: ^mjolnir.Engine) {
  for i in 0 ..< AGENT_COUNT {
    angle := f32(i) / f32(AGENT_COUNT) * math.PI * 2
    r: f32 = 18.0
    agents[i].pos = {math.cos(angle) * r, 0, math.sin(angle) * r}
    agents[i].color = palette[i % len(palette)]

    cap_geom := geometry.make_capsule(12, 6, AGENT_HEIGHT, AGENT_RADIUS)
    mh, _ := world.create_mesh(&engine.world, cap_geom)
    mat := world.create_material(
      &engine.world,
      type = .PBR,
      base_color_factor = agents[i].color,
      emissive_value = 0.4,
    ) or_else {}
    agents[i].node = world.spawn(
      &engine.world,
      agents[i].pos + [3]f32{0, AGENT_HEIGHT * 0.5, 0},
      world.MeshAttachment{handle = mh, material = mat, cast_shadow = true},
    ) or_else {}
  }
}

assign_swap_targets :: proc(engine: ^mjolnir.Engine) {
  for i in 0 ..< AGENT_COUNT {
    angle := f32(i) / f32(AGENT_COUNT) * math.PI * 2 + math.PI
    r: f32 = 16.0 + rand.float32() * 4.0
    agents[i].goal = {math.cos(angle) * r, 0, math.sin(angle) * r}
    replan(engine, &agents[i])
  }
}

replan :: proc(engine: ^mjolnir.Engine, a: ^Agent) {
  delete(a.path)
  a.path = nav.find_path(&engine.nav, a.pos, a.goal, 128)
  a.waypoint_idx = 0
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  total_time += delta_time

  // Replan all agents on a long interval so they swirl
  repath_phase += delta_time
  if repath_phase >= 8.0 {
    repath_phase = 0
    assign_swap_targets(engine)
  }

  for i in 0 ..< AGENT_COUNT {
    a := &agents[i]
    desired_dir := [3]f32{0, 0, 0}
    if len(a.path) > 0 && a.waypoint_idx < len(a.path) {
      target := a.path[a.waypoint_idx]
      diff := target - a.pos
      diff.y = 0
      dist := linalg.length(diff)
      if dist < WAYPOINT_TOLERANCE {
        a.waypoint_idx += 1
      } else {
        desired_dir = diff / dist
      }
    }

    // Separation against neighbours
    sep := [3]f32{0, 0, 0}
    n_sep := 0
    for j in 0 ..< AGENT_COUNT {
      if i == j do continue
      diff := a.pos - agents[j].pos
      diff.y = 0
      d2 := linalg.length2(diff)
      if d2 < 0.0001 || d2 > SEPARATION_RADIUS * SEPARATION_RADIUS do continue
      d := math.sqrt(d2)
      weight := 1.0 - d / SEPARATION_RADIUS
      sep += (diff / d) * weight
      n_sep += 1
    }
    if n_sep > 0 do sep /= f32(n_sep)

    move := desired_dir + sep * 1.5
    ml2 := linalg.length2(move)
    if ml2 > 0.0001 {
      move = linalg.normalize(move)
      a.velocity = move * AGENT_SPEED
      a.pos += a.velocity * delta_time
    } else {
      a.velocity = {0, 0, 0}
    }

    pos := a.pos + [3]f32{0, AGENT_HEIGHT * 0.5, 0}
    world.translate(&engine.world, a.node, pos)
    if linalg.length2(a.velocity.xz) > 0.01 {
      yaw := math.atan2(a.velocity.x, a.velocity.z)
      world.rotate(&engine.world, a.node, yaw, linalg.VECTOR3F32_Y_AXIS)
    }
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
    }
  }
}
