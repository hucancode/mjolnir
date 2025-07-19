package navigation

// Detour constants
VERTS_PER_POLYGON :: 6
NAVMESH_MAGIC :: 'D' << 24 | 'N' << 16 | 'A' << 8 | 'V'
NAVMESH_VERSION :: 7
NAVMESH_STATE_MAGIC :: 'D' << 24 | 'N' << 16 | 'M' << 8 | 'S'
NAVMESH_STATE_VERSION :: 1

// Tile flags
TILE_FREE_DATA :: 0x01

// Polygon types
POLYTYPE_GROUND :: 0
POLYTYPE_OFFMESH_CONNECTION :: 1

// Polygon flags (standard Detour flags)
POLYFLAGS_WALK :: 0x01        // Ability to walk (ground, doors)
POLYFLAGS_SWIM :: 0x02        // Ability to swim (water)
POLYFLAGS_DOOR :: 0x04        // Door passage
POLYFLAGS_JUMP :: 0x08        // Ability to jump
POLYFLAGS_DISABLED :: 0x10    // Disabled polygon
POLYFLAGS_ALL :: 0xFFFF       // All flags

// Status codes as enum with bit flags
StatusFlag :: enum u32 {
  // High level status
  FAILURE = 31,
  SUCCESS = 30,
  IN_PROGRESS = 29,
  // Detail information  
  WRONG_MAGIC = 0,
  WRONG_VERSION = 1,
  OUT_OF_MEMORY = 2,
  INVALID_PARAM = 3,
  BUFFER_TOO_SMALL = 4,
  OUT_OF_NODES = 5,
  PARTIAL_RESULT = 6,
  ALREADY_OCCUPIED = 7,
}

Status :: bit_set[StatusFlag; u32]

// Common status values
FAILURE :: Status{.FAILURE}
SUCCESS :: Status{.SUCCESS}
IN_PROGRESS :: Status{.IN_PROGRESS}

// Check if status is success
status_succeed :: proc(status: Status) -> bool {
  return .SUCCESS in status
}

// Check if status failed
status_failed :: proc(status: Status) -> bool {
  return .FAILURE in status
}

// Check if status is in progress
status_in_progress :: proc(status: Status) -> bool {
  return .IN_PROGRESS in status
}

// Get detail flags from status
status_detail :: proc(status: Status) -> Status {
  // Remove high level flags, keep only detail flags
  detail := status
  detail -= {.FAILURE, .SUCCESS, .IN_PROGRESS}
  return detail
}

// Polygon reference type
PolyRef :: u32
NULL_LINK :: 0xFFFFFFFF

// Extract poly index from reference (lower 8 bits)
decode_poly_id_poly :: proc(ref: PolyRef) -> u32 {
  polyMask :: u32((1 << 8) - 1)
  return ref & polyMask
}

// Extract tile index from reference (bits 8-19)
decode_poly_id_tile :: proc(ref: PolyRef) -> u32 {
  tileMask :: u32((1 << 12) - 1)
  return (ref >> 8) & tileMask
}

// Extract salt from reference (bits 20-31)
decode_poly_id_salt :: proc(ref: PolyRef) -> u32 {
  saltMask :: u32((1 << 12) - 1)
  return (ref >> 20) & saltMask
}

// Encode poly reference: salt(12 bits) | tile(12 bits) | poly(8 bits)
encode_poly_id :: proc(salt, tile, poly: u32) -> PolyRef {
  return (salt << 20) | (tile << 8) | poly
}

// Polygon structure
Poly :: struct {
  first_link: u32,                               // Index to first link
  verts:      [VERTS_PER_POLYGON]u16,           // Vertex indices
  neis:       [VERTS_PER_POLYGON]u16,           // Neighbor data
  flags:      u16,                               // User flags
  vert_count: u8,                                // Number of vertices
  area_and_type: u8,                              // Packed area ID and type
}

// Get/set area and type
get_poly_area :: proc(poly: ^Poly) -> u8 {
  return poly.area_and_type & 0x3F
}

get_poly_type :: proc(poly: ^Poly) -> u8 {
  return poly.area_and_type >> 6
}

set_poly_area :: proc(poly: ^Poly, area: u8) {
  poly.area_and_type = (poly.area_and_type & 0xC0) | (area & 0x3F)
}

set_poly_type :: proc(poly: ^Poly, type: u8) {
  poly.area_and_type = (poly.area_and_type & 0x3F) | (type << 6)
}

// Polygon detail structure
PolyDetail :: struct {
  vert_base:  u32,     // Offset to detail vertex array
  tri_base:   u32,     // Offset to detail triangle array
  vert_count: u8,      // Number of vertices
  tri_count:  u8,      // Number of triangles
}

// Link structure for connections between polygons
Link :: struct {
  ref:  PolyRef,      // Neighbor polygon reference
  next: u32,          // Index to next link
  edge: u8,           // Edge index on current polygon
  side: u8,           // Side index on current polygon
  bmin: u8,           // Min edge coordinate
  bmax: u8,           // Max edge coordinate
}

// BVH node for spatial queries
BVNode :: struct {
  bmin: [3]u16,       // Min bounds
  bmax: [3]u16,       // Max bounds
  i:    i32,          // Index (negative for escape)
}

// Off-mesh connection
OffMeshConnection :: struct {
  pos:     [6]f32,     // Start and end positions
  rad:     f32,        // Connection radius
  poly:    u16,        // Polygon reference
  flags:   u8,         // Connection flags
  side:    u8,         // Side
  user_id: u32,        // User ID
}

// Mesh tile header
MeshHeader :: struct {
  magic:              i32,      // Magic number
  version:            i32,      // Version
  x:                  i32,      // Tile x coord
  y:                  i32,      // Tile y coord
  layer:              i32,      // Tile layer
  user_id:            u32,      // User ID
  poly_count:         i32,      // Number of polygons
  vert_count:         i32,      // Number of vertices
  max_link_count:     i32,      // Max number of links
  detail_mesh_count:  i32,      // Number of detail meshes
  detail_vert_count:  i32,      // Number of detail vertices
  detail_tri_count:   i32,      // Number of detail triangles
  bv_node_count:      i32,      // Number of BVH nodes
  off_mesh_con_count: i32,      // Number of off-mesh connections
  off_mesh_base:      i32,      // Index to first off-mesh connection
  walkable_height:    f32,      // Agent height
  walkable_radius:    f32,      // Agent radius
  walkable_climb:     f32,      // Agent max climb
  bmin:               [3]f32,   // Min bounds
  bmax:               [3]f32,   // Max bounds
  bv_quant_factor:    f32,      // BVH quantization factor
}

// Mesh tile
MeshTile :: struct {
  salt:            u32,                      // Counter for changes
  links_free_list: u32,                     // Index to next free link
  header:          ^MeshHeader,              // Tile header
  polys:           []Poly,                   // Polygons
  verts:           []f32,                    // Vertices (x,y,z)
  links:           []Link,                   // Links
  detail_meshes:   []PolyDetail,             // Detail meshes
  detail_verts:    []f32,                    // Detail vertices
  detail_tris:     []u8,                     // Detail triangles
  bv_tree:         []BVNode,                 // BVH tree
  off_mesh_cons:   []OffMeshConnection,      // Off-mesh connections
  data:            []u8,                     // Raw data
  data_size:       i32,                      // Data size
  flags:           i32,                      // Tile flags
  next:            ^MeshTile,                // Next tile in hash
}

// Navigation mesh
NavMesh :: struct {
  params:         NavMeshParams,        // Current parameters
  orig:           [3]f32,               // Origin
  tile_width:     f32,                  // Tile width
  tile_height:    f32,                  // Tile height
  max_tiles:      i32,                  // Max number of tiles
  tile_lut_size:  i32,                  // Tile hash lookup size
  tile_lut_mask:  i32,                  // Tile hash lookup mask
  pos_lookup:     []^MeshTile,          // Tile hash lookup
  next_free:      ^MeshTile,            // Next free tile
  tiles:          []MeshTile,           // All tiles
  salt_bits:      u32,                  // Salt bits
  tile_bits:      u32,                  // Tile bits
  poly_bits:      u32,                  // Poly bits
}

// Navigation mesh creation parameters
NavMeshParams :: struct {
  orig:        [3]f32,     // Origin
  tile_width:  f32,        // Tile width
  tile_height: f32,        // Tile height
  max_tiles:   i32,        // Maximum tiles
  max_polys:   i32,        // Maximum polygons per tile
}

// Create data parameters
NavMeshCreateParams :: struct {
  // Polygon mesh
  verts:              []u16,                // Vertices
  vert_count:         i32,                  // Vertex count
  polys:              []u16,                // Polygons
  poly_flags:         []u16,                // Polygon flags
  poly_areas:         []u8,                 // Polygon areas
  poly_count:         i32,                  // Polygon count
  nvp:                i32,                  // Max verts per poly
  // Detail mesh
  detail_meshes:      []u32,                // Detail meshes
  detail_verts:       []f32,                // Detail vertices
  detail_verts_count: i32,                  // Detail vertex count
  detail_tris:        []u8,                 // Detail triangles
  detail_tri_count:   i32,                  // Detail triangle count
  // Off-mesh connections
  off_mesh_con_verts:   []f32,                // Off-mesh vertices
  off_mesh_con_rad:     []f32,                // Off-mesh radii
  off_mesh_con_flags:   []u16,                // Off-mesh flags
  off_mesh_con_areas:   []u8,                 // Off-mesh areas
  off_mesh_con_dir:     []u8,                 // Off-mesh directions
  off_mesh_con_user_id: []u32,                // Off-mesh user IDs
  off_mesh_con_count:   i32,                  // Off-mesh count
  // Tile attributes
  user_id:           u32,                  // User ID
  tile_x:            i32,                  // Tile x
  tile_y:            i32,                  // Tile y
  tile_layer:        i32,                  // Tile layer
  // General attributes
  bmin:              [3]f32,               // Min bounds
  bmax:              [3]f32,               // Max bounds
  walkable_height:   f32,                  // Agent height
  walkable_radius:   f32,                  // Agent radius
  walkable_climb:    f32,                  // Agent max climb
  cs:                f32,                  // Cell size
  ch:                f32,                  // Cell height
  build_bv_tree:     bool,                 // Build BVH tree
}

// Query filter
QueryFilter :: struct {
  include_flags: u16,                      // Include poly flags
  exclude_flags: u16,                      // Exclude poly flags
  area_cost:     [64]f32,                  // Cost per area type
}

// Default query filter
query_filter_default :: proc() -> QueryFilter {
  filter: QueryFilter
  filter.include_flags = 0xFFFF
  filter.exclude_flags = 0
  
  // Set default area costs
  for i in 0..<64 {
    filter.area_cost[i] = 1.0  // Default cost
  }
  
  // Set specific area costs to match typical Detour usage
  filter.area_cost[WALKABLE_AREA] = 1.0   // Standard walkable cost
  filter.area_cost[AREA_WATER] = 10.0     // Water is more expensive
  filter.area_cost[AREA_DOOR] = 1.0       // Doors same as walkable
  filter.area_cost[AREA_GRASS] = 2.0      // Grass slightly more expensive
  
  return filter
}