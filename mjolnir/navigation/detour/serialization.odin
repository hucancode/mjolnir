package detour

import "core:log"
import "core:mem"

@(private = "file")
NAVMESH_FILE_MAGIC :: 'N' << 24 | 'A' << 16 | 'V' << 8 | 'M'
@(private = "file")
NAVMESH_FILE_VERSION :: 1

@(private = "file")
Nav_Mesh_File_Header :: struct {
  magic:      u32,
  version:    u32,
  tile_count: u32,
  params:     Nav_Mesh_Params,
}

@(private = "file")
Nav_Mesh_Tile_Entry :: struct {
  ref:       Tile_Ref,
  data_size: u32,
}

// save_navmesh encodes all tiles of nav_mesh in the .navmesh format, in memory the caller frees.
save_navmesh :: proc(nav_mesh: ^Nav_Mesh, allocator := context.allocator) -> []u8 {
  file_header := Nav_Mesh_File_Header {
    magic   = NAVMESH_FILE_MAGIC,
    version = NAVMESH_FILE_VERSION,
    params  = nav_mesh.params,
  }
  size := size_of(Nav_Mesh_File_Header)
  for i in 0 ..< nav_mesh.max_tiles {
    tile := &nav_mesh.tiles[i]
    if tile.header == nil || len(tile.data) == 0 do continue
    file_header.tile_count += 1
    size += size_of(Nav_Mesh_Tile_Entry) + len(tile.data)
  }
  data := make([]u8, size, allocator)
  at := copy(data, mem.ptr_to_bytes(&file_header))
  for i in 0 ..< nav_mesh.max_tiles {
    tile := &nav_mesh.tiles[i]
    if tile.header == nil || len(tile.data) == 0 do continue
    tile_entry := Nav_Mesh_Tile_Entry {
      ref       = get_tile_ref(nav_mesh, tile),
      data_size = u32(len(tile.data)),
    }
    at += copy(data[at:], mem.ptr_to_bytes(&tile_entry))
    at += copy(data[at:], tile.data)
  }
  log.infof("Saved navmesh with %d tiles (%d bytes)", file_header.tile_count, size)
  return data
}

// load_navmesh decodes a mesh encoded by save_navmesh; data is copied, the caller keeps it.
load_navmesh :: proc(data: []u8, allocator := context.allocator) -> (^Nav_Mesh, bool) {
  context.allocator = allocator
  file_header: Nav_Mesh_File_Header
  if copy(mem.ptr_to_bytes(&file_header), data) != size_of(Nav_Mesh_File_Header) {
    log.error("Navmesh data too short for its header")
    return nil, false
  }
  if file_header.magic != NAVMESH_FILE_MAGIC {
    log.errorf("Invalid navmesh file magic: 0x%08x", file_header.magic)
    return nil, false
  }
  if file_header.version != NAVMESH_FILE_VERSION {
    log.errorf("Unsupported navmesh file version: %d", file_header.version)
    return nil, false
  }
  nav_mesh := new(Nav_Mesh, allocator)
  init_status := nav_mesh_init(nav_mesh, &file_header.params)
  if !status_succeeded(init_status) {
    log.error("Failed to initialize navigation mesh")
    free(nav_mesh, allocator)
    return nil, false
  }
  at := size_of(Nav_Mesh_File_Header)
  for i in 0 ..< file_header.tile_count {
    tile_entry: Nav_Mesh_Tile_Entry
    if copy(mem.ptr_to_bytes(&tile_entry), data[at:]) != size_of(Nav_Mesh_Tile_Entry) ||
       len(data) - at - size_of(Nav_Mesh_Tile_Entry) < int(tile_entry.data_size) {
      log.errorf("Navmesh data truncated at tile %d", i)
      nav_mesh_destroy(nav_mesh)
      free(nav_mesh, allocator)
      return nil, false
    }
    at += size_of(Nav_Mesh_Tile_Entry)
    // the mesh frees its tiles (DT_TILE_FREE_DATA): each gets its own copy
    tile_data := make([]u8, tile_entry.data_size, allocator)
    at += copy(tile_data, data[at:])
    _, add_status := nav_mesh_add_tile(nav_mesh, tile_data, DT_TILE_FREE_DATA, tile_entry.ref)
    if !status_succeeded(add_status) {
      log.errorf("Failed to add tile %d to navigation mesh", i)
      delete(tile_data, allocator)
      nav_mesh_destroy(nav_mesh)
      free(nav_mesh, allocator)
      return nil, false
    }
  }
  log.infof("Loaded navmesh with %d tiles", file_header.tile_count)
  return nav_mesh, true
}

// load_navmesh_for_runtime decodes a mesh encoded by save_navmesh and initializes a query on it.
load_navmesh_for_runtime :: proc(
  data: []u8,
  allocator := context.allocator,
) -> (
  ^Nav_Mesh,
  ^Nav_Mesh_Query,
  bool,
) {
  context.allocator = allocator
  nav_mesh, load_ok := load_navmesh(data, allocator)
  if !load_ok {
    return nil, nil, false
  }
  query := new(Nav_Mesh_Query, allocator)
  max_nodes := 2048
  query_status := nav_mesh_query_init(query, nav_mesh, i32(max_nodes))
  if !status_succeeded(query_status) {
    nav_mesh_destroy(nav_mesh)
    free(nav_mesh, allocator)
    free(query, allocator)
    return nil, nil, false
  }
  return nav_mesh, query, true
}
