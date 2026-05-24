---
title: Navigation
---
# Navigation Module (`mjolnir/navigation`)

Navmesh generation (Recast) + pathfinding (Detour) for AI agent
navigation. The engine owns `engine.nav`.

## Quick Setup — bake from tagged scene

Tag the geometry, call `setup_navmesh`, query a path.

```odin
floor := mjolnir.spawn_primitive_mesh(engine, .QUAD_XZ, .GRAY, scale_factor = 30)
mjolnir.tag(engine, floor, {.ENVIRONMENT})

obstacle := mjolnir.spawn_mesh(engine, cube_mesh, mat, pos)
mjolnir.tag(engine, obstacle, {.NAVMESH_OBSTACLE})

mjolnir.setup_navmesh(
  engine,
  config         = mjolnir.DEFAULT_NAVMESH_CONFIG,
  include_filter = {.ENVIRONMENT},
  exclude_filter = {},
)

path := mjolnir.find_path(engine, start_pos, end_pos, 256)
```

## Manual build via `NavGeometryBuilder`

When you want explicit per-mesh offsets and obstacle flags (procedural
levels, per-tile baking, etc.).

```odin
import nav "../../mjolnir/navigation"
import "../../mjolnir/navigation/recast"

builder: nav.NavGeometryBuilder
defer nav.destroy_builder(&builder)

// Add ground (walkable by default)
ground_geom := geometry.make_quad(...)
nav.append_geometry(&builder, ground_geom)

// Add obstacles (is_obstacle marks tris as non-walkable)
for pos in obstacle_positions {
  g := geometry.make_cube(...)
  nav.append_geometry(&builder, g, offset = pos, is_obstacle = true)
}

// Snapshot to a NavigationGeometry view (no copy) and bake
nav.build_navmesh(&engine.nav.nav_mesh, nav.geometry_view(&builder), recast.config_create())
nav.init(&engine.nav)
```

`NavigationGeometry` is the input format:

```odin
NavigationGeometry :: struct {
  vertices:   [][3]f32,
  indices:    []i32,
  area_types: []u8,    // per-triangle: walkable / obstacle / custom
}
```

## Quality Presets

```odin
import "../../mjolnir"

config := mjolnir.NavMeshConfig{
  agent_height    = 2.0,
  agent_radius    = 0.6,
  agent_max_climb = 0.9,
  agent_max_slope = math.PI * 0.25,
  quality         = .MEDIUM,        // .LOW | .MEDIUM | .HIGH | .ULTRA
}

mjolnir.setup_navmesh(engine, config)
```

Quality levels:
- `LOW` — fast generation, coarse mesh; large open areas
- `MEDIUM` — recommended default
- `HIGH` — detailed environments
- `ULTRA` — small intricate spaces

## Manual Recast config

If `NavMeshConfig` isn't expressive enough:

```odin
cfg := recast.Config{
  cs                       = 0.3,
  ch                       = 0.2,
  walkable_slope           = math.PI * 0.25,
  walkable_height          = 10,    // in cells
  walkable_climb           = 4,
  walkable_radius          = 2,
  max_edge_len             = 12,
  max_simplification_error = 1.3,
  min_region_area          = 64,
  merge_region_area        = 400,
  max_verts_per_poly       = 6,
  detail_sample_dist       = 6.0,
  detail_sample_max_error  = 1.0,
  border_size              = 0,
}
```

## Pathfinding

```odin
path := mjolnir.find_path(engine, start, end, max_points = 256)
if len(path) > 0 {
  defer delete(path)
  for point, i in path do log.infof("waypoint %d: %v", i, point)
}

// Project a position onto the navmesh
nearest, ok := mjolnir.find_nearest_point(
  engine, query_pos, extents = {2.0, 5.0, 2.0},
)
```

## Mouse-pick onto the navmesh

```odin
cam, _ := mjolnir.main_camera(engine)
mx, my := glfw.GetCursorPos(engine.window)
ray_origin, ray_dir := world.camera_viewport_to_world_ray(cam, f32(mx), f32(my))

// Intersect ground plane
if math.abs(ray_dir.y) > 0.001 {
  t := -ray_origin.y / ray_dir.y
  if t > 0 {
    ground_hit := ray_origin + ray_dir * t
    pos, ok := mjolnir.find_nearest_point(engine, ground_hit, {2, 5, 2})
    if ok do agent_destination = pos
  }
}
```

## Agent movement

Walking the path is on you — lerp the agent toward each waypoint:

```odin
update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  if len(current_path) == 0 do return
  target := current_path[waypoint_idx]
  diff := target - agent_pos
  dist := linalg.length(diff)

  if dist < 0.5 {
    waypoint_idx += 1
    if waypoint_idx >= len(current_path) do log.info("arrived")
  } else {
    move := math.min(dist, agent_speed * dt)
    agent_pos += linalg.normalize(diff) * move
    mjolnir.translate(engine, agent_handle, agent_pos)
  }
}
```

## Navmesh visualization

```odin
navmesh_geom := nav.build_geometry(&engine.nav.nav_mesh)
m   := mjolnir.create_mesh(engine, navmesh_geom)
mat := mjolnir.create_material(engine,
  type = .RANDOM_COLOR, base_color_factor = {1.0, 0.8, 0.3, 0.3})
mjolnir.spawn_mesh(engine, m, mat)
```

For path debug lines use `mjolnir.debug_segment(engine, a, b, color)`.
