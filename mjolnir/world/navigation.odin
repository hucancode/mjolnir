package world

import "core:log"
import "core:math"
import "core:math/linalg"
import "../geometry"
import "../navigation/detour"
import "../navigation/recast"
import "../resources"
import "../gpu"
import navmesh_renderer "../render/navigation"

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
  resources_manager: ^resources.Manager,
  gpu_context:      ^gpu.GPUContext,
}

scene_geometry_collector_init :: proc(collector: ^SceneGeometryCollector) {
  collector.vertices = make([dynamic][3]f32, 0)
  collector.indices = make([dynamic]i32, 0)
  collector.area_types = make([dynamic]u8, 0)
  collector.mesh_count = 0

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
    mesh, ok := resources.get_mesh(collector.resources_manager, mesh_attachment.handle)
    if !ok {
      return true
    }
    world_matrix := node.transform.world_matrix
    area_type := u8(recast.RC_WALKABLE_AREA)
    if collector.area_type_mapper != nil {
      area_type = collector.area_type_mapper(node)
    }
    add_mesh_to_collector(
      collector,
      mesh,
      collector.resources_manager,
      collector.gpu_context,
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
  resources_manager: ^resources.Manager,
  gpu_context: ^gpu.GPUContext,
  transform: matrix[4, 4]f32,
  area_type: u8,
) {
  vertex_offset := i32(len(collector.vertices))

  vertex_count := int(mesh.vertex_allocation.count)
  vertices := make([]geometry.Vertex, vertex_count, context.temp_allocator)
  ret := gpu.static_buffer_read(
    gpu_context,
    &resources_manager.vertex_buffer,
    vertices,
    int(mesh.vertex_allocation.offset),
  )
  if ret != .SUCCESS {
    log.error("Failed to read vertex data from StaticBuffer")
    return
  }

  for vertex in vertices {
    transformed_pos := (transform * [4]f32{vertex.position.x, vertex.position.y, vertex.position.z, 1.0}).xyz
    append(&collector.vertices, transformed_pos)
  }

  index_count := int(mesh.index_allocation.count)
  indices := make([]u32, index_count, context.temp_allocator)
  ret = gpu.static_buffer_read(
    gpu_context,
    &resources_manager.index_buffer,
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
  for i in 0 ..< triangle_count {
    append(&collector.area_types, area_type)
  }
}

build_navigation_mesh_from_scene :: proc(
  world: ^World, resources_manager: ^resources.Manager, gpu_context: ^gpu.GPUContext,
  config: recast.Config = {},
) -> (
  resources.Handle,
  bool,
) {
  collector: SceneGeometryCollector
  scene_geometry_collector_init(&collector)
  collector.world, collector.resources_manager, collector.gpu_context = world, resources_manager, gpu_context
  defer scene_geometry_collector_destroy(&collector)

  traverse(collector.world, collector.resources_manager, &collector, scene_geometry_collector_traverse)

  if len(collector.vertices) == 0 || len(collector.indices) == 0 {
    return {}, false
  }

  pmesh, dmesh, ok := recast.build_navmesh(
    collector.vertices[:],
    collector.indices[:],
    collector.area_types[:],
    config,
  )
  if !ok {
    return {}, false
  }
  defer {
    recast.free_poly_mesh(pmesh)
    recast.free_poly_mesh_detail(dmesh)
  }

  nav_mesh_handle: resources.Handle
  nav_mesh: ^resources.NavMesh
  nav_mesh_handle, nav_mesh, ok = resources.alloc(&resources_manager.nav_meshes)
  if !ok {
    return nav_mesh_handle, false
  }

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
  if recast.status_failed(create_status) {
    return nav_mesh_handle, false
  }

  mesh_params := detour.Nav_Mesh_Params {
    orig        = pmesh.bmin,
    tile_width  = pmesh.bmax[0] - pmesh.bmin[0],
    tile_height = pmesh.bmax[2] - pmesh.bmin[2],
    max_tiles   = 1,
    max_polys   = 1024,
  }

  init_status := detour.nav_mesh_init(&nav_mesh.detour_mesh, &mesh_params)
  if recast.status_failed(init_status) {
    return nav_mesh_handle, false
  }

  _, add_status := detour.nav_mesh_add_tile(
    &nav_mesh.detour_mesh,
    nav_data,
    recast.DT_TILE_FREE_DATA,
  )
  if recast.status_failed(add_status) {
    detour.nav_mesh_destroy(&nav_mesh.detour_mesh)
    return nav_mesh_handle, false
  }

  nav_mesh.bounds = calculate_bounds_from_vertices(collector.vertices[:])
  nav_mesh.cell_size = config.cs
  nav_mesh.tile_size = config.tile_size
  nav_mesh.is_tiled = config.tile_size > 0

  for i in 0 ..< 64 {
    nav_mesh.area_costs[i] = 1.0
  }

  return nav_mesh_handle, true
}

// Build navigation mesh with custom geometry filter
build_navigation_mesh_from_scene_filtered :: proc(
  world: ^World, resources_manager: ^resources.Manager, gpu_context: ^gpu.GPUContext,
  include_filter: proc(node: ^Node) -> bool,
  area_type_mapper: proc(node: ^Node) -> u8 = nil,
  config: recast.Config = {},
) -> (
  resources.Handle,
  bool,
) {
  // Initialize geometry collector with custom filters
  collector: SceneGeometryCollector
  scene_geometry_collector_init(&collector)
  collector.world, collector.resources_manager, collector.gpu_context = world, resources_manager, gpu_context
  defer scene_geometry_collector_destroy(&collector)

  collector.include_filter = include_filter
  if area_type_mapper != nil {
    collector.area_type_mapper = area_type_mapper
  }

  // Collect geometry from scene
  traverse(collector.world, collector.resources_manager, &collector, scene_geometry_collector_traverse)

  if len(collector.vertices) == 0 || len(collector.indices) == 0 {
    log.error("No geometry found in scene for navigation mesh building")
    return {}, false
  }

  log.infof(
    "Collected %d vertices, %d indices from %d meshes for filtered navigation mesh",
    len(collector.vertices),
    len(collector.indices),
    collector.mesh_count,
  )

  // Build navigation mesh using Recast
  pmesh, dmesh, ok := recast.build_navmesh(
    collector.vertices[:],
    collector.indices[:],
    collector.area_types[:],
    config,
  )
  if !ok {
    log.error("Failed to build navigation mesh")
    return {}, false
  }
  defer {
    recast.free_poly_mesh(pmesh)
    recast.free_poly_mesh_detail(dmesh)
  }

  // Create and initialize resources.NavMesh resource (same as basic version)
  nav_mesh_handle: resources.Handle
  nav_mesh: ^resources.NavMesh
  nav_mesh_handle, nav_mesh, ok = resources.alloc(&resources_manager.nav_meshes)
  if !ok {
    log.error("Failed to allocate navigation mesh resource")
    return nav_mesh_handle, false
  }

  // Create navigation mesh data from Recast polygon mesh
  nav_params := detour.Create_Nav_Mesh_Data_Params {
    poly_mesh          = pmesh,
    poly_mesh_detail   = dmesh,

    // Agent parameters (convert from cells to world units)
    walkable_height    = f32(config.walkable_height) * config.ch,
    walkable_radius    = f32(config.walkable_radius) * config.cs,
    walkable_climb     = f32(config.walkable_climb) * config.ch,

    // Tile parameters (for single tile mesh)
    tile_x             = 0,
    tile_y             = 0,
    tile_layer         = 0,
    user_id            = 0,

    // Off-mesh connections (none for now)
    off_mesh_con_count = 0,
  }

  // Create navigation mesh data
  nav_data, create_status := detour.create_nav_mesh_data(&nav_params)
  if recast.status_failed(create_status) {
    log.errorf("Failed to create navigation mesh data: %v", create_status)
    return nav_mesh_handle, false
  }
  // Don't delete nav_data - ownership is transferred to nav mesh with DT_TILE_FREE_DATA flag

  // Initialize navigation mesh with parameters
  mesh_params := detour.Nav_Mesh_Params {
    orig        = pmesh.bmin,
    tile_width  = pmesh.bmax[0] - pmesh.bmin[0],
    tile_height = pmesh.bmax[2] - pmesh.bmin[2],
    max_tiles   = 1,
    max_polys   = 1024,
  }

  init_status := detour.nav_mesh_init(&nav_mesh.detour_mesh, &mesh_params)
  if recast.status_failed(init_status) {
    log.errorf("Failed to initialize navigation mesh: %v", init_status)
    return nav_mesh_handle, false
  }

  // Add the tile to the navigation mesh with DT_TILE_FREE_DATA flag
  _, add_status := detour.nav_mesh_add_tile(
    &nav_mesh.detour_mesh,
    nav_data,
    recast.DT_TILE_FREE_DATA,
  )
  if recast.status_failed(add_status) {
    log.errorf("Failed to add tile to navigation mesh: %v", add_status)
    detour.nav_mesh_destroy(&nav_mesh.detour_mesh)
    return nav_mesh_handle, false
  }

  nav_mesh.bounds = calculate_bounds_from_vertices(collector.vertices[:])
  nav_mesh.cell_size = config.cs
  nav_mesh.tile_size = config.tile_size
  nav_mesh.is_tiled = config.tile_size > 0

  for i in 0 ..< 64 {
    nav_mesh.area_costs[i] = 1.0
  }

  log.infof(
    "Successfully built filtered navigation mesh with handle %v",
    nav_mesh_handle,
  )
  return nav_mesh_handle, true
}

// Build navigation mesh from world nodes with automatic obstacle detection
build_navigation_mesh_from_world :: proc(
  world: ^World, resources_manager: ^resources.Manager, gpu_context: ^gpu.GPUContext,
  config: recast.Config = {},
) -> (
  resources.Handle,
  bool,
) {
  // Initialize geometry collector with obstacle-aware filters
  collector: SceneGeometryCollector
  scene_geometry_collector_init(&collector)
  collector.world, collector.resources_manager, collector.gpu_context = world, resources_manager, gpu_context
  defer scene_geometry_collector_destroy(&collector)

  // Custom filter to include all mesh nodes
  collector.include_filter = proc(node: ^Node) -> bool {
    _, is_mesh := node.attachment.(MeshAttachment)
    return is_mesh
  }

  // Area type mapper - mark everything as walkable and let Recast filter obstacles
  collector.area_type_mapper = proc(node: ^Node) -> u8 {
    return u8(recast.RC_WALKABLE_AREA)
  }

  // Collect geometry from scene
  traverse(collector.world, collector.resources_manager, &collector, scene_geometry_collector_traverse)

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

  // Debug: Print first few vertices and bounds
  if len(collector.vertices) > 0 {
    log.infof("First vertex: (%.3f, %.3f, %.3f)", collector.vertices[0].x, collector.vertices[0].y, collector.vertices[0].z)
    if len(collector.vertices) > 1 {
      log.infof("Second vertex: (%.3f, %.3f, %.3f)", collector.vertices[1].x, collector.vertices[1].y, collector.vertices[1].z)
    }

    // Calculate bounds
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
    log.infof("Geometry bounds: min(%.3f, %.3f, %.3f) max(%.3f, %.3f, %.3f)",
             min_pos.x, min_pos.y, min_pos.z, max_pos.x, max_pos.y, max_pos.z)
  }

  // Debug: Print area types
  walkable_count := 0
  obstacle_count := 0
  for area in collector.area_types {
    if area == u8(recast.RC_WALKABLE_AREA) {
      walkable_count += 1
    } else if area == u8(recast.RC_NULL_AREA) {
      obstacle_count += 1
    }
  }
  log.infof("Area types: %d walkable triangles, %d obstacle triangles", walkable_count, obstacle_count)

  // Debug: Print configuration
  log.infof("Recast Config: cs=%.3f, ch=%.3f, walkable_radius=%d, min_region=%d",
           config.cs, config.ch, config.walkable_radius, config.min_region_area)

  // Build navigation mesh using Recast
  pmesh, dmesh, ok := recast.build_navmesh(
    collector.vertices[:],
    collector.indices[:],
    collector.area_types[:],
    config,
  )
  if !ok {
    log.error("Failed to build navigation mesh from world")
    return {}, false
  }
  defer {
    recast.free_poly_mesh(pmesh)
    recast.free_poly_mesh_detail(dmesh)
  }

  // Create and initialize resources.NavMesh resource
  nav_mesh_handle: resources.Handle
  nav_mesh: ^resources.NavMesh
  nav_mesh_handle, nav_mesh, ok = resources.alloc(&resources_manager.nav_meshes)
  if !ok {
    log.error("Failed to allocate navigation mesh resource")
    return nav_mesh_handle, false
  }

  // Create navigation mesh data from Recast polygon mesh
  nav_params := detour.Create_Nav_Mesh_Data_Params {
    poly_mesh          = pmesh,
    poly_mesh_detail   = dmesh,

    // Agent parameters (convert from cells to world units)
    walkable_height    = f32(config.walkable_height) * config.ch,
    walkable_radius    = f32(config.walkable_radius) * config.cs,
    walkable_climb     = f32(config.walkable_climb) * config.ch,

    // Tile parameters (for single tile mesh)
    tile_x             = 0,
    tile_y             = 0,
    tile_layer         = 0,
    user_id            = 0,

    // Off-mesh connections (none for now)
    off_mesh_con_count = 0,
  }

  // Create navigation mesh data
  nav_data, create_status := detour.create_nav_mesh_data(&nav_params)
  if recast.status_failed(create_status) {
    log.errorf("Failed to create navigation mesh data: %v", create_status)
    return nav_mesh_handle, false
  }

  // Initialize navigation mesh with parameters
  mesh_params := detour.Nav_Mesh_Params {
    orig        = pmesh.bmin,
    tile_width  = pmesh.bmax[0] - pmesh.bmin[0],
    tile_height = pmesh.bmax[2] - pmesh.bmin[2],
    max_tiles   = 1,
    max_polys   = 1024,
  }

  init_status := detour.nav_mesh_init(&nav_mesh.detour_mesh, &mesh_params)
  if recast.status_failed(init_status) {
    log.errorf("Failed to initialize navigation mesh: %v", init_status)
    return nav_mesh_handle, false
  }

  // Add the tile to the navigation mesh
  _, add_status := detour.nav_mesh_add_tile(
    &nav_mesh.detour_mesh,
    nav_data,
    recast.DT_TILE_FREE_DATA,
  )
  if recast.status_failed(add_status) {
    log.errorf("Failed to add tile to navigation mesh: %v", add_status)
    detour.nav_mesh_destroy(&nav_mesh.detour_mesh)
    return nav_mesh_handle, false
  }

  nav_mesh.bounds = calculate_bounds_from_vertices(collector.vertices[:])
  nav_mesh.cell_size = config.cs
  nav_mesh.tile_size = config.tile_size
  nav_mesh.is_tiled = config.tile_size > 0

  for i in 0 ..< 64 {
    nav_mesh.area_costs[i] = 1.0
  }

  log.infof(
    "Successfully built world navigation mesh with handle %v",
    nav_mesh_handle,
  )
  return nav_mesh_handle, true
}

// Helper function to calculate bounds from vertices
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

// Create navigation context for queries
create_navigation_context :: proc(
  world: ^World, resources_manager: ^resources.Manager, gpu_context: ^gpu.GPUContext,
  nav_mesh_handle: resources.Handle,
) -> (
  resources.Handle,
  bool,
) {
  nav_mesh, ok := resources.get_navmesh(resources_manager, nav_mesh_handle)
  if !ok {
    log.error("Invalid navigation mesh handle for context creation")
    return {}, false
  }
  context_handle: resources.Handle
  nav_context: ^resources.NavContext
  context_handle, nav_context, ok = resources.alloc(&resources_manager.nav_contexts)
  if !ok {
    log.error("Failed to allocate navigation context")
    return context_handle, false
  }
  init_status := detour.nav_mesh_query_init(
    &nav_context.nav_mesh_query,
    &nav_mesh.detour_mesh,
    2048,
  )
  if recast.status_failed(init_status) {
    log.errorf("Failed to initialize navigation mesh query: %v", init_status)
    resources.free(&resources_manager.nav_contexts, context_handle)
    return context_handle, false
  }
  detour.query_filter_init(&nav_context.query_filter)
  nav_context.associated_mesh = nav_mesh_handle
  log.infof("Created navigation context with handle %v", context_handle)
  return context_handle, true
}

// Find path between two points
nav_find_path :: proc(
  world: ^World, resources_manager: ^resources.Manager, gpu_context: ^gpu.GPUContext,
  context_handle: resources.Handle,
  start: [3]f32,
  end: [3]f32,
  max_path_length: i32 = 256,
) -> (
  path: [][3]f32,
  success: bool,
) {
  nav_context, ok := resources.get_nav_context(resources_manager, context_handle)
  if !ok {
    log.error("Invalid navigation context handle")
    return nil, false
  }
  nav_mesh, mesh_found := resources.get_navmesh(resources_manager, nav_context.associated_mesh)
  if !mesh_found {
    log.error("Invalid navigation mesh associated with context")
    return nil, false
  }
  half_extents := [3]f32{2.0, 4.0, 2.0} // Search area for finding polygons
  status, start_ref, start_pos := detour.find_nearest_poly(
    &nav_context.nav_mesh_query,
    start,
    half_extents,
    &nav_context.query_filter,
  )
  if recast.status_failed(status) || start_ref == recast.INVALID_POLY_REF {
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
  if recast.status_failed(status2) || end_ref == recast.INVALID_POLY_REF {
    log.errorf(
      "Failed to find end polygon for pathfinding at position %v",
      end,
    )
    return nil, false
  }

  // Find path between polygons
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

  if recast.status_failed(path_status) || path_count == 0 {
    log.errorf(
      "Failed to find path from %v to %v: %v",
      start,
      end,
      path_status,
    )
    return nil, false
  }

  // Convert polygon path to straight path (string pulling)
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

  if recast.status_failed(straight_status) || straight_path_count == 0 {
    log.errorf("Failed to create straight path: %v", straight_status)
    return nil, false
  }

  // Convert straight path points to result
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

// Check if a position is walkable
nav_is_position_walkable :: proc(
  world: ^World, resources_manager: ^resources.Manager, gpu_context: ^gpu.GPUContext,
  context_handle: resources.Handle,
  position: [3]f32,
) -> bool {
  nav_context, ok := resources.get_nav_context(resources_manager, context_handle)
  if !ok {
    return false
  }

  half_extents := [3]f32{1.0, 2.0, 1.0}

  status, poly_ref, nearest_pos := detour.find_nearest_poly(
    &nav_context.nav_mesh_query,
    position,
    half_extents,
    &nav_context.query_filter,
  )
  return recast.status_succeeded(status) && poly_ref != recast.INVALID_POLY_REF
}

// Spawn navigation agent at position
spawn_nav_agent_at :: proc(
  world: ^World, resources_manager: ^resources.Manager, gpu_context: ^gpu.GPUContext,
  position: [3]f32,
  radius: f32 = 0.5,
  height: f32 = 2.0,
) -> (
  resources.Handle,
  ^Node,
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
  handle, node, ok := spawn_at(world, position, attachment)
  if !ok {
    return {}, nil
  }
  return handle, node
}

// Set navigation agent target
nav_agent_set_target :: proc(
  world: ^World, resources_manager: ^resources.Manager, gpu_context: ^gpu.GPUContext,
  agent_handle: resources.Handle,
  target: [3]f32,
  context_handle: resources.Handle = {},
) -> bool {
  node := resources.get(world.nodes, agent_handle)
  if node == nil {
    return false
  }

  agent := &node.attachment.(NavMeshAgentAttachment)

  agent.target_position = target

  // Find path if pathfinding is enabled
  if agent.pathfinding_enabled {
    // Use provided context or default
    nav_context_handle := context_handle
    if nav_context_handle == {} {
      nav_context_handle =
        resources_manager.navigation_system.default_context_handle
    }

    current_pos := node.transform.position
    path, success := nav_find_path(
      world,
      resources_manager,
      gpu_context,
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

// Build navigation mesh from world and setup rendering
build_and_visualize_navigation_mesh :: proc(
  world: ^World,
  resources_manager: ^resources.Manager,
  gpu_context: ^gpu.GPUContext,
  renderer: ^navmesh_renderer.Renderer,
  config: recast.Config = {},
) -> (nav_mesh_handle: resources.Handle, success: bool) {

  // Build navigation mesh from world geometry
  mesh_handle, build_ok := build_navigation_mesh_from_world(world, resources_manager, gpu_context, config)
  if !build_ok {
    log.error("Failed to build navigation mesh from world")
    return {}, false
  }
  nav_mesh_handle = mesh_handle

  // Get the navigation mesh for visualization
  nav_mesh, found := resources.get_navmesh(resources_manager, nav_mesh_handle)
  if !found {
    log.error("Failed to get navigation mesh for visualization")
    return nav_mesh_handle, false
  }

  // Build visualization from Detour mesh
  tile := detour.get_tile_at(&nav_mesh.detour_mesh, 0, 0, 0)
  if tile == nil || tile.header == nil {
    log.error("Failed to get navigation mesh tile for visualization")
    return nav_mesh_handle, false
  }

  // Create visualization vertices and indices
  Vertex :: struct {
    position: [3]f32,
    color:    [4]f32,
  }
  navmesh_vertices := make([dynamic]Vertex, 0, int(tile.header.vert_count))
  indices := make([dynamic]u32, 0, int(tile.header.poly_count) * 3)
  defer delete(navmesh_vertices)
  defer delete(indices)

  // Convert Detour vertices to renderer format
  for i in 0..<tile.header.vert_count {
    pos := tile.verts[i]
    append(&navmesh_vertices, Vertex{
      position = pos,
      color = {0.0, 0.8, 0.2, 0.6},
    })
  }

  // Convert Detour polygons to triangles
  for i in 0..<tile.header.poly_count {
    poly := &tile.polys[i]
    vert_count := int(poly.vert_count)
    if vert_count < 3 do continue

    // Generate random color for each polygon
    poly_seed := u32(i * 17 + 23)
    hue := f32((poly_seed * 137) % 360)
    poly_color := [4]f32{
      0.5 + 0.5 * math.sin(hue * math.PI / 180.0),
      0.5 + 0.5 * math.sin((hue + 120) * math.PI / 180.0),
      0.5 + 0.5 * math.sin((hue + 240) * math.PI / 180.0),
      0.6,
    }

    // Apply color to vertices
    for j in 0..<vert_count {
      if int(poly.verts[j]) < len(navmesh_vertices) {
        navmesh_vertices[poly.verts[j]].color = poly_color
      }
    }

    // Create triangles from polygon (fan triangulation)
    for j in 1..<vert_count-1 {
      append(&indices, u32(poly.verts[0]), u32(poly.verts[j]), u32(poly.verts[j+1]))
    }
  }

  // Convert vertices to renderer format using transmute since they have identical layout
  renderer_vertices := transmute([]navmesh_renderer.Vertex)navmesh_vertices[:]

  load_ok := navmesh_renderer.load_navmesh_data(renderer, renderer_vertices, indices[:])
  if !load_ok {
    log.error("Failed to load navigation mesh data into renderer")
    return nav_mesh_handle, false
  }

  // Configure renderer
  renderer.enabled = true

  log.infof("Navigation mesh visualization created with %d triangles", renderer.index_count / 3)

  return nav_mesh_handle, true
}
