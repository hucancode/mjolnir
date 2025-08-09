package navigation_detour

import "core:math"
import "core:math/linalg"
import "core:slice"
import nav_recast "../recast"

// Detour navigation mesh polygon
Poly :: struct {
    first_link:   u32,                                    // Index to first link in linked list (DT_NULL_LINK if no link)
    verts:        [nav_recast.DT_VERTS_PER_POLYGON]u16,     // Indices of polygon vertices
    neis:         [nav_recast.DT_VERTS_PER_POLYGON]u16,     // Neighbor data for each edge
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
    ref:   nav_recast.Poly_Ref,  // Neighbor reference (linked polygon)
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
    area_cost:     [nav_recast.DT_MAX_AREAS]f32,  // Cost per area type
    include_flags: u16,                         // Flags for traversable polygons
    exclude_flags: u16,                         // Flags for non-traversable polygons
}

// Raycast hit information
Raycast_Hit :: struct {
    t:              f32,                           // Hit parameter (FLT_MAX if no hit)
    hit_normal:     [3]f32,                        // Normal of nearest wall hit
    hit_edge_index: i32,                           // Edge index on final polygon
    path:           []nav_recast.Poly_Ref,           // Array of visited polygon refs
    path_count:     i32,                           // Number of visited polygons
    path_cost:      f32,                           // Cost of path until hit
}

// Straight path point
Straight_Path_Point :: struct {
    pos:   [3]f32,             // Point position
    flags: u8,                 // Point flags (start, end, off-mesh)
    ref:   nav_recast.Poly_Ref,  // Polygon reference
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
    process: proc(ref: nav_recast.Poly_Ref, tile: ^Mesh_Tile, poly: ^Poly, user_data: rawptr),
    user_data: rawptr,
}

// Default query filter implementation
query_filter_init :: proc(filter: ^Query_Filter) {
    filter.include_flags = 0xffff
    filter.exclude_flags = 0
    slice.fill(filter.area_cost[:], 1.0)
}

query_filter_pass_filter :: proc(filter: ^Query_Filter, ref: nav_recast.Poly_Ref, tile: ^Mesh_Tile, poly: ^Poly) -> bool {
    return (poly.flags & filter.include_flags) != 0 && (poly.flags & filter.exclude_flags) == 0
}

query_filter_get_cost :: proc(filter: ^Query_Filter, 
                                pa: [3]f32, pb: [3]f32,
                                prev_ref: nav_recast.Poly_Ref, prev_tile: ^Mesh_Tile, prev_poly: ^Poly,
                                cur_ref: nav_recast.Poly_Ref, cur_tile: ^Mesh_Tile, cur_poly: ^Poly,
                                next_ref: nav_recast.Poly_Ref, next_tile: ^Mesh_Tile, next_poly: ^Poly) -> f32 {
    // Base cost is distance
    diff := pb - pa
    cost := linalg.length(diff)
    
    // Apply area-specific multiplier
    area := poly_get_area(cur_poly)
    if area < nav_recast.DT_MAX_AREAS {
        cost *= filter.area_cost[area]
    }
    
    return cost
}


// Reference encoding/decoding helpers
encode_poly_id :: proc(nav_mesh: ^Nav_Mesh, salt: u32, tile_index: u32, poly_index: u32) -> nav_recast.Poly_Ref {
    return nav_recast.Poly_Ref((salt << (nav_mesh.poly_bits + nav_mesh.tile_bits)) | 
                            (tile_index << nav_mesh.poly_bits) | 
                            poly_index)
}

decode_poly_id :: proc(nav_mesh: ^Nav_Mesh, ref: nav_recast.Poly_Ref) -> (salt: u32, tile_index: u32, poly_index: u32) {
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
get_poly_index :: proc(nav_mesh: ^Nav_Mesh, ref: nav_recast.Poly_Ref) -> u32 {
    if nav_mesh == nil {
        return 0
    }
    poly_mask := (u32(1) << nav_mesh.poly_bits) - 1
    return u32(ref) & poly_mask
}

// Calculate tile location from world position with robust error handling
calc_tile_loc :: proc(nav_mesh: ^Nav_Mesh, pos: [3]f32) -> (tx: i32, ty: i32, status: nav_recast.Status) {
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
    offset_x := pos[0] - nav_mesh.orig[0]
    offset_z := pos[2] - nav_mesh.orig[2]
    
    // Check for infinite or NaN offset values (could happen if origin is invalid)
    if offset_x != offset_x || offset_z != offset_z ||  // NaN check
       offset_x == math.F32_MAX || offset_x == -math.F32_MAX ||  // Infinity check
       offset_z == math.F32_MAX || offset_z == -math.F32_MAX ||
       math.abs(offset_x) > 1e20 || math.abs(offset_z) > 1e20 {  // Extremely large values
        return 0, 0, {.Invalid_Param}
    }
    
    // Calculate floating-point tile coordinates
    tile_f_x := offset_x / nav_mesh.tile_width
    tile_f_z := offset_z / nav_mesh.tile_height
    
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
    if nav_recast.status_failed(status) {
        return 0, 0
    }
    return result_tx, result_ty
}

// Get detail triangle edge flags
get_detail_tri_edge_flags :: proc(tri_flags: u8, edge_index: i32) -> i32 {
    return i32((tri_flags >> (u8(edge_index) * 2)) & 0x3)
}
