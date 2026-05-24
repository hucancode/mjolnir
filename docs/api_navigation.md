---
title: navigation API
---
# `mjolnir/navigation` — API Reference

Navmesh build + pathfinding. The engine owns one `NavigationSystem` at
`engine.nav`. The fastest path is to bake the scene graph into a navmesh
via `mjolnir.setup_navmesh` and then call the engine-rooted
`find_path` / `find_nearest_point` shortcuts.

```odin
mjolnir.setup_navmesh(engine,
                      config = mjolnir.DEFAULT_NAVMESH_CONFIG,
                      include_filter = world.NodeTagSet{},
                      exclude_filter = world.NodeTagSet{}) -> bool

mjolnir.find_path         (engine, start, goal, max_points = 256) -> [][3]f32
mjolnir.find_nearest_point(engine, pos, extents = {1, 1, 1})      -> ([3]f32, bool)
```

`setup_navmesh` collects geometry from nodes matching the filters,
voxelizes it, builds a navmesh, and binds the query context. After it
returns, pathfinding works against the engine.

See `mjolnir.NavMeshConfig` / `DEFAULT_NAVMESH_CONFIG` in
[`api_engine`](api_engine.html) for the user-facing config.

## Types

```odin
TileCoord :: struct { x, y: i32 }

NavigationGeometry :: struct {
  vertices:   [][3]f32,
  indices:    []i32,
  area_types: []u8,        // walkable / obstacle / custom per triangle
}

NavMesh :: struct {
  bounds:     geometry.Aabb,
  cell_size:  f32,
  tile_size:  i32,
  is_tiled:   bool,
  area_costs: [64]f32,     // cost multiplier per area type (default 1.0)
  // (the underlying Detour mesh and query handles also live here)
}

NavigationSystem :: struct {
  nav_mesh: NavMesh,
  // (query state lives here too)
}
```

`area_types[i] = 0` means walkable. Non-zero values index `area_costs`
to make some terrain more expensive without making it impassable.

## Lifecycle

```odin
init     (sys: ^NavigationSystem, max_nodes: i32 = 2048) -> bool
shutdown (sys: ^NavigationSystem)
```

The engine calls these for you.

## Building a navmesh manually

```odin
NavGeometryBuilder :: struct {
  vertices:   [dynamic][3]f32,
  indices:    [dynamic]i32,
  area_types: [dynamic]u8,
}

append_geometry (b, geom: geometry.Geometry, offset: [3]f32 = {0,0,0}, is_obstacle: bool = false)
geometry_view   (b) -> NavigationGeometry      // no copy; valid while b is alive
destroy_builder (b)

build_navmesh   (nav_mesh, geom: NavigationGeometry, config: recast.Config = {}) -> bool
calculate_bounds_from_vertices(vertices) -> geometry.Aabb
build_geometry  (nav_mesh) -> geometry.Geometry        // navmesh → visual mesh, for debug
convert_geometry_to_nav(vertices: []geometry.Vertex, indices: []u32)
                       -> (nav_vertices: [][3]f32, nav_indices: []i32)
```

```odin
builder: nav.NavGeometryBuilder
defer nav.destroy_builder(&builder)

nav.append_geometry(&builder, ground_geom)
nav.append_geometry(&builder, obstacle_geom, offset = {5, 0, 0}, is_obstacle = true)

nav.build_navmesh(&engine.nav.nav_mesh, nav.geometry_view(&builder))
```

Use `build_navmesh` directly when you need full control over geometry
inputs (procedurally generated terrain, streamed tiles); use
`mjolnir.setup_navmesh` for the default "bake everything tagged" flow.

## Pathfinding

```odin
find_path           (sys, start, end: [3]f32, max_path_length: i32 = 256)
                   -> (path: [][3]f32, ok: bool)
is_position_walkable(sys, position: [3]f32) -> bool
find_nearest_point  (sys, position: [3]f32, search_extents: [3]f32 = {2, 4, 2})
                   -> (nearest_pos: [3]f32, found: bool)
```

`find_path` returns an empty slice if no path exists. `find_nearest_point`
snaps an off-mesh point onto the navmesh — useful before calling
`find_path` with a goal selected by the user via raycast.
