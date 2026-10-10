package bake

import "core:log"
import ".."
import "../detour"
import "../recast"

// Triangle soup to bake: one area type per triangle.
NavGeometryBuilder :: struct {
  vertices:   [dynamic][3]f32,
  indices:    [dynamic]i32,
  area_types: [dynamic]u8,
}

// Append a triangle mesh to a builder. Triangles are walkable unless
// `is_obstacle`. Every position is offset by `offset`.
append_triangles :: proc(
  b: ^NavGeometryBuilder,
  positions: [][3]f32,
  indices: []u32,
  offset: [3]f32 = {0, 0, 0},
  is_obstacle: bool = false,
) {
  base := i32(len(b.vertices))
  for p in positions do append(&b.vertices, p + offset)
  for i in indices do append(&b.indices, base + i32(i))
  area: u8 = u8(recast.RC_NULL_AREA) if is_obstacle else u8(recast.RC_WALKABLE_AREA)
  for _ in 0 ..< len(indices) / 3 do append(&b.area_types, area)
}

builder_destroy :: proc(b: ^NavGeometryBuilder) {
  delete(b.vertices)
  delete(b.indices)
  delete(b.area_types)
  b^ = {}
}

// Build the mesh and its query from the builder's triangles, replacing any
// previous build.
build :: proc(
  nav: ^navigation.NavMesh,
  geom: ^NavGeometryBuilder,
  config: NavMeshConfig = DEFAULT_NAVMESH_CONFIG,
  max_query_nodes: i32 = 2048,
) -> bool {
  if len(geom.vertices) == 0 || len(geom.indices) == 0 {
    log.error("Cannot build navigation mesh from empty geometry")
    return false
  }
  cfg := config_to_recast(config)
  pmesh, dmesh := recast.build_navmesh(geom.vertices[:], geom.indices[:], geom.area_types[:], cfg) or_return
  defer {
    recast.destroy_poly_mesh(pmesh)
    recast.destroy_poly_mesh_detail(dmesh)
  }
  nav_params := Create_Nav_Mesh_Data_Params {
    poly_mesh        = pmesh,
    poly_mesh_detail = dmesh,
    walkable_height  = f32(cfg.walkable_height) * cfg.ch,
    walkable_radius  = f32(cfg.walkable_radius) * cfg.cs,
    walkable_climb   = f32(cfg.walkable_climb) * cfg.ch,
  }
  nav_data, create_status := create_nav_mesh_data(&nav_params)
  if !detour.status_succeeded(create_status) {
    log.errorf("Failed to create navigation mesh data: %v", create_status)
    return false
  }
  mesh_params := detour.Nav_Mesh_Params {
    orig        = pmesh.bmin,
    tile_width  = pmesh.bmax[0] - pmesh.bmin[0],
    tile_height = pmesh.bmax[2] - pmesh.bmin[2],
    max_tiles   = 1,
    max_polys   = 1024,
  }
  return navigation.init(nav, nav_data, mesh_params, max_query_nodes)
}
