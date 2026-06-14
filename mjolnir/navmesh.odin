package mjolnir

import nav "navigation"
import "navigation/recast"
import "world"

setup_navmesh :: proc(
  engine: ^Engine,
  config: nav.NavMeshConfig = nav.DEFAULT_NAVMESH_CONFIG,
  include_filter: world.NodeTagSet = {},
  exclude_filter: world.NodeTagSet = {},
) -> bool {
  build_area_types_from_tags :: proc(node_infos: []world.BakedNodeInfo) -> []u8 {
    area_types := make([dynamic]u8, 0, len(node_infos) * 10)
    for info in node_infos {
      triangle_count := info.index_count / 3
      area_type :=
        .NAVMESH_OBSTACLE in info.tags ? u8(recast.RC_NULL_AREA) : u8(recast.RC_WALKABLE_AREA)
      for _ in 0 ..< triangle_count {
        append(&area_types, area_type)
      }
    }
    return area_types[:]
  }
  world.traverse(&engine.world)
  baked_geom, node_infos, bake_ok := world.bake_geometry(
    &engine.world,
    include_filter,
    exclude_filter,
    true,
  )
  if !bake_ok {
    return false
  }
  defer {
    delete(baked_geom.vertices)
    delete(baked_geom.indices)
    delete(node_infos)
  }
  nav_vertices, nav_indices := nav.convert_geometry_to_nav(
    baked_geom.vertices,
    baked_geom.indices,
  )
  defer {
    delete(nav_vertices)
    delete(nav_indices)
  }
  area_types := build_area_types_from_tags(node_infos)
  defer delete(area_types)
  recast_config := nav.config_to_recast(config)
  nav_geom := nav.NavigationGeometry {
    vertices   = nav_vertices,
    indices    = nav_indices,
    area_types = area_types,
  }
  if !nav.build_navmesh(&engine.nav.nav_mesh, nav_geom, recast_config) {
    return false
  }
  if !nav.init(&engine.nav) {
    return false
  }
  return true
}
