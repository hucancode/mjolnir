package resources

import "core:math/linalg"
import "../geometry"
import detour "../navigation/detour"
import recast "../navigation/recast"

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
  triangles:   [dynamic]NavMeshTriangle,
  version:     u32,
}

NavContext :: struct {
  nav_mesh_query:  detour.Nav_Mesh_Query,
  associated_mesh: Handle,
  query_filter:    detour.Query_Filter,
}

NavMeshTriangle :: struct {
  positions: [3][3]f32,
  area_type: u8,
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

NavObstacleEntry :: struct {
  handle:    Handle,
  area_type: u8,
}

NavigationSystem :: struct {
  default_context_handle: Handle,
  geometry_cache:         [dynamic]NavigationGeometry,
  dirty_tiles:            map[TileCoord]bool,
  rebuild_queued:         bool,
  obstacles:              [dynamic]NavObstacleEntry,
  active_nav_mesh:        Handle,
}

DEFAULT_NAVIGATION_AREA :: recast.RC_WALKABLE_AREA

ensure_obstacle_storage :: proc(system: ^NavigationSystem) {
  if system.obstacles == nil {
    system.obstacles = make([dynamic]NavObstacleEntry, 0)
  }
}

register_navigation_obstacle :: proc(
  manager: ^Manager,
  handle: Handle,
  area_type: u8,
) {
  system := &manager.navigation_system
  ensure_obstacle_storage(system)
  reusable_index := -1
  for idx in 0 ..< len(system.obstacles) {
    obstacle := &system.obstacles[idx]
    if obstacle.handle == handle {
      obstacle.area_type = area_type
      return
    }
    if reusable_index < 0 && obstacle.handle.generation == 0 {
      reusable_index = idx
    }
  }
  if reusable_index >= 0 {
    system.obstacles[reusable_index] = NavObstacleEntry{handle = handle, area_type = area_type}
  } else {
    append(&system.obstacles, NavObstacleEntry{handle = handle, area_type = area_type})
  }
}

unregister_navigation_obstacle :: proc(
  manager: ^Manager,
  handle: Handle,
) {
  system := &manager.navigation_system
  if system.obstacles == nil {
    return
  }
  for idx in 0 ..< len(system.obstacles) {
    if system.obstacles[idx].handle == handle {
      system.obstacles[idx] = NavObstacleEntry{}
      break
    }
  }
}

set_active_nav_mesh :: proc(
  manager: ^Manager,
  handle: Handle,
) {
  manager.navigation_system.active_nav_mesh = handle
}

clear_active_nav_mesh :: proc(manager: ^Manager) {
  manager.navigation_system.active_nav_mesh = {}
}

get_navigation_obstacles :: proc(system: ^NavigationSystem) -> []NavObstacleEntry {
  if system.obstacles == nil {
    return nil
  }
  return system.obstacles[:]
}
