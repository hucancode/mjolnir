package navigation_recast

import "core:mem"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"

// ========================================
// STANDARDIZED ERROR HANDLING SYSTEM
// ========================================

// Navigation error categories for structured error handling
Nav_Error_Category :: enum u8 {
    None = 0,

    // Input validation errors
    Invalid_Parameter,
    Invalid_Geometry,
    Invalid_Configuration,

    // Resource errors
    Out_Of_Memory,
    Buffer_Too_Small,
    Resource_Exhausted,

    // Algorithm errors
    Algorithm_Failed,
    Convergence_Failed,
    Numerical_Instability,

    // I/O errors
    File_Not_Found,
    File_Corrupted,
    Serialization_Failed,

    // System errors
    Thread_Error,
    Timeout,
    Internal_Error,
}

// Navigation error with detailed context
Nav_Error :: struct {
    category:    Nav_Error_Category,
    code:        u32,                // Specific error code within category
    message:     string,             // Human-readable error message
    ctx:         string,             // Additional context (function name, file, etc.)
    inner_error: ^Nav_Error,         // Nested error for error chains
}

// Result type for operations that can fail
Nav_Result :: struct($T: typeid) {
    value:   T,
    error:   Nav_Error,
    success: bool,
}


// Get direction offsets for 4-connected grid
get_dir_offset_x :: proc "contextless" (dir: int) -> i32 {
    offset := [4]i32{-1, 0, 1, 0}
    return offset[dir & 0x03]
}

get_dir_offset_y :: proc "contextless" (dir: int) -> i32 {
    offset := [4]i32{0, 1, 0, -1}
    return offset[dir & 0x03]
}
// ========================================
// ERROR CREATION HELPERS
// ========================================

// Create a successful result
nav_ok :: proc($T: typeid, value: T) -> Nav_Result(T) {
    return Nav_Result(T){
        value = value,
        error = {},
        success = true,
    }
}

// Create a simple success result for bool
nav_success :: proc() -> Nav_Result(bool) {
    return nav_ok(bool, true)
}

// Create an error result
nav_error :: proc($T: typeid, category: Nav_Error_Category, message: string,
                 ctx: string = "", code: u32 = 0) -> Nav_Result(T) {
    return Nav_Result(T){
        value = {},
        error = Nav_Error{
            category = category,
            code = code,
            message = message,
            ctx = ctx,
        },
        success = false,
    }
}

// Create error with context automatically captured
nav_error_here :: proc($T: typeid, category: Nav_Error_Category, message: string,
                      code: u32 = 0, loc := #caller_location) -> Nav_Result(T) {
    ctx := fmt.tprintf("%s:%d", loc.procedure, loc.line)
    return nav_error(T, category, message, ctx, code)
}

// Chain errors for error propagation
nav_error_chain :: proc($T: typeid, category: Nav_Error_Category, message: string,
                       inner: Nav_Error, ctx: string = "", code: u32 = 0) -> Nav_Result(T) {
    inner_copy := new(Nav_Error)
    inner_copy^ = inner

    return Nav_Result(T){
        value = {},
        error = Nav_Error{
            category = category,
            code = code,
            message = message,
            ctx = ctx,
            inner_error = inner_copy,
        },
        success = false,
    }
}

// ========================================
// VALIDATION HELPERS
// ========================================

// Check if result is successful
nav_is_ok :: proc(result: Nav_Result($T)) -> bool {
    return result.success
}

// Check if result is an error
nav_is_error :: proc(result: Nav_Result($T)) -> bool {
    return !result.success
}

// Convert Status to Nav_Result
nav_from_status :: proc(status: Status) -> Nav_Result(Status) {
    if status_succeeded(status) {
        return nav_ok(Status, status)
    }

    // Map status flags to error categories
    category := Nav_Error_Category.Algorithm_Failed
    message := "Unknown error"

    if .Invalid_Param in status {
        category = .Invalid_Parameter
        message = "Invalid parameter"
    } else if .Out_Of_Memory in status {
        category = .Out_Of_Memory
        message = "Out of memory"
    } else if .Buffer_Too_Small in status {
        category = .Buffer_Too_Small
        message = "Buffer too small"
    } else if .Out_Of_Nodes in status {
        category = .Resource_Exhausted
        message = "Out of pathfinding nodes"
    } else if .Wrong_Magic in status {
        category = .File_Corrupted
        message = "Invalid file format (wrong magic number)"
    } else if .Wrong_Version in status {
        category = .File_Corrupted
        message = "Unsupported file version"
    }

    return nav_error(Status, category, message)
}

// Validate pointer is not nil
nav_require_non_nil :: proc(ptr: rawptr, name: string, loc := #caller_location) -> Nav_Result(bool) {
    if ptr == nil {
        return nav_error_here(bool, .Invalid_Parameter, fmt.tprintf("Parameter '%s' cannot be nil", name))
    }
    return nav_success()
}

// Validate positive value
nav_require_positive :: proc(value: $T, name: string, loc := #caller_location) -> Nav_Result(bool) {
    if value <= 0 {
        return nav_error_here(bool, .Invalid_Parameter,
                             fmt.tprintf("Parameter '%s' (%v) must be positive", name, value))
    }
    return nav_success()
}
// Build types for region partitioning
Partition_Type :: enum {
    Watershed,
    Monotone,
    Layers,
}

// Off-mesh connection endpoints
Off_Mesh_Connection_Verts :: struct {
    start: [3]f32,  // Start position (ax, ay, az)
    end:   [3]f32,  // End position (bx, by, bz)
}

// Contour structure
Contour :: struct {
    verts:   [][4]i32,     // Simplified contour vertex and connection data [x, y, z, connection]
    rverts:  [][4]i32,     // Raw contour vertex and connection data [x, y, z, connection]
    reg:     u16,          // Region id of the contour
    area:    u8,           // Area id of the contour
}

// Contour set
Contour_Set :: struct {
    conts:       [dynamic]Contour,    // Dynamic array of contours
    bmin:        [3]f32,   // Minimum bounds
    bmax:        [3]f32,   // Maximum bounds
    cs:          f32,              // Cell size
    ch:          f32,              // Cell height
    width:       i32,              // Width in cells
    height:      i32,              // Height in cells
    border_size: i32,              // Border size
    max_error:   f32,              // Max edge error
}

// Polygon mesh
Poly_Mesh :: struct {
    verts:          [][3]u16,      // Mesh vertices [x, y, z]
    polys:          []u16,         // Polygon and neighbor data [Length: maxpolys * 2 * nvp]
    regs:           []u16,         // Region id per polygon [Length: maxpolys]
    flags:          []u16,         // User flags per polygon [Length: maxpolys]
    areas:          []u8,          // Area id per polygon [Length: maxpolys]
    npolys:         i32,           // Number of polygons
    maxpolys:       i32,           // Number of allocated polygons
    nvp:            i32,           // Max vertices per polygon
    bmin:           [3]f32,// Minimum bounds
    bmax:           [3]f32,// Maximum bounds
    cs:             f32,           // Cell size
    ch:             f32,           // Cell height
    border_size:    i32,           // Border size
    max_edge_error: f32,           // Max edge error
}

// Polygon mesh detail
Poly_Mesh_Detail :: struct {
    meshes:  [][4]u32,   // Sub-mesh data [vert_base, vert_count, tri_base, tri_count]
    verts:   [][3]f32,   // Mesh vertices [x, y, z]
    tris:    [][4]u8,    // Mesh triangles [vertA, vertB, vertC, flags]
}

// Edge structure for contour building
Edge :: struct {
    vert:     [2]u16,
    poly:     [2]u16,
    poly_edge: [2]u16,
}

// Potential diagonal for triangulation
Potential_Diagonal :: struct {
    vert: i32,
    dist: i32,
}

// Layer region for layer building
Layer_Region :: struct {
    id:            u8,
    layer_id:      u8,
    base:          bool,
    ymin:          u16,
    ymax:          u16,
    layers:        [RC_MAX_LAYERS]u8,
    nlayers:       u8,
}

// Build context for passing state between functions
Build_Context :: struct {
    // Intermediate results
    solid:       ^Heightfield,
    chf:         ^Compact_Heightfield,
    cset:        ^Contour_Set,
    pmesh:       ^Poly_Mesh,
    dmesh:       ^Poly_Mesh_Detail,

    // Configuration
    cfg:         Config,

    // Context for logging/timing
}

// Heightfield layer representing a single layer in a layer set
Heightfield_Layer :: struct {
    bmin:        [3]f32,         // Minimum bounds in world space
    bmax:        [3]f32,         // Maximum bounds in world space
    cs:          f32,            // Cell size (XZ plane)
    ch:          f32,            // Cell height (Y axis)
    width:       i32,            // Width of the layer (along X-axis in cell units)
    height:      i32,            // Height of the layer (along Z-axis in cell units)
    minx:        i32,            // Minimum X bounds of usable data
    maxx:        i32,            // Maximum X bounds of usable data
    miny:        i32,            // Minimum Y bounds of usable data (along Z-axis)
    maxy:        i32,            // Maximum Y bounds of usable data (along Z-axis)
    hmin:        i32,            // Minimum height bounds of usable data (along Y-axis)
    hmax:        i32,            // Maximum height bounds of usable data (along Y-axis)
    heights:     []u8,           // Height values [Size: width * height]
    areas:       []u8,           // Area IDs [Size: width * height]
    cons:        []u8,           // Packed neighbor connection information [Size: width * height]
}

// Helper to allocate poly mesh
alloc_poly_mesh :: proc() -> ^Poly_Mesh {
    pmesh := new(Poly_Mesh)
    return pmesh
}

// Helper to free poly mesh
free_poly_mesh :: proc(pmesh: ^Poly_Mesh) {
    delete(pmesh.verts)
    delete(pmesh.polys)
    delete(pmesh.regs)
    delete(pmesh.flags)
    delete(pmesh.areas)
    free(pmesh)
}

// Helper to allocate poly mesh detail
alloc_poly_mesh_detail :: proc() -> ^Poly_Mesh_Detail {
    dmesh := new(Poly_Mesh_Detail)
    return dmesh
}

// Helper to free poly mesh detail
free_poly_mesh_detail :: proc(dmesh: ^Poly_Mesh_Detail) {
    if dmesh == nil do return
    delete(dmesh.meshes)
    delete(dmesh.verts)
    delete(dmesh.tris)
    free(dmesh)
}
// Build time configuration constants
RC_COMPRESSION :: true  // Enable compression for tile cache
RC_LARGE_WORLDS :: true // Enable 64-bit tile/poly references

// Heightfield edge flags
RC_LEDGE_BORDER :: 0x1
RC_LEDGE_WALKABLE :: 0x2

// Poly mesh flags
RC_MESH_FLAG_16BIT_INDICES :: 1 << 0

// Detail mesh flags
DT_DETAIL_EDGE_BOUNDARY :: 0x01

// Tile flags
DT_TILE_FREE_DATA :: 0x01

// Off-mesh connection flags
DT_OFFMESH_CON_BIDIR :: 1

// Poly types
DT_POLYTYPE_GROUND :: 0
DT_POLYTYPE_OFFMESH_CONNECTION :: 1

// Find path options
DT_FINDPATH_ANY_ANGLE :: 0x02

// Raycast options
DT_RAYCAST_USE_COSTS :: 0x01

// Straightpath options
DT_STRAIGHTPATH_AREA_CROSSINGS :: 0x01
DT_STRAIGHTPATH_ALL_CROSSINGS :: 0x02

// Navigation mesh parameters
DT_VERTS_PER_POLYGON :: 6
DT_NAVMESH_MAGIC :: 'D'<<24 | 'N'<<16 | 'A'<<8 | 'V'
DT_NAVMESH_VERSION :: 7
DT_NAVMESH_STATE_MAGIC :: 'D'<<24 | 'N'<<16 | 'M'<<8 | 'S'
DT_NAVMESH_STATE_VERSION :: 1

// Tile parameters
DT_MAX_AREAS :: 64

// Default query limits
DEFAULT_MAX_PATH :: 256
DEFAULT_MAX_POLYGONS :: 256
DEFAULT_MAX_SMOOTH :: 2048

// Crowd agent states
DT_CROWDAGENT_STATE_INVALID :: 0
DT_CROWDAGENT_STATE_WALKING :: 1
DT_CROWDAGENT_STATE_OFFMESH :: 2

// Crowd agent update flags
DT_CROWDAGENT_TARGET_NONE :: 0
DT_CROWDAGENT_TARGET_FAILED :: 1
DT_CROWDAGENT_TARGET_VALID :: 2
DT_CROWDAGENT_TARGET_REQUESTING :: 3
DT_CROWDAGENT_TARGET_WAITING_FOR_QUEUE :: 4
DT_CROWDAGENT_TARGET_WAITING_FOR_PATH :: 5
DT_CROWDAGENT_TARGET_VELOCITY :: 6

// Move request states
DT_CROWDAGENT_TARGET_ADJUSTED :: 16

// Obstacle avoidance
DT_MAX_PATTERN_DIVS :: 32
DT_MAX_PATTERN_RINGS :: 4

// Sample area types (used in test scenes and examples)
SAMPLE_POLYAREA_NULL :: 0
SAMPLE_POLYAREA_GROUND :: 1
SAMPLE_POLYAREA_WATER :: 2
SAMPLE_POLYAREA_DOOR :: 3
SAMPLE_POLYAREA_GRASS :: 4
SAMPLE_POLYAREA_JUMP :: 5
SAMPLE_POLYAREA_LADDER :: 6

// TileCache parameters
DT_TILECACHE_MAGIC :: 'D'<<24 | 'T'<<16 | 'L'<<8 | 'R'
DT_TILECACHE_VERSION :: 1
DT_TILECACHE_NULL_AREA :: 0
DT_TILECACHE_WALKABLE_AREA :: 63
DT_TILECACHE_NULL_IDX :: 0xffff

// Compressed tile flags
DT_COMPRESSEDTILE_FREE_DATA :: 0x01

// Layer region flags
DT_LAYER_MAX_NEIS :: 16

// Max layers
RC_MAX_LAYERS :: 32

// Span constants
RC_SPAN_HEIGHT_BITS :: 13
RC_SPAN_MAX_HEIGHT :: (1 << RC_SPAN_HEIGHT_BITS) - 1
RC_SPANS_PER_POOL :: 2048

// Area constants
RC_NULL_AREA :: 0
RC_WALKABLE_AREA :: 63
RC_NOT_CONNECTED :: 0x3f

// Region constants
RC_BORDER_REG :: 0x8000
RC_MULTIPLE_REGS :: 0
RC_BORDER_VERTEX :: 0x10000
RC_AREA_BORDER :: 0x20000
RC_CONTOUR_REG_MASK :: 0xffff
RC_MESH_NULL_IDX :: 0xffff
// Contour tessellation flags
Contour_Tess_Flag :: enum {
	WALL_EDGES = 0,  // Tessellate solid (impassable) edges during contour simplification
	AREA_EDGES = 1,  // Tessellate edges between areas during contour simplification
}
Contour_Tess_Flags :: bit_set[Contour_Tess_Flag; u32]

// Vertex flags for contour points
Vertex_Flag :: enum {
	BORDER_VERTEX = 16, // RC_BORDER_VERTEX (0x10000)
	AREA_BORDER = 17,   // RC_AREA_BORDER (0x20000)
}
Vertex_Flags :: bit_set[Vertex_Flag; u32]

// Invalid references
DT_NULL_LINK :: 0xffffffff
INVALID_POLY_REF :: Poly_Ref(0)
INVALID_TILE_REF :: Tile_Ref(0)

// Type-safe references
Poly_Ref :: distinct u32
Tile_Ref :: distinct u32
Agent_Id :: distinct u32
Obstacle_Ref :: distinct u32

// Status flags using bit_set for efficient operations
Status_Flag :: enum u32 {
    Success        = 0,
    In_Progress    = 1,
    Partial_Result = 2,
    // Error flags start at bit 16
    Wrong_Magic    = 16,
    Wrong_Version  = 17,
    Out_Of_Memory  = 18,
    Invalid_Param  = 19,
    Buffer_Too_Small = 20,
    Out_Of_Nodes   = 21,
    Partial_Path   = 22,
}

Status :: bit_set[Status_Flag; u32]

// Status helper functions
status_succeeded :: proc "contextless" (status: Status) -> bool {
    return Status_Flag.Success in status && card(status & {.Wrong_Magic, .Wrong_Version, .Out_Of_Memory, .Invalid_Param, .Buffer_Too_Small, .Out_Of_Nodes}) == 0
}

status_failed :: proc "contextless" (status: Status) -> bool {
    return !status_succeeded(status)
}

status_in_progress :: proc "contextless" (status: Status) -> bool {
    return Status_Flag.In_Progress in status
}

status_detail :: proc "contextless" (status: Status) -> (Status, Status) {
    success_mask := Status{.Success, .In_Progress, .Partial_Result}
    return status & success_mask, status & ~success_mask
}

// Configuration structure for building navigation meshes
Config :: struct {
    width:                    i32,     // Field width in voxels
    height:                   i32,     // Field height in voxels
    tile_size:                i32,     // Tile size in voxels (0 = no tiling)
    border_size:              i32,     // Border size in voxels
    cs:                       f32,     // Cell size in world units
    ch:                       f32,     // Cell height in world units
    bmin:                     [3]f32,  // Minimum bounds
    bmax:                     [3]f32,  // Maximum bounds
    walkable_slope_angle:     f32,     // Maximum walkable slope in degrees
    walkable_height:          i32,     // Minimum floor to ceiling height in cells
    walkable_climb:           i32,     // Maximum ledge height in cells
    walkable_radius:          i32,     // Agent radius in cells
    max_edge_len:             i32,     // Maximum edge length in cells
    max_simplification_error: f32,     // Maximum edge error in voxels
    min_region_area:          i32,     // Minimum region area in cells
    merge_region_area:        i32,     // Merge region area in cells
    max_verts_per_poly:       i32,     // Maximum vertices per polygon
    detail_sample_dist:       f32,     // Detail mesh sample distance
    detail_sample_max_error:  f32,     // Detail mesh sample max error
}
// Build navigation mesh from triangle mesh
// This is the main entry point
build_navmesh :: proc(vertices: [][3]f32, indices: []i32, areas: []u8, cfg: Config) -> (pmesh: ^Poly_Mesh, dmesh: ^Poly_Mesh_Detail, ok: bool) {
    // Validate inputs
    if len(vertices) == 0 || len(indices) == 0 || cfg.cs <= 0 || cfg.ch <= 0 {
        return
    }

    // Calculate bounds if needed
    config := cfg
    if config.bmin == {} && config.bmax == {} {
        config.bmin, config.bmax = calc_bounds(vertices)
    }

    // Calculate grid size
    config.width, config.height = calc_grid_size(config.bmin, config.bmax, config.cs)

    // Validate grid size
    if config.width <= 0 || config.height <= 0 {
        return
    }

    // Build heightfield
    hf := new(Heightfield)
    defer free_heightfield(hf)

    create_heightfield(hf, config.width, config.height, config.bmin, config.bmax, config.cs, config.ch) or_return
    // Debug: Check areas before rasterization
    when ODIN_DEBUG {
        log.infof("Rasterizing %d triangles with areas:", len(indices)/3)
        for i in 0..<min(10, len(areas)) {
            log.infof("  Triangle %d: area=%d", i, areas[i])
        }
        // Also check if we're marking triangles as unwalkable due to slope
        walkable_thr := math.cos(math.to_radians(config.walkable_slope_angle))
        log.infof("Walkable slope threshold: %.3f (angle=%.1f degrees)", walkable_thr, config.walkable_slope_angle)

        // Check first triangle normal
        if len(indices) >= 3 {
            v0 := vertices[indices[0]]
            v1 := vertices[indices[1]]
            v2 := vertices[indices[2]]
            norm := linalg.normalize(linalg.cross(v1 - v0, v2 - v0))
            log.infof("First triangle normal: (%.3f, %.3f, %.3f), Y=%.3f %s threshold %.3f",
                      norm.x, norm.y, norm.z, norm.y,
                      norm.y > walkable_thr ? ">" : "<=", walkable_thr)
        }
    }
    rasterize_triangles(vertices, indices, areas, hf, config.walkable_climb) or_return
    // Debug: Count spans in heightfield
    when ODIN_DEBUG {
        span_count := 0
        null_area_count := 0
        total_spans := 0
        non_empty_cells := 0
        for y in 0..<hf.height {
            for x in 0..<hf.width {
                s := hf.spans[x + y * hf.width]
                if s != nil {
                    non_empty_cells += 1
                }
                for s != nil {
                    total_spans += 1
                    if s.area != RC_NULL_AREA {
                        span_count += 1
                    } else {
                        null_area_count += 1
                    }
                    s = s.next
                }
            }
        }
        log.infof("Heightfield after rasterization: %d total spans in %d non-empty cells", total_spans, non_empty_cells)
        log.infof("  %d walkable spans, %d null area spans", span_count, null_area_count)

        // Check span distribution
        quadrants := [4]int{0, 0, 0, 0}  // NE, NW, SW, SE
        mid_x := hf.width / 2
        mid_z := hf.height / 2
        for y in 0..<hf.height {
            for x in 0..<hf.width {
                s := hf.spans[x + y * hf.width]
                if s != nil && s.area != RC_NULL_AREA {
                    quad := 0
                    if x < mid_x && y < mid_z do quad = 2  // SW
                    else if x >= mid_x && y < mid_z do quad = 3  // SE
                    else if x < mid_x && y >= mid_z do quad = 1  // NW
                    else do quad = 0  // NE
                    quadrants[quad] += 1
                }
            }
        }
        log.infof("Span distribution by quadrant: NE=%d, NW=%d, SW=%d, SE=%d",
                  quadrants[0], quadrants[1], quadrants[2], quadrants[3])
    }

    // Filter walkable surfaces
    filter_low_hanging_walkable_obstacles(int(config.walkable_climb), hf)
    filter_ledge_spans(int(config.walkable_height), int(config.walkable_climb), hf)
    filter_walkable_low_height_spans(int(config.walkable_height), hf)

    // Debug: Count spans after filtering
    when ODIN_DEBUG {
        span_count2 := 0
        quadrants2 := [4]int{0, 0, 0, 0}  // NE, NW, SW, SE
        mid_x2 := hf.width / 2
        mid_z2 := hf.height / 2
        for y in 0..<hf.height {
            for x in 0..<hf.width {
                for s := hf.spans[x + y * hf.width]; s != nil;s = s.next do if s.area != RC_NULL_AREA {
                    span_count2 += 1
                    quad := 0
                    if x < mid_x2 && y < mid_z2 do quad = 2  // SW
                    else if x >= mid_x2 && y < mid_z2 do quad = 3  // SE
                    else if x < mid_x2 && y >= mid_z2 do quad = 1  // NW
                    else do quad = 0  // NE
                    quadrants2[quad] += 1
                }
            }
        }
        log.infof("Heightfield after filtering: %d walkable spans", span_count2)
        log.infof("After filtering distribution: NE=%d, NW=%d, SW=%d, SE=%d",
                  quadrants2[0], quadrants2[1], quadrants2[2], quadrants2[3])
    }

    // Build compact heightfield
    chf := new(Compact_Heightfield)
    defer free_compact_heightfield(chf)
    build_compact_heightfield(config.walkable_height, config.walkable_climb, hf, chf) or_return
    erode_walkable_area(config.walkable_radius, chf) or_return
    build_distance_field(chf) or_return
    log.infof("Building regions with min_area=%d, merge_area=%d", config.min_region_area, config.merge_region_area)
    build_regions(chf, 0, config.min_region_area, config.merge_region_area) or_return
    log.info("Regions built successfully")
    cset := alloc_contour_set()
    defer free_contour_set(cset)
    build_contours(chf, config.max_simplification_error, config.max_edge_len, cset) or_return
    // Build polygon mesh
    pmesh = alloc_poly_mesh()
    if !build_poly_mesh(cset, config.max_verts_per_poly, pmesh) {
        free_poly_mesh(pmesh)
        return
    }
    // Build detail mesh
    dmesh = alloc_poly_mesh_detail()
    if !build_poly_mesh_detail(pmesh, chf, config.detail_sample_dist, config.detail_sample_max_error, dmesh) {
        free_poly_mesh(pmesh)
        free_poly_mesh_detail(dmesh)
        return
    }
    return pmesh, dmesh, true
}
