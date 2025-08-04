package mjolnir

import "core:log"
import "core:math/linalg"
import "core:slice"
import "geometry"
import "resource"
import nav_recast "navigation/recast"
import recast "navigation/recast"
import detour "navigation/detour"

// Navigation integration for Mjolnir engine
// Uses types defined in other mjolnir package files

// Navigation mesh component for scene nodes
NavMeshAttachment :: struct {
    nav_mesh_handle: Handle,           // Handle to NavMesh resource
    tile_x:          i32,              // For tiled nav meshes
    tile_y:          i32,
    area_type:       u8,               // Area type for pathfinding costs
    enabled:         bool,             // Can disable for dynamic obstacles
}

// Navigation agent component for moving entities
NavMeshAgentAttachment :: struct {
    target_position:     [3]f32,       // Current pathfinding target
    current_path:        [][3]f32,     // Current path points
    path_index:          i32,          // Current point in path
    agent_radius:        f32,          // Agent collision radius
    agent_height:        f32,          // Agent height for clearance
    max_speed:           f32,          // Maximum movement speed
    max_acceleration:    f32,          // For smooth movement
    arrival_distance:    f32,          // How close to consider "arrived"
    auto_update_path:    bool,         // Automatically recalculate path
    pathfinding_enabled: bool,         // Can disable pathfinding
}

// Navigation obstacle component for dynamic obstacles
NavMeshObstacleAttachment :: struct {
    obstacle_bounds: geometry.Aabb,    // Obstacle dimensions
    affects_pathfinding: bool,         // Whether to rebuild nav mesh
    obstacle_type: NavObstacleType,    // Static vs dynamic
}

NavObstacleType :: enum {
    Static,   // Permanent obstacle, requires nav mesh rebuild
    Dynamic,  // Temporary obstacle, use dynamic avoidance
}

// Navigation mesh resource
NavMesh :: struct {
    detour_mesh:     detour.Nav_Mesh,
    bounds:          geometry.Aabb,
    cell_size:       f32,
    tile_size:       i32,
    is_tiled:        bool,
    area_costs:      [64]f32,  // Cost multiplier per area type
}

// Navigation context for queries
NavContext :: struct {
    nav_mesh_query:  detour.Nav_Mesh_Query,
    associated_mesh: Handle,    // Handle to NavMesh
    query_filter:    detour.Query_Filter,
}

// Navigation system state
NavigationSystem :: struct {
    default_context_handle: Handle,     // Default navigation context
    geometry_cache:         [dynamic]NavigationGeometry,
    dirty_tiles:           map[TileCoord]bool,
    rebuild_queued:        bool,
}

NavigationGeometry :: struct {
    vertices:   []f32,
    indices:    []i32,
    area_types: []u8,
    transform:  matrix[4,4]f32,
    dirty:      bool,
}

TileCoord :: struct {
    x, y: i32,
}

// Scene geometry collector for navigation mesh building
SceneGeometryCollector :: struct {
    vertices:         [dynamic]f32,
    indices:          [dynamic]i32,
    area_types:       [dynamic]u8,
    mesh_count:       i32,
    include_filter:   proc(node: ^Node) -> bool,  // Optional filter function
    area_type_mapper: proc(node: ^Node) -> u8,    // Maps nodes to area types
    engine:           ^Engine,                     // Reference to engine for mesh access
}

// Initialize scene geometry collector
scene_geometry_collector_init :: proc(collector: ^SceneGeometryCollector) {
    collector.vertices = make([dynamic]f32, 0)
    collector.indices = make([dynamic]i32, 0)
    collector.area_types = make([dynamic]u8, 0)
    collector.mesh_count = 0
    
    // Default filter: include all mesh nodes
    collector.include_filter = proc(node: ^Node) -> bool {
        _, is_mesh := node.attachment.(MeshAttachment)
        return is_mesh
    }
    
    // Default area type mapper: walkable area for all
    collector.area_type_mapper = proc(node: ^Node) -> u8 {
        return u8(nav_recast.RC_WALKABLE_AREA)
    }
}

// Clean up scene geometry collector
scene_geometry_collector_deinit :: proc(collector: ^SceneGeometryCollector) {
    delete(collector.vertices)
    delete(collector.indices)
    delete(collector.area_types)
}

// Collect geometry from scene nodes
scene_geometry_collector_traverse :: proc(node: ^Node, ctx: rawptr) -> bool {
    collector := cast(^SceneGeometryCollector)ctx
    
    // Skip if filter rejects this node
    if collector.include_filter != nil && !collector.include_filter(node) {
        return true
    }
    
    // Process mesh attachments
    if mesh_attachment, is_mesh := node.attachment.(MeshAttachment); is_mesh {
        mesh := resource.get(collector.engine.warehouse.meshes, mesh_attachment.handle)
        if mesh == nil {
            return true
        }
        
        // Get world transform
        world_matrix := geometry.transform_get_world_matrix(&node.transform)
        
        // Get area type for this node
        area_type := u8(nav_recast.RC_WALKABLE_AREA)
        if collector.area_type_mapper != nil {
            area_type = collector.area_type_mapper(node)
        }
        
        // Extract mesh data and transform vertices
        add_mesh_to_collector(collector, mesh, world_matrix, area_type)
        collector.mesh_count += 1
    }
    
    return true
}

// Add a mesh to the geometry collector with transformation
add_mesh_to_collector :: proc(collector: ^SceneGeometryCollector, mesh: ^Mesh, transform: matrix[4,4]f32, area_type: u8) {
    if mesh.vertex_buffer.mapped == nil || mesh.index_buffer.mapped == nil {
        return
    }
    
    // Calculate vertex offset for indices
    vertex_offset := i32(len(collector.vertices) / 3)
    
    // Transform and add vertices
    vertex_count := int(mesh.vertices_len)
    for i in 0..<vertex_count {
        // Extract position from vertex buffer (Vertex struct has position as first field)
        vertex := mesh.vertex_buffer.mapped[i]
        pos := vertex.position
        
        // Transform position to world space
        world_pos := linalg.matrix_mul_vector(transform, [4]f32{pos.x, pos.y, pos.z, 1.0})
        
        // Add to vertices array
        append(&collector.vertices, world_pos.x, world_pos.y, world_pos.z)
    }
    
    // Add indices with offset
    index_count := int(mesh.indices_len)
    for i in 0..<index_count {
        index := mesh.index_buffer.mapped[i]
        append(&collector.indices, i32(index) + vertex_offset)
    }
    
    // Add area types for each triangle
    triangle_count := index_count / 3
    for i in 0..<triangle_count {
        append(&collector.area_types, area_type)
    }
}

// Build navigation mesh from scene geometry
build_navigation_mesh_from_scene :: proc(engine: ^Engine, config: recast.Config = {}) -> (Handle, bool) {
    // Initialize geometry collector
    collector: SceneGeometryCollector
    scene_geometry_collector_init(&collector)
    collector.engine = engine
    defer scene_geometry_collector_deinit(&collector)
    
    // Collect geometry from scene
    scene_traverse(&engine.scene, &collector, scene_geometry_collector_traverse)
    
    if len(collector.vertices) == 0 || len(collector.indices) == 0 {
        log.error("No geometry found in scene for navigation mesh building")
        return {}, false
    }
    
    log.infof("Collected %d vertices, %d indices from %d meshes for navigation mesh", 
              len(collector.vertices)/3, len(collector.indices), collector.mesh_count)
    
    // Build navigation mesh using Recast
    pmesh, dmesh, ok := recast.build_navmesh(collector.vertices[:], collector.indices[:], collector.area_types[:], config)
    if !ok {
        log.error("Failed to build navigation mesh")
        return {}, false
    }
    defer {
        if pmesh != nil do recast.free_poly_mesh(pmesh)
        if dmesh != nil do recast.free_poly_mesh_detail(dmesh)
    }
    
    // Create NavMesh resource
    nav_mesh_handle, nav_mesh := resource.alloc(&engine.warehouse.nav_meshes)
    if nav_mesh == nil {
        log.error("Failed to allocate navigation mesh resource")
        return nav_mesh_handle, false
    }
    
    // Create navigation mesh data from Recast polygon mesh
    nav_params := detour.Create_Nav_Mesh_Data_Params{
        poly_mesh = pmesh,
        poly_mesh_detail = dmesh,
        
        // Agent parameters (convert from cells to world units)
        walkable_height = f32(config.walkable_height) * config.ch,
        walkable_radius = f32(config.walkable_radius) * config.cs,
        walkable_climb = f32(config.walkable_climb) * config.ch,
        
        // Tile parameters (for single tile mesh)
        tile_x = 0,
        tile_y = 0,
        tile_layer = 0,
        user_id = 0,
        
        // Off-mesh connections (none for now)
        off_mesh_con_count = 0,
    }
    
    // Create navigation mesh data
    nav_data, create_status := detour.create_nav_mesh_data(&nav_params)
    if nav_recast.status_failed(create_status) {
        log.errorf("Failed to create navigation mesh data: %v", create_status)
        return nav_mesh_handle, false
    }
    // Don't delete nav_data - ownership is transferred to nav mesh with DT_TILE_FREE_DATA flag
    
    // Initialize navigation mesh with parameters
    mesh_params := detour.Nav_Mesh_Params{
        orig = pmesh.bmin,
        tile_width = pmesh.bmax[0] - pmesh.bmin[0],
        tile_height = pmesh.bmax[2] - pmesh.bmin[2],
        max_tiles = 1,
        max_polys = 1024,
    }
    
    init_status := detour.nav_mesh_init(&nav_mesh.detour_mesh, &mesh_params)
    if nav_recast.status_failed(init_status) {
        log.errorf("Failed to initialize navigation mesh: %v", init_status)
        return nav_mesh_handle, false
    }
    
    // Add the tile to the navigation mesh with DT_TILE_FREE_DATA flag
    _, add_status := detour.nav_mesh_add_tile(&nav_mesh.detour_mesh, nav_data, nav_recast.DT_TILE_FREE_DATA)
    if nav_recast.status_failed(add_status) {
        log.errorf("Failed to add tile to navigation mesh: %v", add_status)
        detour.nav_mesh_destroy(&nav_mesh.detour_mesh)
        return nav_mesh_handle, false
    }
    
    // Set navigation mesh properties
    nav_mesh.bounds = calculate_bounds_from_vertices(collector.vertices[:])
    nav_mesh.cell_size = config.cs
    nav_mesh.tile_size = config.tile_size
    nav_mesh.is_tiled = config.tile_size > 0
    
    // Initialize default area costs
    for i in 0..<64 {
        nav_mesh.area_costs[i] = 1.0
    }
    
    log.infof("Successfully built navigation mesh with handle %v", nav_mesh_handle)
    return nav_mesh_handle, true
}

// Build navigation mesh with custom geometry filter
build_navigation_mesh_from_scene_filtered :: proc(
    engine: ^Engine, 
    include_filter: proc(node: ^Node) -> bool,
    area_type_mapper: proc(node: ^Node) -> u8 = nil,
    config: recast.Config = {}
) -> (Handle, bool) {
    // Initialize geometry collector with custom filters
    collector: SceneGeometryCollector
    scene_geometry_collector_init(&collector)
    collector.engine = engine
    defer scene_geometry_collector_deinit(&collector)
    
    collector.include_filter = include_filter
    if area_type_mapper != nil {
        collector.area_type_mapper = area_type_mapper
    }
    
    // Collect geometry from scene
    scene_traverse(&engine.scene, &collector, scene_geometry_collector_traverse)
    
    if len(collector.vertices) == 0 || len(collector.indices) == 0 {
        log.error("No geometry found in scene for navigation mesh building")
        return {}, false
    }
    
    log.infof("Collected %d vertices, %d indices from %d meshes for filtered navigation mesh", 
              len(collector.vertices)/3, len(collector.indices), collector.mesh_count)
    
    // Build navigation mesh using Recast
    pmesh, dmesh, ok := recast.build_navmesh(collector.vertices[:], collector.indices[:], collector.area_types[:], config)
    if !ok {
        log.error("Failed to build navigation mesh")
        return {}, false
    }
    defer {
        if pmesh != nil do recast.free_poly_mesh(pmesh)
        if dmesh != nil do recast.free_poly_mesh_detail(dmesh)
    }
    
    // Create and initialize NavMesh resource (same as basic version)
    nav_mesh_handle, nav_mesh := resource.alloc(&engine.warehouse.nav_meshes)
    if nav_mesh == nil {
        log.error("Failed to allocate navigation mesh resource")
        return nav_mesh_handle, false
    }
    
    // Create navigation mesh data from Recast polygon mesh
    nav_params := detour.Create_Nav_Mesh_Data_Params{
        poly_mesh = pmesh,
        poly_mesh_detail = dmesh,
        
        // Agent parameters (convert from cells to world units)
        walkable_height = f32(config.walkable_height) * config.ch,
        walkable_radius = f32(config.walkable_radius) * config.cs,
        walkable_climb = f32(config.walkable_climb) * config.ch,
        
        // Tile parameters (for single tile mesh)
        tile_x = 0,
        tile_y = 0,
        tile_layer = 0,
        user_id = 0,
        
        // Off-mesh connections (none for now)
        off_mesh_con_count = 0,
    }
    
    // Create navigation mesh data
    nav_data, create_status := detour.create_nav_mesh_data(&nav_params)
    if nav_recast.status_failed(create_status) {
        log.errorf("Failed to create navigation mesh data: %v", create_status)
        return nav_mesh_handle, false
    }
    // Don't delete nav_data - ownership is transferred to nav mesh with DT_TILE_FREE_DATA flag
    
    // Initialize navigation mesh with parameters
    mesh_params := detour.Nav_Mesh_Params{
        orig = pmesh.bmin,
        tile_width = pmesh.bmax[0] - pmesh.bmin[0],
        tile_height = pmesh.bmax[2] - pmesh.bmin[2],
        max_tiles = 1,
        max_polys = 1024,
    }
    
    init_status := detour.nav_mesh_init(&nav_mesh.detour_mesh, &mesh_params)
    if nav_recast.status_failed(init_status) {
        log.errorf("Failed to initialize navigation mesh: %v", init_status)
        return nav_mesh_handle, false
    }
    
    // Add the tile to the navigation mesh with DT_TILE_FREE_DATA flag
    _, add_status := detour.nav_mesh_add_tile(&nav_mesh.detour_mesh, nav_data, nav_recast.DT_TILE_FREE_DATA)
    if nav_recast.status_failed(add_status) {
        log.errorf("Failed to add tile to navigation mesh: %v", add_status)
        detour.nav_mesh_destroy(&nav_mesh.detour_mesh)
        return nav_mesh_handle, false
    }
    
    nav_mesh.bounds = calculate_bounds_from_vertices(collector.vertices[:])
    nav_mesh.cell_size = config.cs
    nav_mesh.tile_size = config.tile_size
    nav_mesh.is_tiled = config.tile_size > 0
    
    for i in 0..<64 {
        nav_mesh.area_costs[i] = 1.0
    }
    
    log.infof("Successfully built filtered navigation mesh with handle %v", nav_mesh_handle)
    return nav_mesh_handle, true
}

// Helper function to calculate bounds from vertices
calculate_bounds_from_vertices :: proc(vertices: []f32) -> geometry.Aabb {
    if len(vertices) < 3 {
        return {}
    }
    
    min_pos := [3]f32{vertices[0], vertices[1], vertices[2]}  
    max_pos := [3]f32{vertices[0], vertices[1], vertices[2]}
    
    for i := 3; i < len(vertices); i += 3 {
        pos := [3]f32{vertices[i], vertices[i+1], vertices[i+2]}
        min_pos = linalg.min(min_pos, pos)
        max_pos = linalg.max(max_pos, pos)
    }
    
    return geometry.Aabb{
        min = min_pos,
        max = max_pos,
    }
}

// Create navigation context for queries
create_navigation_context :: proc(engine: ^Engine, nav_mesh_handle: Handle) -> (Handle, bool) {
    nav_mesh := resource.get(engine.warehouse.nav_meshes, nav_mesh_handle)
    if nav_mesh == nil {
        log.error("Invalid navigation mesh handle for context creation")
        return {}, false
    }
    
    context_handle, nav_context := resource.alloc(&engine.warehouse.nav_contexts)
    if nav_context == nil {
        log.error("Failed to allocate navigation context")
        return context_handle, false
    }
    
    // Initialize navigation mesh query
    init_status := detour.nav_mesh_query_init(&nav_context.nav_mesh_query, &nav_mesh.detour_mesh, 2048)
    if nav_recast.status_failed(init_status) {
        log.errorf("Failed to initialize navigation mesh query: %v", init_status)
        resource.free(&engine.warehouse.nav_contexts, context_handle)
        return context_handle, false
    }
    
    // Initialize query filter
    detour.query_filter_init(&nav_context.query_filter)
    nav_context.associated_mesh = nav_mesh_handle
    
    log.infof("Created navigation context with handle %v", context_handle)
    return context_handle, true
}

// Navigation convenience functions

// Find path between two points
nav_find_path :: proc(engine: ^Engine, context_handle: Handle, start: [3]f32, end: [3]f32, max_path_length: i32 = 256) -> (path: [][3]f32, success: bool) {
    nav_context := resource.get(engine.warehouse.nav_contexts, context_handle)
    if nav_context == nil {
        log.error("Invalid navigation context handle")
        return nil, false
    }
    
    // Get navigation mesh from context
    nav_mesh := resource.get(engine.warehouse.nav_meshes, nav_context.associated_mesh)
    if nav_mesh == nil {
        log.error("Invalid navigation mesh associated with context")
        return nil, false
    }
    
    // Find nearest polygon to start and end positions
    half_extents := [3]f32{2.0, 4.0, 2.0}  // Search area for finding polygons
    
    start_ref: nav_recast.Poly_Ref
    start_pos: [3]f32
    status := detour.find_nearest_poly(&nav_context.nav_mesh_query, start, half_extents, &nav_context.query_filter, &start_ref, &start_pos)
    if nav_recast.status_failed(status) || start_ref == nav_recast.INVALID_POLY_REF {
        log.errorf("Failed to find start polygon for pathfinding at position %v", start)
        return nil, false
    }
    
    end_ref: nav_recast.Poly_Ref
    end_pos: [3]f32
    status = detour.find_nearest_poly(&nav_context.nav_mesh_query, end, half_extents, &nav_context.query_filter, &end_ref, &end_pos)
    if nav_recast.status_failed(status) || end_ref == nav_recast.INVALID_POLY_REF {
        log.errorf("Failed to find end polygon for pathfinding at position %v", end)
        return nil, false
    }
    
    // Find path between polygons
    poly_path := make([]nav_recast.Poly_Ref, max_path_length)
    defer delete(poly_path)
    path_count: i32
    
    status = detour.find_path(&nav_context.nav_mesh_query, start_ref, end_ref, start_pos, end_pos, 
                                &nav_context.query_filter, poly_path[:], &path_count, max_path_length)
    
    if nav_recast.status_failed(status) || path_count == 0 {
        log.errorf("Failed to find path from %v to %v: %v", start, end, status)
        return nil, false
    }
    
    // Convert polygon path to straight path (string pulling)
    straight_path := make([]detour.Straight_Path_Point, max_path_length)
    defer delete(straight_path)
    straight_path_count: i32
    
    status = detour.find_straight_path(&nav_context.nav_mesh_query, start_pos, end_pos, 
                                         poly_path[:path_count], path_count,
                                         straight_path[:], nil, nil, &straight_path_count, 
                                         max_path_length, u32(detour.Straight_Path_Options.All_Crossings))
    
    if nav_recast.status_failed(status) || straight_path_count == 0 {
        log.errorf("Failed to create straight path: %v", status)
        return nil, false
    }
    
    // Convert straight path points to result
    result_path := make([][3]f32, straight_path_count)
    for i in 0..<straight_path_count {
        result_path[i] = straight_path[i].pos
    }
    
    log.infof("Found path with %d waypoints from %v to %v", straight_path_count, start, end)
    return result_path, true
}

// Check if a position is walkable
nav_is_position_walkable :: proc(engine: ^Engine, context_handle: Handle, position: [3]f32) -> bool {
    nav_context := resource.get(engine.warehouse.nav_contexts, context_handle)
    if nav_context == nil {
        return false
    }
    
    poly_ref: nav_recast.Poly_Ref
    nearest_pos: [3]f32
    half_extents := [3]f32{1.0, 2.0, 1.0}
    
    status := detour.find_nearest_poly(&nav_context.nav_mesh_query, position, half_extents, &nav_context.query_filter, &poly_ref, &nearest_pos)
    return nav_recast.status_succeeded(status) && poly_ref != nav_recast.INVALID_POLY_REF
}

// Spawn navigation agent at position
spawn_nav_agent_at :: proc(engine: ^Engine, position: [3]f32, radius: f32 = 0.5, height: f32 = 2.0) -> (Handle, ^Node) {
    attachment := NavMeshAgentAttachment{
        target_position = position,
        agent_radius = radius,
        agent_height = height,
        max_speed = 5.0,
        max_acceleration = 10.0,
        arrival_distance = 0.1,
        auto_update_path = true,
        pathfinding_enabled = true,
    }
    return spawn_at(&engine.scene, position, attachment)
}

// Set navigation agent target
nav_agent_set_target :: proc(engine: ^Engine, agent_handle: Handle, target: [3]f32, context_handle: Handle = {}) -> bool {
    node := resource.get(engine.scene.nodes, agent_handle)
    if node == nil {
        return false
    }
    
    agent, ok := &node.attachment.(NavMeshAgentAttachment)
    if !ok {
        return false
    }
    
    agent.target_position = target
    
    // Find path if pathfinding is enabled
    if agent.pathfinding_enabled {
        // Use provided context or default
        nav_context_handle := context_handle
        if nav_context_handle == {} {
            nav_context_handle = engine.warehouse.navigation_system.default_context_handle
        }
        
        current_pos := node.transform.position
        path, success := nav_find_path(engine, nav_context_handle, current_pos, target)
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