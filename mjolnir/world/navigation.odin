package world

import cont "../containers"
import "../geometry"
import "../gpu"
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
  obstacle_type:       resources.NavObstacleType,
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
    return u8(recast.RC_WALKABLE_AREA) // Default to walkable - to be enhanced later with obstacle detection
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
  config: recast.Config = {},
) -> (
  ret: resources.NavMeshHandle,
  ok: bool,
) #optional_ok {
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
    return {}, false
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
  pmesh, dmesh := recast.build_navmesh(
    collector.vertices[:],
    collector.indices[:],
    collector.area_types[:],
    config,
  ) or_return
  defer {
    recast.free_poly_mesh(pmesh)
    recast.free_poly_mesh_detail(dmesh)
  }
  nav_mesh: ^resources.NavMesh
  ret, nav_mesh = cont.alloc(&rm.nav_meshes, resources.NavMeshHandle) or_return
  nav_params := detour.Create_Nav_Mesh_Data_Params {
    poly_mesh          = pmesh,
    poly_mesh_detail   = dmesh,
    walkable_height    = f32(config.walkable_height) * config.ch,
    walkable_radius    = f32(config.walkable_radius) * config.cs,
    walkable_climb     = f32(config.walkable_climb) * config.ch,
    tile_x             = 0,
    tile_y             = 0,
    tile_layer         = 0,
    user_id            = 0,
    off_mesh_con_count = 0,
  }
  nav_data, create_status := detour.create_nav_mesh_data(&nav_params)
  if !recast.status_succeeded(create_status) {
    log.errorf("Failed to create navigation mesh data: %v", create_status)
    return ret, false
  }
  mesh_params := detour.Nav_Mesh_Params {
    orig        = pmesh.bmin,
    tile_width  = pmesh.bmax[0] - pmesh.bmin[0],
    tile_height = pmesh.bmax[2] - pmesh.bmin[2],
    max_tiles   = 1,
    max_polys   = 1024,
  }
  init_status := detour.nav_mesh_init(&nav_mesh.detour_mesh, &mesh_params)
  if !recast.status_succeeded(init_status) {
    log.errorf("Failed to initialize navigation mesh: %v", init_status)
    return ret, false
  }
  _, add_status := detour.nav_mesh_add_tile(
    &nav_mesh.detour_mesh,
    nav_data,
    recast.DT_TILE_FREE_DATA,
  )
  if !recast.status_succeeded(add_status) {
    log.errorf("Failed to add tile to navigation mesh: %v", add_status)
    detour.nav_mesh_destroy(&nav_mesh.detour_mesh)
    return ret, false
  }
  nav_mesh.bounds = calculate_bounds_from_vertices(collector.vertices[:])
  nav_mesh.cell_size = config.cs
  nav_mesh.tile_size = config.tile_size
  nav_mesh.is_tiled = config.tile_size > 0
  for i in 0 ..< 64 {
    nav_mesh.area_costs[i] = 1.0
  }
  log.infof("Successfully built world navigation mesh with handle %v", ret)
  return ret, true
}

calculate_bounds_from_vertices :: proc(vertices: [][3]f32) -> geometry.Aabb {
  if len(vertices) == 0 {
    return {}
  }
  min_pos := vertices[0]
  max_pos := vertices[0]
  for v in vertices[1:] {
    min_pos = linalg.min(min_pos, v)
    max_pos = linalg.max(max_pos, v)
  }
  return geometry.Aabb{min = min_pos, max = max_pos}
}

create_navigation_context :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  nav_mesh_handle: resources.NavMeshHandle,
) -> (
  ret: resources.NavContextHandle,
  ok: bool,
) #optional_ok {
  nav_mesh := cont.get(rm.nav_meshes, nav_mesh_handle)
  if nav_mesh == nil do return {}, false
  nav_context: ^resources.NavContext
  ret, nav_context = cont.alloc(&rm.nav_contexts, resources.NavContextHandle) or_return
  init_status := detour.nav_mesh_query_init(
    &nav_context.nav_mesh_query,
    &nav_mesh.detour_mesh,
    2048,
  )
  if !recast.status_succeeded(init_status) {
    log.errorf("Failed to initialize navigation mesh query: %v", init_status)
    cont.free(&rm.nav_contexts, ret)
    return ret, false
  }
  detour.query_filter_init(&nav_context.query_filter)
  nav_context.associated_mesh = nav_mesh_handle
  log.infof("Created navigation context with handle %v", ret)
  return ret, true
}

nav_find_path :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  context_handle: resources.NavContextHandle,
  start: [3]f32,
  end: [3]f32,
  max_path_length: i32 = 256,
) -> (
  path: [][3]f32,
  ok: bool,
) {
  nav_context := cont.get(rm.nav_contexts, context_handle)
  if nav_context == nil do return nil, false
  nav_mesh := cont.get(rm.nav_meshes, nav_context.associated_mesh)
  if nav_mesh == nil do return nil, false
  half_extents := [3]f32{2.0, 4.0, 2.0}
  status, start_ref, start_pos := detour.find_nearest_poly(
    &nav_context.nav_mesh_query,
    start,
    half_extents,
    &nav_context.query_filter,
  )
  if !recast.status_succeeded(status) || start_ref == recast.INVALID_POLY_REF {
    log.errorf(
      "Failed to find start polygon for pathfinding at position %v",
      start,
    )
    return nil, false
  }
  status2: recast.Status
  end_ref: recast.Poly_Ref
  end_pos: [3]f32
  status2, end_ref, end_pos = detour.find_nearest_poly(
    &nav_context.nav_mesh_query,
    end,
    half_extents,
    &nav_context.query_filter,
  )
  if !recast.status_succeeded(status2) || end_ref == recast.INVALID_POLY_REF {
    log.errorf(
      "Failed to find end polygon for pathfinding at position %v",
      end,
    )
    return nil, false
  }
  poly_path := make([]recast.Poly_Ref, max_path_length, context.temp_allocator)
  path_status, path_count := detour.find_path(
    &nav_context.nav_mesh_query,
    start_ref,
    end_ref,
    start_pos,
    end_pos,
    &nav_context.query_filter,
    poly_path[:],
    max_path_length,
  )
  if !recast.status_succeeded(path_status) || path_count == 0 {
    log.errorf(
      "Failed to find path from %v to %v: %v",
      start,
      end,
      path_status,
    )
    return nil, false
  }
  straight_path := make(
    []detour.Straight_Path_Point,
    max_path_length,
    context.temp_allocator,
  )
  straight_status, straight_path_count := detour.find_straight_path(
    &nav_context.nav_mesh_query,
    start_pos,
    end_pos,
    poly_path[:path_count],
    path_count,
    straight_path[:],
    nil,
    nil,
    max_path_length,
    u32(detour.Straight_Path_Options.All_Crossings),
  )
  if !recast.status_succeeded(straight_status) || straight_path_count == 0 {
    log.errorf("Failed to create straight path: %v", straight_status)
    return nil, false
  }
  result_path := make([][3]f32, straight_path_count)
  for i in 0 ..< straight_path_count {
    result_path[i] = straight_path[i].pos
  }
  log.infof(
    "Found path with %d waypoints from %v to %v",
    straight_path_count,
    start,
    end,
  )
  return result_path, true
}

nav_is_position_walkable :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  context_handle: resources.NavContextHandle,
  position: [3]f32,
) -> bool {
  nav_context := cont.get(rm.nav_contexts, context_handle)
  if nav_context == nil do return false
  half_extents := [3]f32{1.0, 2.0, 1.0}
  status, poly_ref, nearest_pos := detour.find_nearest_poly(
    &nav_context.nav_mesh_query,
    position,
    half_extents,
    &nav_context.query_filter,
  )
  return recast.status_succeeded(status) && poly_ref != recast.INVALID_POLY_REF
}

nav_find_nearest_point :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  context_handle: resources.NavContextHandle,
  position: [3]f32,
  search_extents: [3]f32 = {2.0, 4.0, 2.0},
) -> (
  nearest_pos: [3]f32,
  found: bool,
) {
  nav_context := cont.get(rm.nav_contexts, context_handle)
  if nav_context == nil do return {}, false
  status, poly_ref, result_pos := detour.find_nearest_poly(
    &nav_context.nav_mesh_query,
    position,
    search_extents,
    &nav_context.query_filter,
  )
  if recast.status_succeeded(status) && poly_ref != recast.INVALID_POLY_REF {
    return result_pos, true
  }
  return {}, false
}

spawn_nav_agent_at :: proc(
  world: ^World,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
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
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
  agent_handle: resources.NodeHandle,
  target: [3]f32,
  context_handle: resources.NavContextHandle = {},
) -> bool {
  node := cont.get(world.nodes, agent_handle)
  if node == nil {
    return false
  }
  agent := &node.attachment.(NavMeshAgentAttachment)
  agent.target_position = target
  if agent.pathfinding_enabled {
    nav_context_handle := context_handle
    if nav_context_handle == {} {
      nav_context_handle = rm.navigation_system.default_context_handle
    }
    current_pos := node.transform.position
    path, success := nav_find_path(
      world,
      rm,
      gctx,
      nav_context_handle,
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
  renderer: ^navmesh_renderer.Renderer,
  config: recast.Config = {},
) -> (
  nav_mesh_handle: resources.NavMeshHandle,
  success: bool,
) {
  mesh_handle, build_ok := build_navigation_mesh_from_world(
    world,
    rm,
    gctx,
    config,
  )
  if !build_ok {
    log.error("Failed to build navigation mesh from world")
    return {}, false
  }
  nav_mesh_handle = mesh_handle
  nav_mesh := cont.get(rm.nav_meshes, nav_mesh_handle)
  if nav_mesh == nil do return nav_mesh_handle, false
  tile := detour.get_tile_at(&nav_mesh.detour_mesh, 0, 0, 0)
  if tile == nil || tile.header == nil {
    log.error("Failed to get navigation mesh tile for visualization")
    return nav_mesh_handle, false
  }
  Vertex :: struct {
    position: [3]f32,
    color:    [4]f32,
  }
  navmesh_vertices := make([dynamic]Vertex, 0, int(tile.header.vert_count))
  indices := make([dynamic]u32, 0, int(tile.header.poly_count) * 3)
  defer delete(navmesh_vertices)
  defer delete(indices)
  // convert Detour vertices to renderer format
  for i in 0 ..< tile.header.vert_count {
    pos := tile.verts[i]
    append(
      &navmesh_vertices,
      Vertex{position = pos, color = {0.0, 0.8, 0.2, 0.6}},
    )
  }
  // convert Detour polygons to triangles
  for i in 0 ..< tile.header.poly_count {
    poly := &tile.polys[i]
    vert_count := int(poly.vert_count)
    if vert_count < 3 do continue
    // generate random color for each polygon
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
    // create triangles from polygon (fan triangulation)
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
    return nav_mesh_handle, false
  }
  renderer.enabled = true
  log.infof(
    "Navigation mesh visualization created with %d triangles",
    renderer.index_count / 3,
  )
  return nav_mesh_handle, true
}
