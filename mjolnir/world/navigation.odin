package world

import cont "../containers"
import "../geometry"
import "../gpu"
import nav "../navigation"
import "../navigation/detour"
import "../navigation/recast"
import navmesh_renderer "../render/navigation"
import "../resources"
import "core:log"
import "core:math"
import "core:math/linalg"

NavMeshAgentAttachment :: struct {
  target_position:     [3]f32,
  current_path:        [][3]f32,
  path_index:          i32,
  agent_radius:        f32,
  agent_height:        f32,
  max_speed:           f32,
  max_acceleration:    f32,
  arrival_distance:    f32,
  auto_update_path:    bool,
  pathfinding_enabled: bool,
}

NavMeshObstacleAttachment :: struct {
  obstacle_bounds:     geometry.Aabb,
  affects_pathfinding: bool,
  obstacle_type:       nav.NavObstacleType,
}

SceneGeometryCollector :: struct {
  vertices:         [dynamic][3]f32,
  indices:          [dynamic]i32,
  area_types:       [dynamic]u8,
  mesh_count:       i32,
  include_filter:   proc(node: ^Node) -> bool,
  area_type_mapper: proc(node: ^Node) -> u8,
  world:            ^World,
  rm:               ^resources.Manager,
  gctx:             ^gpu.GPUContext,
}

scene_geometry_collector_init :: proc(collector: ^SceneGeometryCollector) {
  collector.include_filter = proc(node: ^Node) -> bool {
    _, is_mesh := node.attachment.(MeshAttachment)
    return is_mesh
  }
  collector.area_type_mapper = proc(node: ^Node) -> u8 {
    return u8(recast.RC_WALKABLE_AREA)
  }
}

scene_geometry_collector_destroy :: proc(collector: ^SceneGeometryCollector) {
  delete(collector.vertices)
  delete(collector.indices)
  delete(collector.area_types)
}

scene_geometry_collector_traverse :: proc(node: ^Node, ctx: rawptr) -> bool {
  collector := cast(^SceneGeometryCollector)ctx
  if collector.include_filter != nil && !collector.include_filter(node) {
    return true
  }
  if mesh_attachment, is_mesh := node.attachment.(MeshAttachment); is_mesh {
    mesh := cont.get(collector.rm.meshes, mesh_attachment.handle)
    if mesh == nil do return true
    world_matrix := node.transform.world_matrix
    area_type := u8(recast.RC_WALKABLE_AREA)
    if collector.area_type_mapper != nil {
      area_type = collector.area_type_mapper(node)
    }
    add_mesh_to_collector(
      collector,
      mesh,
      collector.rm,
      collector.gctx,
      world_matrix,
      area_type,
    )
    collector.mesh_count += 1
  }
  return true
}

add_mesh_to_collector :: proc(
  collector: ^SceneGeometryCollector,
  mesh: ^resources.Mesh,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  transform: matrix[4, 4]f32,
  area_type: u8,
) {
  vertex_offset := i32(len(collector.vertices))
  vertex_count := int(mesh.vertex_allocation.count)
  vertices := make([]geometry.Vertex, vertex_count, context.temp_allocator)
  ret := gpu.get_all(
    gctx,
    &rm.vertex_buffer,
    vertices,
    int(mesh.vertex_allocation.offset),
  )
  if ret != .SUCCESS {
    log.error("Failed to read vertex data from StaticBuffer")
    return
  }
  for vertex in vertices {
    transformed_pos :=
      (transform * [4]f32{vertex.position.x, vertex.position.y, vertex.position.z, 1.0}).xyz
    append(&collector.vertices, transformed_pos)
  }
  index_count := int(mesh.index_allocation.count)
  indices := make([]u32, index_count, context.temp_allocator)
  ret = gpu.get_all(
    gctx,
    &rm.index_buffer,
    indices,
    int(mesh.index_allocation.offset),
  )
  if ret != .SUCCESS {
    log.error("Failed to read index data from StaticBuffer")
    return
  }
  for index in indices {
    append(&collector.indices, i32(index) + vertex_offset)
  }
  triangle_count := index_count / 3
  for _ in 0 ..< triangle_count {
    append(&collector.area_types, area_type)
  }
}

build_navigation_mesh_from_world :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  nav_sys: ^nav.NavigationSystem,
  config: recast.Config = {},
) -> bool {
  collector: SceneGeometryCollector
  scene_geometry_collector_init(&collector)
  collector.world, collector.rm, collector.gctx = world, rm, gctx
  defer scene_geometry_collector_destroy(&collector)
  collector.include_filter = proc(node: ^Node) -> bool {
    _, is_mesh := node.attachment.(MeshAttachment)
    return is_mesh
  }
  collector.area_type_mapper = proc(node: ^Node) -> u8 {
    return u8(recast.RC_WALKABLE_AREA)
  }
  traverse(
    collector.world,
    collector.rm,
    &collector,
    scene_geometry_collector_traverse,
  )
  if len(collector.vertices) == 0 || len(collector.indices) == 0 {
    log.error("No geometry found in world for navigation mesh building")
    return false
  }
  log.infof(
    "Collected %d vertices, %d indices from %d meshes for world navigation mesh",
    len(collector.vertices),
    len(collector.indices),
    collector.mesh_count,
  )
  if len(collector.vertices) > 0 {
    log.infof(
      "First vertex: (%.3f, %.3f, %.3f)",
      collector.vertices[0].x,
      collector.vertices[0].y,
      collector.vertices[0].z,
    )
    if len(collector.vertices) > 1 {
      log.infof(
        "Second vertex: (%.3f, %.3f, %.3f)",
        collector.vertices[1].x,
        collector.vertices[1].y,
        collector.vertices[1].z,
      )
    }
    min_pos := collector.vertices[0]
    max_pos := collector.vertices[0]
    for vertex in collector.vertices[1:] {
      min_pos.x = min(min_pos.x, vertex.x)
      min_pos.y = min(min_pos.y, vertex.y)
      min_pos.z = min(min_pos.z, vertex.z)
      max_pos.x = max(max_pos.x, vertex.x)
      max_pos.y = max(max_pos.y, vertex.y)
      max_pos.z = max(max_pos.z, vertex.z)
    }
    log.infof(
      "Geometry bounds: min(%.3f, %.3f, %.3f) max(%.3f, %.3f, %.3f)",
      min_pos.x,
      min_pos.y,
      min_pos.z,
      max_pos.x,
      max_pos.y,
      max_pos.z,
    )
  }
  walkable_count := 0
  obstacle_count := 0
  for area in collector.area_types {
    if area == u8(recast.RC_WALKABLE_AREA) {
      walkable_count += 1
    } else if area == u8(recast.RC_NULL_AREA) {
      obstacle_count += 1
    }
  }
  log.infof(
    "Area types: %d walkable triangles, %d obstacle triangles",
    walkable_count,
    obstacle_count,
  )
  log.infof(
    "Recast Config: cs=%.3f, ch=%.3f, walkable_radius=%d, min_region=%d",
    config.cs,
    config.ch,
    config.walkable_radius,
    config.min_region_area,
  )
  geom := nav.NavigationGeometry {
    vertices   = collector.vertices[:],
    indices    = collector.indices[:],
    area_types = collector.area_types[:],
  }
  navmesh, build_ok := nav.build_navmesh_from_geometry(geom, config)
  if !build_ok do return false
  if !nav.set_navmesh(nav_sys, navmesh) do return false
  log.info("Successfully built world navigation mesh")
  return true
}

spawn_nav_agent_at :: proc(
  world: ^World,
  position: [3]f32,
  radius: f32 = 0.5,
  height: f32 = 2.0,
) -> (
  handle: resources.NodeHandle,
  node: ^Node,
  ok: bool,
) {
  attachment := NavMeshAgentAttachment {
    target_position     = position,
    agent_radius        = radius,
    agent_height        = height,
    max_speed           = 5.0,
    max_acceleration    = 10.0,
    arrival_distance    = 0.1,
    auto_update_path    = true,
    pathfinding_enabled = true,
  }
  return spawn(world, position, attachment)
}

nav_agent_set_target :: proc(
  world: ^World,
  nav_sys: ^nav.NavigationSystem,
  agent_handle: resources.NodeHandle,
  target: [3]f32,
) -> bool {
  node := cont.get(world.nodes, agent_handle)
  if node == nil {
    return false
  }
  agent := &node.attachment.(NavMeshAgentAttachment)
  agent.target_position = target
  if agent.pathfinding_enabled {
    current_pos := node.transform.position
    path, success := nav.find_path(
      nav_sys,
      current_pos,
      target,
    )
    if success {
      agent.current_path = path
      agent.path_index = 0
      log.infof("Set new path for agent with %d waypoints", len(path))
    } else {
      log.warn("Failed to find path for navigation agent")
    }
  }
  return true
}

build_and_visualize_navigation_mesh :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  nav_sys: ^nav.NavigationSystem,
  renderer: ^navmesh_renderer.Renderer,
  config: recast.Config = {},
) -> bool {
  if !build_navigation_mesh_from_world(
    world,
    rm,
    gctx,
    nav_sys,
    config,
  ) {
    return false
  }
  if !nav_sys.has_mesh do return false
  tile := detour.get_tile_at(&nav_sys.nav_mesh.detour_mesh, 0, 0, 0)
  if tile == nil || tile.header == nil {
    log.error("Failed to get navigation mesh tile for visualization")
    return false
  }
  Vertex :: struct {
    position: [3]f32,
    color:    [4]f32,
  }
  navmesh_vertices := make([dynamic]Vertex, 0, int(tile.header.vert_count))
  indices := make([dynamic]u32, 0, int(tile.header.poly_count) * 3)
  defer delete(navmesh_vertices)
  defer delete(indices)
  for i in 0 ..< tile.header.vert_count {
    pos := tile.verts[i]
    append(
      &navmesh_vertices,
      Vertex{position = pos, color = {0.0, 0.8, 0.2, 0.6}},
    )
  }
  for i in 0 ..< tile.header.poly_count {
    poly := &tile.polys[i]
    vert_count := int(poly.vert_count)
    if vert_count < 3 do continue
    poly_seed := u32(i * 17 + 23)
    hue := f32((poly_seed * 137) % 360)
    poly_color := [4]f32 {
      0.5 + 0.5 * math.sin(hue * math.PI / 180.0),
      0.5 + 0.5 * math.sin((hue + 120) * math.PI / 180.0),
      0.5 + 0.5 * math.sin((hue + 240) * math.PI / 180.0),
      0.6,
    }
    for j in 0 ..< vert_count {
      if int(poly.verts[j]) < len(navmesh_vertices) {
        navmesh_vertices[poly.verts[j]].color = poly_color
      }
    }
    for j in 1 ..< vert_count - 1 {
      append(
        &indices,
        u32(poly.verts[0]),
        u32(poly.verts[j]),
        u32(poly.verts[j + 1]),
      )
    }
  }
  renderer_vertices := transmute([]navmesh_renderer.Vertex)navmesh_vertices[:]
  load_ok := navmesh_renderer.load_navmesh_data(
    renderer,
    renderer_vertices,
    indices[:],
  )
  if !load_ok {
    log.error("Failed to load navigation mesh data into renderer")
    return false
  }
  renderer.enabled = true
  log.infof(
    "Navigation mesh visualization created with %d triangles",
    renderer.index_count / 3,
  )
  return true
}
