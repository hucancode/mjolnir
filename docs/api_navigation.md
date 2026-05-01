# `mjolnir/navigation` — API Reference

Layer 2. Recast (voxel-based navmesh build) + Detour (query / pathfinding).
The engine wraps these into one `NavigationSystem`. See
[architecture §1](architecture.html#1-layered-module-organization) for layer
placement.

## Types

```odin
NavObstacleType :: enum { Static, Dynamic }
TileCoord       :: struct { x, y: i32 }

NavigationGeometry :: struct {
  vertices:   [][3]f32,
  indices:    []i32,
  area_types: []u8,                  // per-triangle: walkable / obstacle / custom
}

NavMesh :: struct {
  detour_mesh: detour.Nav_Mesh,
  bounds:      geometry.Aabb,
  cell_size:   f32,
  tile_size:   i32,
  is_tiled:    bool,
  area_costs:  [64]f32,
}

NavContext :: struct {
  nav_mesh_query: detour.Nav_Mesh_Query,
  query_filter:   detour.Query_Filter,
}

NavigationSystem :: struct {
  nav_mesh:       NavMesh,
  nav_mesh_query: detour.Nav_Mesh_Query,
  query_filter:   detour.Query_Filter,
}
```

## Lifecycle

```odin
init    (sys: ^NavigationSystem, max_nodes: i32 = 2048) -> bool
shutdown(sys: ^NavigationSystem)
```

## Build

```odin
build_navmesh(nav_mesh: ^NavMesh, geom: NavigationGeometry, config: recast.Config = {}) -> bool

calculate_bounds_from_vertices(vertices: [][3]f32) -> geometry.Aabb
build_geometry  (nav_mesh: ^NavMesh) -> geometry.Geometry
convert_geometry_to_nav(vertices: []geometry.Vertex, indices: []u32)
                       -> (nav_vertices: [][3]f32, nav_indices: []i32)
```

`build_navmesh` runs:
1. Voxelization (height field rasterization)
2. Region partitioning
3. Contour extraction
4. Polygon mesh build
5. Detail mesh build
6. Detour mesh init
7. Area-cost initialization (`area_costs[i] = 1.0` for all 64 area types)

## Pathfinding

```odin
find_path(sys, start: [3]f32, end: [3]f32, max_path_length: i32 = 256)
         -> (path: [][3]f32, ok: bool)

is_position_walkable(sys, position: [3]f32) -> bool
find_nearest_point  (sys, position: [3]f32, search_extents: [3]f32 = {2, 4, 2})
                   -> (nearest_pos: [3]f32, found: bool)
```

## Engine wrapper

The full bake-from-scene-graph entry point lives in `mjolnir/engine.odin`:

```odin
mjolnir.setup_navmesh(engine,
                      config         = mjolnir.DEFAULT_NAVMESH_CONFIG,
                      include_filter = world.NodeTagSet{},
                      exclude_filter = world.NodeTagSet{}) -> bool
```

It calls `world.bake_geometry`, converts coordinates, runs `build_navmesh`,
and binds the system's query context. See `api_engine.md`.
