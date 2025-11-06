package navigation_recast

get_dir_offset_x :: proc "contextless" (dir: int) -> i32 {
  offset := [4]i32{-1, 0, 1, 0}
  return offset[dir & 0x03]
}

get_dir_offset_y :: proc "contextless" (dir: int) -> i32 {
  offset := [4]i32{0, 1, 0, -1}
  return offset[dir & 0x03]
}
Partition_Type :: enum {
  Watershed,
  Monotone,
  Layers,
}

Off_Mesh_Connection_Verts :: struct {
  start: [3]f32,
  end:   [3]f32,
}

Contour :: struct {
  verts:  [][4]i32,
  rverts: [][4]i32,
  reg:    u16,
  area:   u8,
}

Contour_Set :: struct {
  conts:       [dynamic]Contour,
  bmin:        [3]f32,
  bmax:        [3]f32,
  cs:          f32,
  ch:          f32,
  width:       i32,
  height:      i32,
  border_size: i32,
  max_error:   f32,
}

Poly_Mesh :: struct {
  verts:          [][3]u16,
  polys:          []u16,
  regs:           []u16,
  flags:          []u16,
  areas:          []u8,
  npolys:         i32,
  maxpolys:       i32,
  nvp:            i32,
  bmin:           [3]f32,
  bmax:           [3]f32,
  cs:             f32,
  ch:             f32,
  border_size:    i32,
  max_edge_error: f32,
}

Poly_Mesh_Detail :: struct {
  meshes: [][4]u32,
  verts:  [][3]f32,
  tris:   [][4]u8,
}

Edge :: struct {
  vert:      [2]u16,
  poly:      [2]u16,
  poly_edge: [2]u16,
}

Potential_Diagonal :: struct {
  vert: i32,
  dist: i32,
}

Layer_Region :: struct {
  id:       u8,
  layer_id: u8,
  base:     bool,
  ymin:     u16,
  ymax:     u16,
  layers:   [RC_MAX_LAYERS]u8,
  nlayers:  u8,
}

Build_Context :: struct {
  solid: ^Heightfield,
  chf:   ^Compact_Heightfield,
  cset:  ^Contour_Set,
  pmesh: ^Poly_Mesh,
  dmesh: ^Poly_Mesh_Detail,
  cfg:   Config,
}

Heightfield_Layer :: struct {
  bmin:    [3]f32,
  bmax:    [3]f32,
  cs:      f32,
  ch:      f32,
  width:   i32,
  height:  i32,
  minx:    i32,
  maxx:    i32,
  miny:    i32,
  maxy:    i32,
  hmin:    i32,
  hmax:    i32,
  heights: []u8,
  areas:   []u8,
  cons:    []u8,
}

create_poly_mesh :: proc(cset: ^Contour_Set, nvp: i32) -> ^Poly_Mesh {
  pmesh := new(Poly_Mesh)
  if !build_poly_mesh(cset, nvp, pmesh) {
    free_poly_mesh(pmesh)
    return nil
  }
  return pmesh
}

free_poly_mesh :: proc(pmesh: ^Poly_Mesh) {
  if pmesh == nil do return
  delete(pmesh.verts)
  delete(pmesh.polys)
  delete(pmesh.regs)
  delete(pmesh.flags)
  delete(pmesh.areas)
  free(pmesh)
}

create_poly_mesh_detail :: proc(
  pmesh: ^Poly_Mesh,
  chf: ^Compact_Heightfield,
  sample_dist, sample_max_error: f32,
) -> ^Poly_Mesh_Detail {
  dmesh := new(Poly_Mesh_Detail)
  if !build_poly_mesh_detail(
    pmesh,
    chf,
    sample_dist,
    sample_max_error,
    dmesh,
  ) {
    free_poly_mesh_detail(dmesh)
    return nil
  }
  return dmesh
}

free_poly_mesh_detail :: proc(dmesh: ^Poly_Mesh_Detail) {
  if dmesh == nil do return
  delete(dmesh.meshes)
  delete(dmesh.verts)
  delete(dmesh.tris)
  free(dmesh)
}

RC_COMPRESSION :: true
RC_LARGE_WORLDS :: true

RC_LEDGE_BORDER :: 0x1
RC_LEDGE_WALKABLE :: 0x2

RC_MESH_FLAG_16BIT_INDICES :: 1 << 0

DT_DETAIL_EDGE_BOUNDARY :: 0x01

DT_TILE_FREE_DATA :: 0x01

DT_OFFMESH_CON_BIDIR :: 1

DT_POLYTYPE_GROUND :: 0
DT_POLYTYPE_OFFMESH_CONNECTION :: 1

DT_FINDPATH_ANY_ANGLE :: 0x02

DT_RAYCAST_USE_COSTS :: 0x01

DT_STRAIGHTPATH_AREA_CROSSINGS :: 0x01
DT_STRAIGHTPATH_ALL_CROSSINGS :: 0x02

DT_VERTS_PER_POLYGON :: 6
DT_NAVMESH_MAGIC :: 'D' << 24 | 'N' << 16 | 'A' << 8 | 'V'
DT_NAVMESH_VERSION :: 7
DT_NAVMESH_STATE_MAGIC :: 'D' << 24 | 'N' << 16 | 'M' << 8 | 'S'
DT_NAVMESH_STATE_VERSION :: 1

DT_MAX_AREAS :: 64

DEFAULT_MAX_PATH :: 256
DEFAULT_MAX_POLYGONS :: 256
DEFAULT_MAX_SMOOTH :: 2048

DT_CROWDAGENT_STATE_INVALID :: 0
DT_CROWDAGENT_STATE_WALKING :: 1
DT_CROWDAGENT_STATE_OFFMESH :: 2

DT_CROWDAGENT_TARGET_NONE :: 0
DT_CROWDAGENT_TARGET_FAILED :: 1
DT_CROWDAGENT_TARGET_VALID :: 2
DT_CROWDAGENT_TARGET_REQUESTING :: 3
DT_CROWDAGENT_TARGET_WAITING_FOR_QUEUE :: 4
DT_CROWDAGENT_TARGET_WAITING_FOR_PATH :: 5
DT_CROWDAGENT_TARGET_VELOCITY :: 6

DT_CROWDAGENT_TARGET_ADJUSTED :: 16

DT_MAX_PATTERN_DIVS :: 32
DT_MAX_PATTERN_RINGS :: 4

SAMPLE_POLYAREA_NULL :: 0
SAMPLE_POLYAREA_GROUND :: 1
SAMPLE_POLYAREA_WATER :: 2
SAMPLE_POLYAREA_DOOR :: 3
SAMPLE_POLYAREA_GRASS :: 4
SAMPLE_POLYAREA_JUMP :: 5
SAMPLE_POLYAREA_LADDER :: 6

DT_TILECACHE_MAGIC :: 'D' << 24 | 'T' << 16 | 'L' << 8 | 'R'
DT_TILECACHE_VERSION :: 1
DT_TILECACHE_NULL_AREA :: 0
DT_TILECACHE_WALKABLE_AREA :: 63
DT_TILECACHE_NULL_IDX :: 0xffff

DT_COMPRESSEDTILE_FREE_DATA :: 0x01

DT_LAYER_MAX_NEIS :: 16

RC_MAX_LAYERS :: 32

RC_SPAN_HEIGHT_BITS :: 13
RC_SPAN_MAX_HEIGHT :: (1 << RC_SPAN_HEIGHT_BITS) - 1
RC_SPANS_PER_POOL :: 2048

RC_NULL_AREA :: 0
RC_WALKABLE_AREA :: 63
RC_NOT_CONNECTED :: 0x3f

RC_BORDER_REG :: 0x8000
RC_MULTIPLE_REGS :: 0
RC_BORDER_VERTEX :: 0x10000
RC_AREA_BORDER :: 0x20000
RC_CONTOUR_REG_MASK :: 0xffff
RC_MESH_NULL_IDX :: 0xffff
Contour_Tess_Flag :: enum {
  WALL_EDGES = 0,
  AREA_EDGES = 1,
}
Contour_Tess_Flags :: bit_set[Contour_Tess_Flag;u32]

Vertex_Flag :: enum {
  BORDER_VERTEX = 16,
  AREA_BORDER   = 17,
}
Vertex_Flags :: bit_set[Vertex_Flag;u32]

DT_NULL_LINK :: 0xffffffff
INVALID_POLY_REF :: Poly_Ref(0)
INVALID_TILE_REF :: Tile_Ref(0)

Poly_Ref :: distinct u32
Tile_Ref :: distinct u32
Agent_Id :: distinct u32
Obstacle_Ref :: distinct u32

Status_Flag :: enum u32 {
  Success          = 0,
  In_Progress      = 1,
  Partial_Result   = 2,
  Wrong_Magic      = 16,
  Wrong_Version    = 17,
  Out_Of_Memory    = 18,
  Invalid_Param    = 19,
  Buffer_Too_Small = 20,
  Out_Of_Nodes     = 21,
  Partial_Path     = 22,
}

Status :: bit_set[Status_Flag;u32]

status_succeeded :: proc "contextless" (status: Status) -> bool {
  return(
    Status_Flag.Success in status &&
    card(
      status &
      {
          .Wrong_Magic,
          .Wrong_Version,
          .Out_Of_Memory,
          .Invalid_Param,
          .Buffer_Too_Small,
          .Out_Of_Nodes,
        },
    ) ==
      0 \
  )
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

Config :: struct {
  width:                    i32,
  height:                   i32,
  tile_size:                i32,
  border_size:              i32,
  cs:                       f32,
  ch:                       f32,
  bmin:                     [3]f32,
  bmax:                     [3]f32,
  walkable_slope_angle:     f32,
  walkable_height:          i32,
  walkable_climb:           i32,
  walkable_radius:          i32,
  max_edge_len:             i32,
  max_simplification_error: f32,
  min_region_area:          i32,
  merge_region_area:        i32,
  max_verts_per_poly:       i32,
  detail_sample_dist:       f32,
  detail_sample_max_error:  f32,
}
build_navmesh :: proc(
  vertices: [][3]f32,
  indices: []i32,
  areas: []u8,
  cfg: Config,
) -> (
  pmesh: ^Poly_Mesh,
  dmesh: ^Poly_Mesh_Detail,
  ok: bool,
) {
  if len(vertices) == 0 || len(indices) == 0 || cfg.cs <= 0 || cfg.ch <= 0 {
    return
  }
  config := cfg
  if config.bmin == {} && config.bmax == {} {
    config.bmin, config.bmax = calc_bounds(vertices)
  }
  config.width, config.height = calc_grid_size(
    config.bmin,
    config.bmax,
    config.cs,
  )
  if config.width <= 0 || config.height <= 0 {
    return
  }
  hf := create_heightfield(
    config.width,
    config.height,
    config.bmin,
    config.bmax,
    config.cs,
    config.ch,
  )
  defer free_heightfield(hf)
  rasterize_triangles(
    vertices,
    indices,
    areas,
    hf,
    config.walkable_climb,
  ) or_return
  filter_low_hanging_walkable_obstacles(int(config.walkable_climb), hf)
  filter_ledge_spans(
    int(config.walkable_height),
    int(config.walkable_climb),
    hf,
  )
  filter_walkable_low_height_spans(int(config.walkable_height), hf)
  chf := create_compact_heightfield(
    config.walkable_height,
    config.walkable_climb,
    hf,
  )
  if chf == nil do return
  defer free_compact_heightfield(chf)
  erode_walkable_area(config.walkable_radius, chf) or_return
  build_distance_field(chf) or_return
  build_regions(
    chf,
    0,
    config.min_region_area,
    config.merge_region_area,
  ) or_return
  cset := create_contour_set(
    chf,
    config.max_simplification_error,
    config.max_edge_len,
  )
  if cset == nil do return
  defer free_contour_set(cset)
  pmesh = create_poly_mesh(cset, config.max_verts_per_poly)
  if pmesh == nil {
    return
  }
  dmesh = create_poly_mesh_detail(
    pmesh,
    chf,
    config.detail_sample_dist,
    config.detail_sample_max_error,
  )
  if dmesh == nil {
    free_poly_mesh(pmesh)
    return
  }
  return pmesh, dmesh, true
}
