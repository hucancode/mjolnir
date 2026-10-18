package bake

import "core:log"
import "core:math/linalg"
import "../detour"
import "../recast"

// NavGeometryBuilder accumulates the triangle soup to bake: one area type per triangle.
NavGeometryBuilder :: struct {
  vertices:   [dynamic][3]f32,
  indices:    [dynamic]i32,
  area_types: [dynamic]u8,
}

// append_triangles adds a triangle mesh to b, its positions moved by `transform` (a node's
// world matrix, say). Triangles are walkable unless `is_obstacle`.
append_triangles :: proc(
  self: ^NavGeometryBuilder,
  positions: [][3]f32,
  indices: []u32,
  transform: matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY,
  is_obstacle: bool = false,
) {
  base := i32(len(self.vertices))
  for p in positions do append(&self.vertices, (transform * [4]f32{p.x, p.y, p.z, 1}).xyz)
  for i in indices do append(&self.indices, base + i32(i))
  area: u8 = u8(recast.RC_NULL_AREA) if is_obstacle else u8(recast.RC_WALKABLE_AREA)
  for _ in 0 ..< len(indices) / 3 do append(&self.area_types, area)
}

// append_box adds the six faces of a box to b, e.g. a ground slab or an obstacle. Faces are
// walkable unless `is_obstacle` (the bake still drops the steep sides).
append_box :: proc(self: ^NavGeometryBuilder, center, half_extents: [3]f32, is_obstacle: bool = false) {
  faces := BOX_FACES
  area: u8 = u8(recast.RC_NULL_AREA) if is_obstacle else u8(recast.RC_WALKABLE_AREA)
  for face in faces {
    base := i32(len(self.vertices))
    for corner in face do append(&self.vertices, center + corner * half_extents)
    append(&self.indices, base, base + 1, base + 2, base + 2, base + 3, base)
    append(&self.area_types, area, area)
  }
}

// The corners of each face of the unit box, wound as render's make_cube winds them.
@(private = "file")
BOX_FACES :: [6][4][3]f32 {
  {{-1, -1, 1}, {1, -1, 1}, {1, 1, 1}, {-1, 1, 1}},
  {{-1, 1, -1}, {1, 1, -1}, {1, -1, -1}, {-1, -1, -1}},
  {{1, 1, -1}, {-1, 1, -1}, {-1, 1, 1}, {1, 1, 1}},
  {{1, -1, 1}, {-1, -1, 1}, {-1, -1, -1}, {1, -1, -1}},
  {{1, -1, -1}, {1, 1, -1}, {1, 1, 1}, {1, -1, 1}},
  {{-1, -1, 1}, {-1, 1, 1}, {-1, 1, -1}, {-1, -1, -1}},
}

// builder_destroy frees the builder arrays.
builder_destroy :: proc(self: ^NavGeometryBuilder) {
  delete(self.vertices)
  delete(self.indices)
  delete(self.area_types)
  self^ = {}
}

// build bakes the builder's triangles into a navigation mesh, encoded as navigation.save
// encodes one, in memory the caller frees: navigation.init with it, or store it
// (platform.write_file) and load it in the shipped game.
build :: proc(
  self: ^NavGeometryBuilder,
  config: NavMeshConfig = DEFAULT_NAVMESH_CONFIG,
  allocator := context.allocator,
) -> (
  data: []u8,
  ok: bool,
) {
  if len(self.vertices) == 0 || len(self.indices) == 0 {
    log.error("Cannot build navigation mesh from empty geometry")
    return nil, false
  }
  cfg := config_to_recast(config)
  pmesh, dmesh := recast.build_navmesh(self.vertices[:], self.indices[:], self.area_types[:], cfg) or_return
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
    return nil, false
  }
  mesh_params := detour.Nav_Mesh_Params {
    orig        = pmesh.bmin,
    tile_width  = pmesh.bmax[0] - pmesh.bmin[0],
    tile_height = pmesh.bmax[2] - pmesh.bmin[2],
    max_tiles   = 1,
    max_polys   = 1024,
  }
  mesh: detour.Nav_Mesh
  defer detour.nav_mesh_destroy(&mesh)
  if status := detour.nav_mesh_init(&mesh, &mesh_params); !detour.status_succeeded(status) {
    log.errorf("Failed to initialize navigation mesh: %v", status)
    delete(nav_data)
    return nil, false
  }
  if _, status := detour.nav_mesh_add_tile(&mesh, nav_data, detour.DT_TILE_FREE_DATA); !detour.status_succeeded(status) {
    log.errorf("Failed to add tile to navigation mesh: %v", status)
    delete(nav_data)
    return nil, false
  }
  return detour.save_navmesh(&mesh, allocator), true
}

// destroy frees a builder, as builder_destroy does.
destroy :: proc {
  builder_destroy,
}
