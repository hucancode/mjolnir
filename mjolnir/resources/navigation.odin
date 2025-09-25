package resources

import "core:math/linalg"
import "../geometry"
import detour "../navigation/detour"
import "../resources"

NavObstacleType :: enum {
  Static,
  Dynamic,
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
  nav_mesh_query:  detour.Nav_Mesh_Query,
  associated_mesh: resources.Handle,
  query_filter:    detour.Query_Filter,
}

NavigationGeometry :: struct {
  vertices:   []f32,
  indices:    []i32,
  area_types: []u8,
  transform:  matrix[4, 4]f32,
  dirty:      bool,
}

TileCoord :: struct {
  x, y: i32,
}

NavigationSystem :: struct {
  default_context_handle: resources.Handle,
  geometry_cache:         [dynamic]NavigationGeometry,
  dirty_tiles:            map[TileCoord]bool,
  rebuild_queued:         bool,
}
