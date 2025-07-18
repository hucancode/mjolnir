package navigation

// Recast area constants matching original
WALKABLE_AREA :: 63
NULL_AREA :: 0

// Region constants
BORDER_REG :: 0x8000

// Contour vertex flags
BORDER_VERTEX :: 0x10000
AREA_BORDER :: 0x20000
CONTOUR_REG_MASK :: 0xffff

// Contour build flags
CONTOUR_TESS_WALL_EDGES :: 0x01  // Tessellate solid (impassable) edges during contour simplification
CONTOUR_TESS_AREA_EDGES :: 0x02  // Tessellate edges between areas during contour simplification

// Additional area type constants
AREA_WALKABLE :: int(AreaTypeSet.WALKABLE)
AREA_WATER :: int(AreaTypeSet.WATER)
AREA_DOOR :: int(AreaTypeSet.DOOR)
AREA_GRASS :: int(AreaTypeSet.GRASS)

// Area type set for bitflags
AreaTypeSet :: enum u8 {
  WALKABLE = 0,
  UNWALKABLE = 1,
  DOOR = 2,
  WATER = 3,
  ROAD = 4,
  GRASS = 5,
  JUMP = 6,
  SPECIAL = 7,
}

// Recast configuration matching original rcConfig
Config :: struct {
  width:                     i32,      // Grid width in voxels
  height:                    i32,      // Grid height in voxels
  tile_size:                 i32,      // Tile size in voxels (0 = no tiles)
  border_size:               i32,      // Border size in voxels
  cs:                        f32,      // Cell size (xz-plane)
  ch:                        f32,      // Cell height (y-axis)
  bmin:                      [3]f32,   // AABB min bounds
  bmax:                      [3]f32,   // AABB max bounds
  walkable_slope_angle:      f32,      // Max walkable slope angle in degrees
  walkable_height:           i32,      // Min walkable height (in cells)
  walkable_climb:            i32,      // Max climbable height (in cells)
  walkable_radius:           i32,      // Agent radius (in cells)
  max_edge_len:              i32,      // Max edge length (in cells)
  max_simplification_error:  f32,      // Max simplification error
  min_region_area:           i32,      // Min region area (in cells)
  merge_region_area:         i32,      // Merge region area threshold
  max_verts_per_poly:        i32,      // Max vertices per polygon
  detail_sample_dist:        f32,      // Detail mesh sample distance
  detail_sample_max_error:   f32,      // Detail mesh max error
}

// Span constants
SPAN_HEIGHT_BITS :: 13
SPAN_MAX_HEIGHT :: (1 << SPAN_HEIGHT_BITS) - 1
SPANS_PER_POOL :: 2048

// Recast span structure
Span :: struct {
  smin: u32,          // Min height of span
  smax: u32,          // Max height of span
  area: u8,           // Area ID
  next: ^Span,      // Next span in column
}

// Memory pool for spans
SpanPool :: struct {
  next:  ^SpanPool,             // Next pool
  items: [SPANS_PER_POOL]Span, // Spans in pool
}

// Recast heightfield
Heightfield :: struct {
  width:    i32,                  // Width in cells
  height:   i32,                  // Height in cells
  bmin:     [3]f32,               // Min bounds
  bmax:     [3]f32,               // Max bounds
  cs:       f32,                  // Cell size
  ch:       f32,                  // Cell height
  spans:    []^Span,            // Array of span columns
  pools:    ^SpanPool,          // Memory pools
  freelist: ^Span,              // Free list
}

// Compact heightfield structures
CompactCell :: struct {
  index: u32,         // Index to first span (24 bits) and count (8 bits)
}

CompactSpan :: struct {
  y:   u16,           // Bottom of span
  reg: u16,           // Region ID
  con: u32,           // Packed connections (24 bits) and height (8 bits)
}

CompactHeightfield :: struct {
  width:           i32,                    // Width in cells
  height:          i32,                    // Height in cells
  span_count:      i32,                    // Total number of spans
  walkable_height: i32,                    // From config
  walkable_climb:  i32,                    // From config
  border_size:     i32,                    // Border size used
  max_distance:    u16,                    // Max distance value
  max_regions:     u16,                    // Max region ID
  bmin:            [3]f32,                 // Min bounds
  bmax:            [3]f32,                 // Max bounds
  cs:              f32,                    // Cell size
  ch:              f32,                    // Cell height
  cells:           []CompactCell,        // Array of cells
  spans:           []CompactSpan,        // Array of spans
  dist:            []u16,                  // Distance field
  areas:           []u8,                   // Area IDs
}

// Contour structures
Contour :: struct {
  verts:  []i32,      // Vertices (x,y,z,reg tuples)
  nverts: i32,        // Number of vertices
  rverts: []i32,      // Raw vertices
  nrverts: i32,       // Number of raw vertices
  reg:    u16,        // Region ID
  area:   u8,         // Area ID
}

ContourSet :: struct {
  conts:       []Contour,          // Contours
  nconts:      i32,                  // Number of contours
  bmin:        [3]f32,               // Min bounds
  bmax:        [3]f32,               // Max bounds
  cs:          f32,                  // Cell size
  ch:          f32,                  // Cell height
  width:       i32,                  // Width
  height:      i32,                  // Height
  border_size: i32,                // Border size
  max_error:   f32,                  // Max edge error
}

// Polygon mesh structures
PolyMesh :: struct {
  verts:          []u16,                // Vertices (x,y,z tuples)
  polys:          []u16,                // Polygons (vertex indices + neighbor info)
  regs:           []u16,                // Region IDs per polygon
  flags:          []u16,                // Flags per polygon
  areas:          []u8,                 // Area types per polygon
  nverts:         i32,                  // Number of vertices
  npolys:         i32,                  // Number of polygons
  max_polys:      i32,                  // Max polygons allocated
  nvp:            i32,                  // Max vertices per polygon
  bmin:           [3]f32,               // Min bounds
  bmax:           [3]f32,               // Max bounds
  cs:             f32,                  // Cell size
  ch:             f32,                  // Cell height
  border_size:    i32,                // Border size
  max_edge_error: f32,              // Max edge error
}

// Detail mesh structures
PolyMeshDetail :: struct {
  meshes:   []u32,                // Mesh data (vertBase, vertCount, triBase, triCount)
  verts:    []f32,                // Vertices (x,y,z tuples)
  tris:     []u8,                 // Triangles (3 indices per triangle)
  n_meshes: i32,                  // Number of meshes
  n_verts:  i32,                  // Number of vertices
  n_tris:   i32,                  // Number of triangles
}

// Connection constant
// NOT_CONNECTED :: 0x3F  // Defined in navigation.odin

// Helper functions for packing/unpacking
pack_compact_cell :: proc(index: u32, count: u8) -> u32 {
  return (index & 0xFFFFFF) | (u32(count) << 24)
}

unpack_compact_cell :: proc(cell: u32) -> (index: u32, count: u8) {
  return cell & 0xFFFFFF, u8(cell >> 24)
}

pack_compact_span :: proc(con: u32, h: u8) -> u32 {
  return (con & 0xFFFFFF) | (u32(h) << 24)
}

unpack_compact_span :: proc(span: u32) -> (con: u32, h: u8) {
  return span & 0xFFFFFF, u8(span >> 24)
}
