package detour

@(private = "file")
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

// Status is a set of result flags; test it with status_succeeded and friends.
Status :: bit_set[Status_Flag;u32]

// status_succeeded reports whether status has Success and no failure flag.
status_succeeded :: proc "contextless" (status: Status) -> bool {
  return(
    .Success in status &&
    .Wrong_Magic not_in status &&
    .Wrong_Version not_in status &&
    .Out_Of_Memory not_in status &&
    .Invalid_Param not_in status &&
    .Buffer_Too_Small not_in status &&
    .Out_Of_Nodes not_in status \
  )
}

// status_failed reports whether status carries any failure flag.
status_failed :: proc "contextless" (status: Status) -> bool {
  return(
    .Wrong_Magic in status ||
    .Wrong_Version in status ||
    .Out_Of_Memory in status ||
    .Invalid_Param in status ||
    .Buffer_Too_Small in status ||
    .Out_Of_Nodes in status \
  )
}

// status_in_progress reports whether a sliced operation is still running.
status_in_progress :: proc "contextless" (status: Status) -> bool {
  return .In_Progress in status
}

// status_detail splits status into its success bool and the remaining detail flags.
status_detail :: proc "contextless" (status: Status) -> (succeeded: bool, detail: Status) {
  succeeded = status_succeeded(status)
  detail = status - {.Success}
  return
}

// DEFAULT_MAX_PATH is the default capacity for polygon path buffers.
DEFAULT_MAX_PATH :: 256

// Poly_Ref is an opaque handle to a polygon (tile salt, tile index, polygon index).
Poly_Ref :: distinct u32
@(private)
Tile_Ref :: distinct u32

// INVALID_POLY_REF is the null polygon handle.
INVALID_POLY_REF :: Poly_Ref(0)
@(private)
INVALID_TILE_REF :: Tile_Ref(0)
// DT_NULL_LINK marks the end of a polygon link list.
DT_NULL_LINK :: 0xffffffff

// DT_VERTS_PER_POLYGON is the maximum vertex count of a navmesh polygon.
DT_VERTS_PER_POLYGON :: 6
@(private)
DT_MAX_AREAS :: 64
// DT_POLYTYPE_GROUND is the polygon type of regular walkable polygons.
DT_POLYTYPE_GROUND :: 0
// DT_POLYTYPE_OFFMESH_CONNECTION is the polygon type of off-mesh link polygons.
DT_POLYTYPE_OFFMESH_CONNECTION :: 1

// DT_TILE_FREE_DATA is the nav_mesh_add_tile flag that lets the mesh free the tile data.
DT_TILE_FREE_DATA :: 0x01
// DT_OFFMESH_CON_BIDIR is the off-mesh connection flag for two-way links.
DT_OFFMESH_CON_BIDIR :: 1
// DT_RAYCAST_USE_COSTS is the raycast option that accumulates path cost.
DT_RAYCAST_USE_COSTS :: 0x01

// DT_NAVMESH_MAGIC identifies serialized navmesh tile data.
DT_NAVMESH_MAGIC :: 'D' << 24 | 'N' << 16 | 'A' << 8 | 'V'
// DT_NAVMESH_VERSION is the serialized tile format version.
DT_NAVMESH_VERSION :: 7
@(private = "file")
DT_NAVMESH_STATE_MAGIC :: 'D' << 24 | 'N' << 16 | 'M' << 8 | 'S'
@(private = "file")
DT_NAVMESH_STATE_VERSION :: 1
