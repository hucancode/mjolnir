package navigation_detour

import "core:log"
import "core:fmt"
import "core:slice"
import "core:time"
import "core:math"
import "core:math/linalg"
import "../recast"

// Create navigation mesh from Recast polygon mesh
create_navmesh :: proc(pmesh: ^recast.Poly_Mesh, dmesh: ^recast.Poly_Mesh_Detail, walkable_height: f32, walkable_radius: f32, walkable_climb: f32) -> (nav_mesh: ^Nav_Mesh, ok: bool) {
    // Create navigation mesh data
    params := Create_Nav_Mesh_Data_Params{
        poly_mesh = pmesh,
        poly_mesh_detail = dmesh,
        off_mesh_con_count = 0,
        user_id = 1,
        tile_x = 0,
        tile_y = 0,
        tile_layer = 0,
        walkable_height = walkable_height,
        walkable_radius = walkable_radius,
        walkable_climb = walkable_climb,
    }

    nav_data, data_status := create_nav_mesh_data(&params)
    if recast.status_failed(data_status) {
        return nil, false
    }
    // Don't delete nav_data here - DT_TILE_FREE_DATA flag means Detour will manage it

    // Create navigation mesh
    nav_mesh = new(Nav_Mesh)

    mesh_params := Nav_Mesh_Params{
        orig = pmesh.bmin,
        tile_width = (pmesh.bmax - pmesh.bmin).x,
        tile_height = (pmesh.bmax - pmesh.bmin).z,
        max_tiles = 1,
        max_polys = 1024,
    }

    init_status := nav_mesh_init(nav_mesh, &mesh_params)
    if recast.status_failed(init_status) {
        free(nav_mesh)
        return nil, false
    }

    // Add tile
    _, add_status := nav_mesh_add_tile(nav_mesh, nav_data, recast.DT_TILE_FREE_DATA)
    if recast.status_failed(add_status) {
        nav_mesh_destroy(nav_mesh)
        free(nav_mesh)
        return nil, false
    }

    return nav_mesh, true
}

// Find path between two points
find_path_points :: proc(query: ^Nav_Mesh_Query, start_pos: [3]f32, end_pos: [3]f32, filter: ^Query_Filter, path: [][3]f32) -> (path_count: int, status: recast.Status) {
    log.infof("=== find_path_points called: start=%v, end=%v, path_buffer_len=%d", start_pos, end_pos, len(path))
    half_extents := [3]f32{5.0, 5.0, 5.0}  // Use larger search radius to ensure we find polygons

    // Find start polygon
    start_status, start_ref, start_nearest := find_nearest_poly(query, start_pos, half_extents, filter)
    log.infof("find_path_points: find_nearest_poly for start returned status=%v, ref=0x%x, nearest=%v", start_status, start_ref, start_nearest)
    if recast.status_failed(start_status) || start_ref == recast.INVALID_POLY_REF {
        log.errorf("find_path_points: Failed to find start polygon, returning early")
        return 0, start_status
    }

    // Find end polygon
    end_status, end_ref, end_nearest := find_nearest_poly(query, end_pos, half_extents, filter)
    log.infof("find_path_points: find_nearest_poly for end returned status=%v, ref=0x%x, nearest=%v", end_status, end_ref, end_nearest)
    if recast.status_failed(end_status) || end_ref == recast.INVALID_POLY_REF {
        log.errorf("find_path_points: Failed to find end polygon, returning early")
        return 0, end_status
    }

    // Find polygon path
    poly_path := make([]recast.Poly_Ref, len(path))
    defer delete(poly_path)

    path_status, poly_path_count := find_path(query, start_ref, end_ref, start_nearest, end_nearest, filter, poly_path, i32(len(path)))
    log.infof("find_path_points: find_path returned status=%v, poly_path_count=%d", path_status, poly_path_count)
    if recast.status_failed(path_status) || poly_path_count == 0 {
        log.errorf("find_path_points: Failed to find polygon path or path empty, returning early")
        return 0, path_status
    }

    // Convert to straight path
    straight_path := make([]Straight_Path_Point, len(path))
    defer delete(straight_path)

    straight_path_flags := make([]u8, len(path))
    defer delete(straight_path_flags)

    straight_path_refs := make([]recast.Poly_Ref, len(path))
    defer delete(straight_path_refs)

    // Special case: if path has only 1 polygon, just return start and end points
    log.infof("find_path_points: poly_path_count = %d", poly_path_count)
    if poly_path_count == 1 {
        log.info("find_path_points: Single polygon path - returning direct line")
        path[0] = start_nearest
        if linalg.length2(end_nearest - start_nearest) > 0.0001 {  // Not the same point
            path[1] = end_nearest
            log.infof("Returning 2 points: start=%v, end=%v", start_nearest, end_nearest)
            return 2, {.Success}
        }
        log.info("Start and end are same point, returning 1")
        return 1, {.Success}
    }

    log.infof("find_path_points: About to call find_straight_path with %d polygons", poly_path_count)
    log.infof("  poly_path_count=%d, len(poly_path)=%d", poly_path_count, len(poly_path))
    log.infof("  len(straight_path)=%d, max=%d", len(straight_path), len(path))
    log.infof("  start_nearest=%v, end_nearest=%v", start_nearest, end_nearest)

    // Log the polygon path
    for i in 0..<poly_path_count {
        log.infof("  poly_path[%d] = 0x%x", i, poly_path[i])
    }

    straight_status, straight_path_count := find_straight_path(query, start_nearest, end_nearest, poly_path[:poly_path_count], poly_path_count,
                                                                straight_path, straight_path_flags, straight_path_refs,
                                                                i32(len(path)), u32(Straight_Path_Options.All_Crossings))
    log.infof("find_path_points: find_straight_path returned status=%v, count=%d", straight_status, straight_path_count)
    if recast.status_failed(straight_status) {
        log.errorf("find_path_points: find_straight_path failed with status %v", straight_status)
        return 0, straight_status
    }

    // Extract positions and filter duplicates
    path_count = 0
    last_pos := [3]f32{math.F32_MAX, math.F32_MAX, math.F32_MAX}

    for i in 0..<int(straight_path_count) {
        pos := straight_path[i].pos
        // Skip duplicate consecutive points
        if linalg.length2(pos - last_pos) > 0.0001 { // 0.01 unit threshold squared
            path[path_count] = pos
            path_count += 1
            last_pos = pos
        }
    }

    return path_count, {.Success}
}

// Detour navigation mesh polygon
Poly :: struct {
    first_link:   u32,                                    // Index to first link in linked list (DT_NULL_LINK if no link)
    verts:        [recast.DT_VERTS_PER_POLYGON]u16,     // Indices of polygon vertices
    neis:         [recast.DT_VERTS_PER_POLYGON]u16,     // Neighbor data for each edge
    flags:        u16,                                    // User defined polygon flags
    vert_count:   u8,                                     // Number of vertices in polygon
    area_and_type: u8,                                   // Packed area id and polygon type
}

// Polygon area and type helpers
poly_set_area :: proc(poly: ^Poly, area: u8) {
    poly.area_and_type = (poly.area_and_type & 0xc0) | (area & 0x3f)
}

poly_set_type :: proc(poly: ^Poly, type: u8) {
    poly.area_and_type = (poly.area_and_type & 0x3f) | (type << 6)
}

poly_get_area :: proc(poly: ^Poly) -> u8 {
    return poly.area_and_type & 0x3f
}

poly_get_type :: proc(poly: ^Poly) -> u8 {
    return poly.area_and_type >> 6
}

// Detail polygon mesh data
Poly_Detail :: struct {
    vert_base:  u32,  // Offset of vertices in detail vertex array
    tri_base:   u32,  // Offset of triangles in detail triangle array
    vert_count: u8,   // Number of vertices in sub-mesh
    tri_count:  u8,   // Number of triangles in sub-mesh
}

// Link between polygons
Link :: struct {
    ref:   recast.Poly_Ref,  // Neighbor reference (linked polygon)
    next:  u32,                // Index of next link
    edge:  u8,                 // Index of polygon edge that owns this link
    side:  u8,                 // If boundary link, defines which side
    bmin:  u8,                 // If boundary link, minimum sub-edge area
    bmax:  u8,                 // If boundary link, maximum sub-edge area
}

// Bounding volume node for spatial queries
BV_Node :: struct {
    bmin: [3]u16,  // Minimum bounds of AABB
    bmax: [3]u16,  // Maximum bounds of AABB
    i:    i32,     // Node index (negative for escape sequence)
}

// Off-mesh connection
Off_Mesh_Connection :: struct {
    start:   [3]f32,  // Start position
    end:     [3]f32,  // End position
    rad:     f32,     // Radius of endpoints
    poly:    u16,     // Polygon reference within tile
    flags:   u8,      // Link flags (internal use)
    side:    u8,      // End point side
    user_id: u32,     // User assigned ID
}

// Mesh header containing tile metadata
Mesh_Header :: struct {
    magic:               i32,    // Tile magic number
    version:             i32,    // Data format version
    x:                   i32,    // Tile x-position in grid
    y:                   i32,    // Tile y-position in grid
    layer:               i32,    // Tile layer in grid
    user_id:             u32,    // User defined tile ID
    poly_count:          i32,    // Number of polygons
    vert_count:          i32,    // Number of vertices
    max_link_count:      i32,    // Number of allocated links
    detail_mesh_count:   i32,    // Number of detail sub-meshes
    detail_vert_count:   i32,    // Number of unique detail vertices
    detail_tri_count:    i32,    // Number of detail triangles
    bv_node_count:       i32,    // Number of bounding volume nodes
    off_mesh_con_count:  i32,    // Number of off-mesh connections
    off_mesh_base:       i32,    // Index of first off-mesh polygon
    walkable_height:     f32,    // Agent height
    walkable_radius:     f32,    // Agent radius
    walkable_climb:      f32,    // Agent max climb
    bmin:                [3]f32, // Tile minimum bounds
    bmax:                [3]f32, // Tile maximum bounds
    bv_quant_factor:     f32,    // Bounding volume quantization factor
}

// Navigation mesh tile
Mesh_Tile :: struct {
    salt:              u32,                       // Counter for modifications to tile
    links_free_list:   u32,                       // Index to next free link
    header:            ^Mesh_Header,           // Tile header
    polys:             []Poly,                 // Tile polygons
    verts:             [][3]f32,                  // Tile vertices
    links:             []Link,                 // Tile links
    detail_meshes:     []Poly_Detail,          // Detail sub-meshes
    detail_verts:      [][3]f32,                  // Detail vertices
    detail_tris:       [][4]u8,                   // Detail triangles [vertA, vertB, vertC, flags]
    bv_tree:           []BV_Node,              // Bounding volume tree
    off_mesh_cons:     []Off_Mesh_Connection,  // Off-mesh connections
    data:              []u8,                      // Raw tile data
    flags:             i32,                       // Tile flags
    next:              ^Mesh_Tile,             // Next tile in spatial grid or free list
}

// Navigation mesh parameters
Nav_Mesh_Params :: struct {
    orig:        [3]f32,  // World space origin of tile space
    tile_width:  f32,     // Width of each tile
    tile_height: f32,     // Height of each tile
    max_tiles:   i32,     // Maximum number of tiles
    max_polys:   i32,     // Maximum polygons per tile
}

// Navigation mesh
Nav_Mesh :: struct {
    params:         Nav_Mesh_Params,   // Initialization parameters
    orig:           [3]f32,               // Origin of tile (0,0)
    tile_width:     f32,                  // Tile dimensions
    tile_height:    f32,
    max_tiles:      i32,                  // Maximum number of tiles
    tile_lut_size:  i32,                  // Tile hash lookup size (power of 2)
    tile_lut_mask:  i32,                  // Tile hash lookup mask
    pos_lookup:     []^Mesh_Tile,      // Tile hash lookup
    next_free:      ^Mesh_Tile,        // Free tile list
    tiles:          []Mesh_Tile,       // All tiles

    // Reference encoding parameters
    salt_bits:      u32,                  // Number of salt bits
    tile_bits:      u32,                  // Number of tile bits
    poly_bits:      u32,                  // Number of polygon bits
}

// Query filter for pathfinding constraints
Query_Filter :: struct {
    area_cost:     [recast.DT_MAX_AREAS]f32,  // Cost per area type
    include_flags: u16,                         // Flags for traversable polygons
    exclude_flags: u16,                         // Flags for non-traversable polygons
}

// Raycast hit information
Raycast_Hit :: struct {
    t:              f32,                           // Hit parameter (FLT_MAX if no hit)
    hit_normal:     [3]f32,                        // Normal of nearest wall hit
    hit_edge_index: i32,                           // Edge index on final polygon
    path:           []recast.Poly_Ref,           // Array of visited polygon refs
    path_count:     i32,                           // Number of visited polygons
    path_cost:      f32,                           // Cost of path until hit
}

// Straight path point
Straight_Path_Point :: struct {
    pos:   [3]f32,             // Point position
    flags: u8,                 // Point flags (start, end, off-mesh)
    ref:   recast.Poly_Ref,  // Polygon reference
}

// Straight path flags
Straight_Path_Flags :: enum u8 {
    Start                = 0x01,
    End                  = 0x02,
    Off_Mesh_Connection  = 0x04,
}

// Find path options
Find_Path_Options :: enum u8 {
    Any_Angle = 0x02,
}

// Raycast options
Raycast_Options :: enum u8 {
    Use_Costs = 0x01,
}

// Straight path options
Straight_Path_Options :: enum u8 {
    Area_Crossings = 0x01,
    All_Crossings  = 0x02,
}

// Polygon query interface
Poly_Query :: struct {
    process: proc(ref: recast.Poly_Ref, tile: ^Mesh_Tile, poly: ^Poly, user_data: rawptr),
    user_data: rawptr,
}

// Default query filter implementation
query_filter_init :: proc(filter: ^Query_Filter) {
    filter.include_flags = 0xffff
    filter.exclude_flags = 0
    slice.fill(filter.area_cost[:], 1.0)
}

query_filter_pass_filter :: proc(filter: ^Query_Filter, ref: recast.Poly_Ref, tile: ^Mesh_Tile, poly: ^Poly) -> bool {
    return (poly.flags & filter.include_flags) != 0 && (poly.flags & filter.exclude_flags) == 0
}

query_filter_get_cost :: proc(filter: ^Query_Filter,
                                pa, pb: [3]f32,
                                prev_ref: recast.Poly_Ref, prev_tile: ^Mesh_Tile, prev_poly: ^Poly,
                                cur_ref: recast.Poly_Ref, cur_tile: ^Mesh_Tile, cur_poly: ^Poly,
                                next_ref: recast.Poly_Ref, next_tile: ^Mesh_Tile, next_poly: ^Poly) -> f32 {
    // Base cost is distance
    diff := pb - pa
    cost := linalg.length(diff)

    // Apply area-specific multiplier
    area := poly_get_area(cur_poly)
    if area < recast.DT_MAX_AREAS {
        cost *= filter.area_cost[area]
    }

    return cost
}

// Reference encoding/decoding helpers
encode_poly_id :: proc(nav_mesh: ^Nav_Mesh, salt: u32, tile_index: u32, poly_index: u32) -> recast.Poly_Ref {
    return recast.Poly_Ref((salt << (nav_mesh.poly_bits + nav_mesh.tile_bits)) |
                            (tile_index << nav_mesh.poly_bits) |
                            poly_index)
}

decode_poly_id :: proc(nav_mesh: ^Nav_Mesh, ref: recast.Poly_Ref) -> (salt: u32, tile_index: u32, poly_index: u32) {
    if nav_mesh == nil {
        return 0, 0, 0
    }

    salt_mask := (u32(1) << nav_mesh.salt_bits) - 1
    tile_mask := (u32(1) << nav_mesh.tile_bits) - 1
    poly_mask := (u32(1) << nav_mesh.poly_bits) - 1

    salt = (u32(ref) >> (nav_mesh.poly_bits + nav_mesh.tile_bits)) & salt_mask
    tile_index = (u32(ref) >> nav_mesh.poly_bits) & tile_mask
    poly_index = u32(ref) & poly_mask

    return
}

// Helper to just get the polygon index from a reference
get_poly_index :: proc(nav_mesh: ^Nav_Mesh, ref: recast.Poly_Ref) -> u32 {
    if nav_mesh == nil {
        return 0
    }
    poly_mask := (u32(1) << nav_mesh.poly_bits) - 1
    return u32(ref) & poly_mask
}

// Calculate tile location from world position with robust error handling
calc_tile_loc :: proc(nav_mesh: ^Nav_Mesh, pos: [3]f32) -> (tx: i32, ty: i32, status: recast.Status) {
    // Input validation
    if nav_mesh == nil {
        return 0, 0, {.Invalid_Param}
    }

    // Check for invalid tile dimensions (zero, negative, or extremely small values)
    if nav_mesh.tile_width <= 0 || nav_mesh.tile_height <= 0 {
        return 0, 0, {.Invalid_Param}
    }

    // Check for extremely small tile dimensions that could cause precision issues
    MIN_TILE_DIMENSION :: 1e-6
    if nav_mesh.tile_width < MIN_TILE_DIMENSION || nav_mesh.tile_height < MIN_TILE_DIMENSION {
        return 0, 0, {.Invalid_Param}
    }

    // Check for infinite or NaN position values
    for i in 0..<3 {
        // Check for NaN: NaN != NaN is always true
        if pos[i] != pos[i] {
            return 0, 0, {.Invalid_Param}
        }
        // Check for infinity
        if pos[i] == math.F32_MAX || pos[i] == -math.F32_MAX {
            return 0, 0, {.Invalid_Param}
        }
        // Additional check for extremely large values that could cause overflow
        // Use a reasonable limit that's much larger than typical world coordinates
        MAX_REASONABLE_WORLD_COORD :: 1e10
        if math.abs(pos[i]) > MAX_REASONABLE_WORLD_COORD {
            return 0, 0, {.Invalid_Param}
        }
    }

    // Calculate offset from origin
    offset := pos - nav_mesh.orig
    // Check for infinite or NaN offset values (could happen if origin is invalid)
    if offset.x != offset.x || offset.z != offset.z ||  // NaN check
       offset.x == math.F32_MAX || offset.x == -math.F32_MAX ||  // Infinity check
       offset.z == math.F32_MAX || offset.z == -math.F32_MAX ||
       math.abs(offset.x) > 1e20 || math.abs(offset.z) > 1e20 {  // Extremely large values
        return 0, 0, {.Invalid_Param}
    }

    // Calculate floating-point tile coordinates
    tile_f_x := offset.x / nav_mesh.tile_width
    tile_f_z := offset.z / nav_mesh.tile_height

    // Check for overflow - ensure coordinates won't overflow i32
    // Use conservative bounds to account for negative values
    MAX_SAFE_TILE_COORD :: f32(0x7FFF_FF00) // Leave some headroom before i32 max
    MIN_SAFE_TILE_COORD :: f32(-0x7FFF_FF00)

    if tile_f_x > MAX_SAFE_TILE_COORD || tile_f_x < MIN_SAFE_TILE_COORD ||
       tile_f_z > MAX_SAFE_TILE_COORD || tile_f_z < MIN_SAFE_TILE_COORD {
        return 0, 0, {.Invalid_Param}
    }

    // Handle negative coordinates properly - floor division for correct tile assignment
    // For negative coordinates, we want floor behavior, not truncation toward zero
    tx = i32(math.floor(tile_f_x))
    ty = i32(math.floor(tile_f_z))

    // Additional bounds checking - ensure tile coordinates are reasonable for the system
    // This prevents accessing extremely large tile indices that could cause memory issues
    MAX_REASONABLE_TILE_INDEX :: i32(1_000_000) // 1 million tiles in each direction
    if tx < -MAX_REASONABLE_TILE_INDEX || tx > MAX_REASONABLE_TILE_INDEX ||
       ty < -MAX_REASONABLE_TILE_INDEX || ty > MAX_REASONABLE_TILE_INDEX {
        return 0, 0, {.Invalid_Param}
    }

    return tx, ty, {.Success}
}

// Calculate tile location from world position (simple version)
// Returns (0, 0) for invalid inputs - use calc_tile_loc for full error handling
calc_tile_loc_simple :: proc(nav_mesh: ^Nav_Mesh, pos: [3]f32) -> (tx: i32, ty: i32) {
    result_tx, result_ty, status := calc_tile_loc(nav_mesh, pos)
    if recast.status_failed(status) {
        return 0, 0
    }
    return result_tx, result_ty
}

// Get detail triangle edge flags
get_detail_tri_edge_flags :: proc(tri_flags: u8, edge_index: i32) -> i32 {
    return i32((tri_flags >> (u8(edge_index) * 2)) & 0x3)
}

// ========================================
// ENHANCED DETOUR API WITH STANDARDIZED ERROR HANDLING
// ========================================

// Enhanced navigation context with detailed error tracking
Enhanced_Nav_Context :: struct {
    nav_mesh:         ^Nav_Mesh,
    query:            Nav_Mesh_Query,
    filter:           Query_Filter,

    // Error tracking
    last_error:       recast.Nav_Error,
    warnings:         [dynamic]recast.Nav_Error,

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
    polygon_refs:     []recast.Poly_Ref,
    path_length:      f32,
    is_partial:       bool,
    error:            recast.Nav_Error,
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
nav_init_enhanced :: proc(ctx: ^Enhanced_Nav_Context, pmesh: ^recast.Poly_Mesh,
                         dmesh: ^recast.Poly_Mesh_Detail,
                         config: Nav_Config = DEFAULT_NAV_CONFIG) -> recast.Nav_Result(bool) {

    // Parameter validation
    if result := recast.nav_require_non_nil(ctx, "ctx"); recast.nav_is_error(result) {
        return result
    }
    if result := recast.nav_require_non_nil(pmesh, "pmesh"); recast.nav_is_error(result) {
        return result
    }
    if result := recast.nav_require_non_nil(dmesh, "dmesh"); recast.nav_is_error(result) {
        return result
    }
    if result := recast.nav_require_positive(config.max_nodes, "max_nodes"); recast.nav_is_error(result) {
        return result
    }

    // Initialize context
    ctx.warnings = make([dynamic]recast.Nav_Error)
    ctx.default_extents = config.default_extents
    ctx.max_nodes = config.max_nodes

    // Create navigation mesh parameters
    params := Create_Nav_Mesh_Data_Params{
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
    nav_data, data_status := create_nav_mesh_data(&params)
    if recast.status_failed(data_status) {
        status_result := recast.nav_from_status(data_status)
        return recast.nav_error_chain(bool, recast.Nav_Error_Category.Algorithm_Failed,
                                       "Failed to create navigation mesh data", status_result.error)
    }
    defer delete(nav_data)

    // Create navigation mesh
    ctx.nav_mesh = new(Nav_Mesh)

    mesh_params := Nav_Mesh_Params{
        orig = pmesh.bmin,
        tile_width = (pmesh.bmax - pmesh.bmin).x,
        tile_height = (pmesh.bmax - pmesh.bmin).z,
        max_tiles = 1,
        max_polys = 1024,
    }

    init_status := nav_mesh_init(ctx.nav_mesh, &mesh_params)
    if recast.status_failed(init_status) {
        free(ctx.nav_mesh)
        ctx.nav_mesh = nil
        status_result := recast.nav_from_status(init_status)
        return recast.nav_error_chain(bool, recast.Nav_Error_Category.Algorithm_Failed,
                                       "Failed to initialize navigation mesh", status_result.error)
    }

    // Add tile
    _, add_status := nav_mesh_add_tile(ctx.nav_mesh, nav_data, recast.DT_TILE_FREE_DATA)
    if recast.status_failed(add_status) {
        nav_mesh_destroy(ctx.nav_mesh)
        free(ctx.nav_mesh)
        ctx.nav_mesh = nil
        status_result := recast.nav_from_status(add_status)
        return recast.nav_error_chain(bool, recast.Nav_Error_Category.Algorithm_Failed,
                                       "Failed to add navigation mesh tile", status_result.error)
    }

    // Initialize query
    query_status := nav_mesh_query_init(&ctx.query, ctx.nav_mesh, config.max_nodes)
    if recast.status_failed(query_status) {
        nav_mesh_destroy(ctx.nav_mesh)
        free(ctx.nav_mesh)
        ctx.nav_mesh = nil
        status_result := recast.nav_from_status(query_status)
        return recast.nav_error_chain(bool, recast.Nav_Error_Category.Algorithm_Failed,
                                       "Failed to initialize pathfinding query", status_result.error)
    }

    // Initialize default filter
    query_filter_init(&ctx.filter)

    log.infof("Enhanced navigation context initialized successfully")
    return recast.nav_success()
}

// Clean up enhanced navigation context
nav_destroy_enhanced :: proc(ctx: ^Enhanced_Nav_Context) {
    if ctx == nil do return

    if ctx.nav_mesh != nil {
        nav_mesh_query_destroy(&ctx.query)
        nav_mesh_destroy(ctx.nav_mesh)
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
            error = recast.Nav_Error{
                category = recast.Nav_Error_Category.Invalid_Parameter,
                message = "Navigation context cannot be nil",
                ctx = "nav_find_path_enhanced",
            },
            success = false,
        }
    }

    if ctx.nav_mesh == nil {
        return Path_Result{
            error = recast.Nav_Error{
                category = recast.Nav_Error_Category.Internal_Error,
                message = "Navigation mesh not initialized",
                ctx = "nav_find_path_enhanced",
            },
            success = false,
        }
    }

    if max_waypoints <= 0 {
        return Path_Result{
            error = recast.Nav_Error{
                category = recast.Nav_Error_Category.Invalid_Parameter,
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
    start_status, start_ref, start_nearest := find_nearest_poly(&ctx.query, start_pos, search_extents, &ctx.filter)

    if recast.status_failed(start_status) {
        return Path_Result{
            error = recast.Nav_Error{
                category = recast.Nav_Error_Category.Algorithm_Failed,
                message = fmt.tprintf("Could not find start polygon near position (%.2f, %.2f, %.2f)",
                                    start_pos.x, start_pos.y, start_pos.z),
                ctx = "nav_find_path_enhanced",
            },
            success = false,
        }
    }

    // Find end polygon
    end_status, end_ref, end_nearest := find_nearest_poly(&ctx.query, end_pos, search_extents, &ctx.filter)

    if recast.status_failed(end_status) {
        return Path_Result{
            error = recast.Nav_Error{
                category = recast.Nav_Error_Category.Algorithm_Failed,
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
    path_refs := make([]recast.Poly_Ref, max_waypoints)
    defer delete(path_refs)

    path_status, path_count := find_path(&ctx.query, start_ref, end_ref, start_nearest, end_nearest,
                                          &ctx.filter, path_refs, i32(max_waypoints))

    if recast.status_failed(path_status) {
        return Path_Result{
            error = recast.Nav_Error{
                category = recast.Nav_Error_Category.Algorithm_Failed,
                message = "Pathfinding algorithm failed",
                ctx = "nav_find_path_enhanced",
            },
            success = false,
        }
    }

    if path_count == 0 {
        return Path_Result{
            error = recast.Nav_Error{
                category = recast.Nav_Error_Category.Algorithm_Failed,
                message = "No path found between start and end positions",
                ctx = "nav_find_path_enhanced",
            },
            success = false,
        }
    }

    // Generate straight path
    straight_path := make([]Straight_Path_Point, max_waypoints)
    defer delete(straight_path)

    straight_path_flags := make([]u8, max_waypoints)
    defer delete(straight_path_flags)

    straight_path_refs := make([]recast.Poly_Ref, max_waypoints)
    defer delete(straight_path_refs)

    straight_status, straight_path_count := find_straight_path(&ctx.query, start_nearest, end_nearest,
                                                                path_refs[:path_count], path_count,
                                                                straight_path, straight_path_flags, straight_path_refs,
                                                                i32(max_waypoints), 0)

    if recast.status_failed(straight_status) && !recast.status_in_progress(straight_status) {
        return Path_Result{
            error = recast.Nav_Error{
                category = recast.Nav_Error_Category.Algorithm_Failed,
                message = "Failed to generate straight path",
                ctx = "nav_find_path_enhanced",
            },
            success = false,
        }
    }

    // Convert to waypoint array
    waypoints := make([][3]f32, straight_path_count)
    refs := make([]recast.Poly_Ref, straight_path_count)
    total_length := f32(0)

    for i in 0..<straight_path_count {
        waypoints[i] = straight_path[i].pos
        refs[i] = straight_path_refs[i]

        if i > 0 {
            total_length += linalg.distance(waypoints[i-1], waypoints[i])
        }
    }

    // Check if path is partial
    is_partial := recast.Status_Flag.Partial_Result in path_status ||
                  recast.Status_Flag.Partial_Path in path_status

    if is_partial {
        warning := recast.Nav_Error{
            category = recast.Nav_Error_Category.None,
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
                                     extents: [3]f32 = {}) -> recast.Nav_Result(bool) {
    if ctx == nil {
        return recast.nav_error_here(bool, recast.Nav_Error_Category.Invalid_Parameter,
                                      "Navigation context cannot be nil")
    }

    if ctx.nav_mesh == nil {
        return recast.nav_error_here(bool, recast.Nav_Error_Category.Internal_Error,
                                      "Navigation mesh not initialized")
    }

    search_extents := extents
    if search_extents == {} {
        search_extents = ctx.default_extents
    }

    status, poly_ref, nearest_pt := find_nearest_poly(&ctx.query, pos, search_extents, &ctx.filter)

    if recast.status_failed(status) {
        return recast.nav_error_here(bool, recast.Nav_Error_Category.Algorithm_Failed,
                                      "Failed to query navigation mesh")
    }

    return recast.nav_ok(bool, poly_ref != recast.INVALID_POLY_REF)
}

// Get distance to nearest walkable surface
nav_get_distance_to_walkable :: proc(ctx: ^Enhanced_Nav_Context, pos: [3]f32,
                                    extents: [3]f32 = {}) -> recast.Nav_Result(f32) {
    if ctx == nil {
        return recast.nav_error_here(f32, recast.Nav_Error_Category.Invalid_Parameter,
                                      "Navigation context cannot be nil")
    }

    if ctx.nav_mesh == nil {
        return recast.nav_error_here(f32, recast.Nav_Error_Category.Internal_Error,
                                      "Navigation mesh not initialized")
    }

    search_extents := extents
    if search_extents == {} {
        search_extents = ctx.default_extents
    }

    status, poly_ref, nearest_pt := find_nearest_poly(&ctx.query, pos, search_extents, &ctx.filter)

    if recast.status_failed(status) {
        return recast.nav_error_here(f32, recast.Nav_Error_Category.Algorithm_Failed,
                                      "Failed to query navigation mesh")
    }

    if poly_ref == recast.INVALID_POLY_REF {
        return recast.nav_error_here(f32, recast.Nav_Error_Category.Algorithm_Failed,
                                      "No walkable surface found within search radius")
    }

    distance := linalg.distance(pos, nearest_pt)
    return recast.nav_ok(f32, distance)
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
