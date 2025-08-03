package navigation_recast


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
Rc_Contour :: struct {
    verts:   [][4]i32,     // Simplified contour vertex and connection data [x, y, z, connection]
    rverts:  [][4]i32,     // Raw contour vertex and connection data [x, y, z, connection]
    reg:     u16,          // Region id of the contour
    area:    u8,           // Area id of the contour
}

// Contour set
Rc_Contour_Set :: struct {
    conts:       [dynamic]Rc_Contour,    // Dynamic array of contours
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
Rc_Poly_Mesh :: struct {
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
Rc_Poly_Mesh_Detail :: struct {
    meshes:  [][4]u32,   // Sub-mesh data [vert_base, vert_count, tri_base, tri_count]
    verts:   [][3]f32,   // Mesh vertices [x, y, z]
    tris:    [][4]u8,    // Mesh triangles [vertA, vertB, vertC, flags]
}

// Edge structure for contour building
Rc_Edge :: struct {
    vert:     [2]u16,
    poly:     [2]u16,
    poly_edge: [2]u16,
}

// Potential diagonal for triangulation
Rc_Potential_Diagonal :: struct {
    vert: i32,
    dist: i32,
}

// Region structure for region building
Rc_Region :: struct {
    span_count:          i32,
    id:                  u16,
    area_type:           u8,
    remap:               bool,
    visited:             bool,
    overlap:             bool,
    connect_to_border:   bool,
    ymin:                u16,
    ymax:                u16,
}

// Layer region for layer building
Rc_Layer_Region :: struct {
    id:            u8,
    layer_id:      u8,
    base:          bool,
    ymin:          u16,
    ymax:          u16,
    layers:        [RC_MAX_LAYERS]u8,
    nlayers:       u8,
}

// Dirty entry for distance field
Rc_Dirty_Entry :: struct {
    index: i32,
    x:     i32,
    y:     i32,
    z:     i32,
}

// Build context for passing state between functions
Rc_Build_Context :: struct {
    // Intermediate results
    solid:       ^Rc_Heightfield,
    chf:         ^Rc_Compact_Heightfield,
    cset:        ^Rc_Contour_Set,
    pmesh:       ^Rc_Poly_Mesh,
    dmesh:       ^Rc_Poly_Mesh_Detail,

    // Configuration
    cfg:         Config,

    // Context for logging/timing
}

// Heightfield layer representing a single layer in a layer set
Rc_Heightfield_Layer :: struct {
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

// Helper to allocate contour - DEPRECATED
// This function is no longer needed since we're using dynamic arrays
// The caller should append to cset.conts directly
rc_alloc_contour :: proc(cset: ^Rc_Contour_Set) -> ^Rc_Contour {
    panic("rc_alloc_contour is deprecated, modify code to use append instead")
}

// Helper to allocate poly mesh
rc_alloc_poly_mesh :: proc() -> ^Rc_Poly_Mesh {
    pmesh := new(Rc_Poly_Mesh)
    return pmesh
}

// Helper to free poly mesh
rc_free_poly_mesh :: proc(pmesh: ^Rc_Poly_Mesh) {
    if pmesh.verts != nil do delete(pmesh.verts)
    if pmesh.polys != nil do delete(pmesh.polys)
    if pmesh.regs != nil do delete(pmesh.regs)
    if pmesh.flags != nil do delete(pmesh.flags)
    if pmesh.areas != nil do delete(pmesh.areas)
    free(pmesh)
}

// Helper to allocate poly mesh detail
rc_alloc_poly_mesh_detail :: proc() -> ^Rc_Poly_Mesh_Detail {
    dmesh := new(Rc_Poly_Mesh_Detail)
    return dmesh
}

// Helper to free poly mesh detail
rc_free_poly_mesh_detail :: proc(dmesh: ^Rc_Poly_Mesh_Detail) {
    if dmesh == nil do return
    if dmesh.meshes != nil do delete(dmesh.meshes)
    if dmesh.verts != nil do delete(dmesh.verts)
    if dmesh.tris != nil do delete(dmesh.tris)
    free(dmesh)
}


RC_PI :: 3.14159265

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
RC_CONTOUR_TESS_WALL_EDGES :: 0x01
RC_CONTOUR_TESS_AREA_EDGES :: 0x02

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
