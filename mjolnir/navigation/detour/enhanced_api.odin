package navigation_detour

import "core:math/linalg"
import "core:log"
import "core:fmt"
import "core:time"
import nav_recast "../recast"

// ========================================
// ENHANCED DETOUR API WITH STANDARDIZED ERROR HANDLING
// ========================================

// Enhanced navigation context with detailed error tracking
Enhanced_Nav_Context :: struct {
    nav_mesh:         ^Dt_Nav_Mesh,
    query:            Dt_Nav_Mesh_Query,
    filter:           Dt_Query_Filter,
    
    // Error tracking
    last_error:       nav_recast.Nav_Error,
    warnings:         [dynamic]nav_recast.Nav_Error,
    
    // Configuration
    default_extents:  [3]f32,
    max_nodes:        i32,
    
    // Performance metrics
    query_count:      u64,
    total_query_time: f64,
}

// Enhanced pathfinding result
Path_Result :: struct {
    waypoints:        [][3]f32,
    polygon_refs:     []nav_recast.Poly_Ref,
    path_length:      f32,
    is_partial:       bool,
    error:            nav_recast.Nav_Error,
    success:          bool,
}

// Navigation configuration
Nav_Config :: struct {
    max_nodes:        i32,
    default_extents:  [3]f32,
    max_path_length:  i32,
    enable_metrics:   bool,
}

// Default navigation configuration
DEFAULT_NAV_CONFIG :: Nav_Config{
    max_nodes = 512,
    default_extents = {2.0, 1.0, 2.0},
    max_path_length = 256,
    enable_metrics = true,
}

// ========================================
// CONTEXT MANAGEMENT
// ========================================

// Initialize enhanced navigation context
nav_init_enhanced :: proc(ctx: ^Enhanced_Nav_Context, pmesh: ^nav_recast.Rc_Poly_Mesh, 
                         dmesh: ^nav_recast.Rc_Poly_Mesh_Detail, 
                         config: Nav_Config = DEFAULT_NAV_CONFIG) -> nav_recast.Nav_Result(bool) {
    
    // Parameter validation
    if result := nav_recast.nav_require_non_nil(ctx, "ctx"); nav_recast.nav_is_error(result) {
        return result
    }
    if result := nav_recast.nav_require_non_nil(pmesh, "pmesh"); nav_recast.nav_is_error(result) {
        return result
    }
    if result := nav_recast.nav_require_non_nil(dmesh, "dmesh"); nav_recast.nav_is_error(result) {
        return result
    }
    if result := nav_recast.nav_require_positive(config.max_nodes, "max_nodes"); nav_recast.nav_is_error(result) {
        return result
    }
    
    // Initialize context
    ctx.warnings = make([dynamic]nav_recast.Nav_Error)
    ctx.default_extents = config.default_extents
    ctx.max_nodes = config.max_nodes
    
    // Create navigation mesh parameters
    params := Dt_Create_Nav_Mesh_Data_Params{
        poly_mesh = pmesh,
        poly_mesh_detail = dmesh,
        off_mesh_con_count = 0,
        user_id = 1,
        tile_x = 0,
        tile_y = 0,
        tile_layer = 0,
        walkable_height = 2.0,
        walkable_radius = 0.6,
        walkable_climb = 0.9,
    }
    
    // Create navigation mesh data
    nav_data, data_status := dt_create_nav_mesh_data(&params)
    if nav_recast.status_failed(data_status) {
        status_result := nav_recast.nav_from_status(data_status)
        return nav_recast.nav_error_chain(bool, nav_recast.Nav_Error_Category.Algorithm_Failed,
                                       "Failed to create navigation mesh data", status_result.error)
    }
    defer delete(nav_data)
    
    // Create navigation mesh
    ctx.nav_mesh = new(Dt_Nav_Mesh)
    
    mesh_params := Dt_Nav_Mesh_Params{
        orig = pmesh.bmin,
        tile_width = pmesh.bmax[0] - pmesh.bmin[0],
        tile_height = pmesh.bmax[2] - pmesh.bmin[2],
        max_tiles = 1,
        max_polys = 1024,
    }
    
    init_status := dt_nav_mesh_init(ctx.nav_mesh, &mesh_params)
    if nav_recast.status_failed(init_status) {
        free(ctx.nav_mesh)
        ctx.nav_mesh = nil
        status_result := nav_recast.nav_from_status(init_status)
        return nav_recast.nav_error_chain(bool, nav_recast.Nav_Error_Category.Algorithm_Failed,
                                       "Failed to initialize navigation mesh", status_result.error)
    }
    
    // Add tile
    _, add_status := dt_nav_mesh_add_tile(ctx.nav_mesh, nav_data, nav_recast.DT_TILE_FREE_DATA)
    if nav_recast.status_failed(add_status) {
        dt_nav_mesh_destroy(ctx.nav_mesh)
        free(ctx.nav_mesh)
        ctx.nav_mesh = nil
        status_result := nav_recast.nav_from_status(add_status)
        return nav_recast.nav_error_chain(bool, nav_recast.Nav_Error_Category.Algorithm_Failed,
                                       "Failed to add navigation mesh tile", status_result.error)
    }
    
    // Initialize query
    query_status := dt_nav_mesh_query_init(&ctx.query, ctx.nav_mesh, config.max_nodes)
    if nav_recast.status_failed(query_status) {
        dt_nav_mesh_destroy(ctx.nav_mesh)
        free(ctx.nav_mesh)
        ctx.nav_mesh = nil
        status_result := nav_recast.nav_from_status(query_status)
        return nav_recast.nav_error_chain(bool, nav_recast.Nav_Error_Category.Algorithm_Failed,
                                       "Failed to initialize pathfinding query", status_result.error)
    }
    
    // Initialize default filter
    dt_query_filter_init(&ctx.filter)
    
    log.infof("Enhanced navigation context initialized successfully")
    return nav_recast.nav_success()
}

// Clean up enhanced navigation context
nav_destroy_enhanced :: proc(ctx: ^Enhanced_Nav_Context) {
    if ctx == nil do return
    
    if ctx.nav_mesh != nil {
        dt_nav_mesh_query_destroy(&ctx.query)
        dt_nav_mesh_destroy(ctx.nav_mesh)
        free(ctx.nav_mesh)
        ctx.nav_mesh = nil
    }
    
    delete(ctx.warnings)
    
    if ctx.query_count > 0 {
        avg_time := ctx.total_query_time / f64(ctx.query_count)
        log.infof("Navigation context destroyed. Processed %d queries (avg: %.2fms)", 
                  ctx.query_count, avg_time)
    }
}

// ========================================
// PATHFINDING API
// ========================================

// Find path with comprehensive error handling
nav_find_path_enhanced :: proc(ctx: ^Enhanced_Nav_Context, start_pos: [3]f32, end_pos: [3]f32,
                              max_waypoints: int = 256, extents: [3]f32 = {}) -> Path_Result {
    
    // Parameter validation
    if ctx == nil {
        return Path_Result{
            error = nav_recast.Nav_Error{
                category = nav_recast.Nav_Error_Category.Invalid_Parameter,
                message = "Navigation context cannot be nil",
                ctx = "nav_find_path_enhanced",
            },
            success = false,
        }
    }
    
    if ctx.nav_mesh == nil {
        return Path_Result{
            error = nav_recast.Nav_Error{
                category = nav_recast.Nav_Error_Category.Internal_Error,
                message = "Navigation mesh not initialized",
                ctx = "nav_find_path_enhanced",
            },
            success = false,
        }
    }
    
    if max_waypoints <= 0 {
        return Path_Result{
            error = nav_recast.Nav_Error{
                category = nav_recast.Nav_Error_Category.Invalid_Parameter,
                message = fmt.tprintf("max_waypoints (%d) must be positive", max_waypoints),
                ctx = "nav_find_path_enhanced",
            },
            success = false,
        }
    }
    
    // Use provided extents or default
    search_extents := extents
    if search_extents == {} {
        search_extents = ctx.default_extents
    }
    
    // Performance tracking
    start_time := time.now() if ctx.query_count > 0 else time.Time{}
    defer {
        if ctx.query_count > 0 {
            query_time := time.duration_milliseconds(time.since(start_time))
            ctx.total_query_time += query_time
        }
        ctx.query_count += 1
    }
    
    // Find start polygon
    start_ref := nav_recast.Poly_Ref(0)
    start_nearest := [3]f32{}
    start_status := dt_find_nearest_poly(&ctx.query, start_pos, search_extents, &ctx.filter, &start_ref, &start_nearest)
    
    if nav_recast.status_failed(start_status) {
        return Path_Result{
            error = nav_recast.Nav_Error{
                category = nav_recast.Nav_Error_Category.Algorithm_Failed,
                message = fmt.tprintf("Could not find start polygon near position (%.2f, %.2f, %.2f)", 
                                    start_pos.x, start_pos.y, start_pos.z),
                ctx = "nav_find_path_enhanced",
            },
            success = false,
        }
    }
    
    // Find end polygon
    end_ref := nav_recast.Poly_Ref(0)
    end_nearest := [3]f32{}
    end_status := dt_find_nearest_poly(&ctx.query, end_pos, search_extents, &ctx.filter, &end_ref, &end_nearest)
    
    if nav_recast.status_failed(end_status) {
        return Path_Result{
            error = nav_recast.Nav_Error{
                category = nav_recast.Nav_Error_Category.Algorithm_Failed,
                message = fmt.tprintf("Could not find end polygon near position (%.2f, %.2f, %.2f)", 
                                    end_pos.x, end_pos.y, end_pos.z),
                ctx = "nav_find_path_enhanced",
            },
            success = false,
        }
    }
    
    // Check if start and end are the same polygon (trivial path)
    if start_ref == end_ref {
        return Path_Result{
            waypoints = {start_nearest, end_nearest},
            polygon_refs = {start_ref},
            path_length = linalg.distance(start_nearest, end_nearest),
            is_partial = false,
            success = true,
        }
    }
    
    // Find polygon path
    path_refs := make([]nav_recast.Poly_Ref, max_waypoints)
    defer delete(path_refs)
    
    path_count := i32(0)
    path_status := dt_find_path(&ctx.query, start_ref, end_ref, start_nearest, end_nearest,
                               &ctx.filter, path_refs, &path_count, i32(max_waypoints))
    
    if nav_recast.status_failed(path_status) {
        return Path_Result{
            error = nav_recast.Nav_Error{
                category = nav_recast.Nav_Error_Category.Algorithm_Failed,
                message = "Pathfinding algorithm failed",
                ctx = "nav_find_path_enhanced",
            },
            success = false,
        }
    }
    
    if path_count == 0 {
        return Path_Result{
            error = nav_recast.Nav_Error{
                category = nav_recast.Nav_Error_Category.Algorithm_Failed,
                message = "No path found between start and end positions",
                ctx = "nav_find_path_enhanced",
            },
            success = false,
        }
    }
    
    // Generate straight path
    straight_path := make([]Dt_Straight_Path_Point, max_waypoints)
    defer delete(straight_path)
    
    straight_path_flags := make([]u8, max_waypoints)
    defer delete(straight_path_flags)
    
    straight_path_refs := make([]nav_recast.Poly_Ref, max_waypoints)
    defer delete(straight_path_refs)
    
    straight_path_count := i32(0)
    straight_status := dt_find_straight_path(&ctx.query, start_nearest, end_nearest,
                                           path_refs[:path_count], path_count,
                                           straight_path, straight_path_flags, straight_path_refs,
                                           &straight_path_count, i32(max_waypoints), 0)
    
    if nav_recast.status_failed(straight_status) && !nav_recast.status_in_progress(straight_status) {
        return Path_Result{
            error = nav_recast.Nav_Error{
                category = nav_recast.Nav_Error_Category.Algorithm_Failed,
                message = "Failed to generate straight path",
                ctx = "nav_find_path_enhanced", 
            },
            success = false,
        }
    }
    
    // Convert to waypoint array
    waypoints := make([][3]f32, straight_path_count)
    refs := make([]nav_recast.Poly_Ref, straight_path_count)
    total_length := f32(0)
    
    for i in 0..<straight_path_count {
        waypoints[i] = straight_path[i].pos
        refs[i] = straight_path_refs[i]
        
        if i > 0 {
            total_length += linalg.distance(waypoints[i-1], waypoints[i])
        }
    }
    
    // Check if path is partial
    is_partial := nav_recast.Status_Flag.Partial_Result in path_status || 
                  nav_recast.Status_Flag.Partial_Path in path_status
    
    if is_partial {
        warning := nav_recast.Nav_Error{
            category = nav_recast.Nav_Error_Category.None,
            message = "Generated path is partial - could not reach exact destination",
            ctx = "nav_find_path_enhanced",
        }
        append(&ctx.warnings, warning)
    }
    
    return Path_Result{
        waypoints = waypoints,
        polygon_refs = refs,
        path_length = total_length,
        is_partial = is_partial,
        success = true,
    }
}

// ========================================
// UTILITY FUNCTIONS
// ========================================

// Check if a position is valid for navigation
nav_is_position_valid_enhanced :: proc(ctx: ^Enhanced_Nav_Context, pos: [3]f32, 
                                     extents: [3]f32 = {}) -> nav_recast.Nav_Result(bool) {
    if ctx == nil {
        return nav_recast.nav_error_here(bool, nav_recast.Nav_Error_Category.Invalid_Parameter, 
                                      "Navigation context cannot be nil")
    }
    
    if ctx.nav_mesh == nil {
        return nav_recast.nav_error_here(bool, nav_recast.Nav_Error_Category.Internal_Error,
                                      "Navigation mesh not initialized")
    }
    
    search_extents := extents
    if search_extents == {} {
        search_extents = ctx.default_extents
    }
    
    poly_ref := nav_recast.Poly_Ref(0)
    nearest_pt := [3]f32{}
    status := dt_find_nearest_poly(&ctx.query, pos, search_extents, &ctx.filter, &poly_ref, &nearest_pt)
    
    if nav_recast.status_failed(status) {
        return nav_recast.nav_error_here(bool, nav_recast.Nav_Error_Category.Algorithm_Failed,
                                      "Failed to query navigation mesh")
    }
    
    return nav_recast.nav_ok(bool, poly_ref != nav_recast.INVALID_POLY_REF)
}

// Get distance to nearest walkable surface
nav_get_distance_to_walkable :: proc(ctx: ^Enhanced_Nav_Context, pos: [3]f32,
                                    extents: [3]f32 = {}) -> nav_recast.Nav_Result(f32) {
    if ctx == nil {
        return nav_recast.nav_error_here(f32, nav_recast.Nav_Error_Category.Invalid_Parameter,
                                      "Navigation context cannot be nil")
    }
    
    if ctx.nav_mesh == nil {
        return nav_recast.nav_error_here(f32, nav_recast.Nav_Error_Category.Internal_Error,
                                      "Navigation mesh not initialized")
    }
    
    search_extents := extents
    if search_extents == {} {
        search_extents = ctx.default_extents
    }
    
    poly_ref := nav_recast.Poly_Ref(0)
    nearest_pt := [3]f32{}
    status := dt_find_nearest_poly(&ctx.query, pos, search_extents, &ctx.filter, &poly_ref, &nearest_pt)
    
    if nav_recast.status_failed(status) {
        return nav_recast.nav_error_here(f32, nav_recast.Nav_Error_Category.Algorithm_Failed,
                                      "Failed to query navigation mesh")
    }
    
    if poly_ref == nav_recast.INVALID_POLY_REF {
        return nav_recast.nav_error_here(f32, nav_recast.Nav_Error_Category.Algorithm_Failed,
                                      "No walkable surface found within search radius")
    }
    
    distance := linalg.distance(pos, nearest_pt)
    return nav_recast.nav_ok(f32, distance)
}

// Get navigation context statistics
nav_get_stats :: proc(ctx: ^Enhanced_Nav_Context) -> Nav_Stats {
    if ctx == nil {
        return {}
    }
    
    avg_query_time := f64(0)
    if ctx.query_count > 0 {
        avg_query_time = ctx.total_query_time / f64(ctx.query_count)
    }
    
    return Nav_Stats{
        query_count = ctx.query_count,
        total_query_time_ms = ctx.total_query_time,
        average_query_time_ms = avg_query_time,
        warning_count = u32(len(ctx.warnings)),
    }
}

// Navigation statistics
Nav_Stats :: struct {
    query_count:           u64,
    total_query_time_ms:   f64,
    average_query_time_ms: f64,
    warning_count:         u32,
}

// Free path result resources
nav_free_path_result :: proc(result: ^Path_Result) {
    delete(result.waypoints)
    delete(result.polygon_refs)
    result.waypoints = nil
    result.polygon_refs = nil
}