package detour

import "core:log"
import "core:os"

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

// save_navmesh_to_file writes all tiles of nav_mesh to filepath.
save_navmesh_to_file :: proc(nav_mesh: ^Nav_Mesh, filepath: string) -> bool {
  file, err := os.open(filepath, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.perm(0o644))
  if err != os.ERROR_NONE {
    log.errorf("Failed to create navmesh file: %s", filepath)
    return false
  }
  defer os.close(file)
  tile_count := u32(0)
  for i in 0 ..< nav_mesh.max_tiles {
    tile := &nav_mesh.tiles[i]
    if tile.header != nil && len(tile.data) > 0 {
      tile_count += 1
    }
  }
  file_header := Nav_Mesh_File_Header {
    magic      = NAVMESH_FILE_MAGIC,
    version    = NAVMESH_FILE_VERSION,
    tile_count = tile_count,
    params     = nav_mesh.params,
  }
  _, err = os.write_ptr(file, &file_header, size_of(Nav_Mesh_File_Header))
  if err != os.ERROR_NONE {
    log.error("Failed to write navmesh file header")
    return false
  }
  for i in 0 ..< nav_mesh.max_tiles {
    tile := &nav_mesh.tiles[i]
    if tile.header == nil || len(tile.data) <= 0 do continue
    tile_ref := get_tile_ref(nav_mesh, tile)
    tile_entry := Nav_Mesh_Tile_Entry {
      ref       = tile_ref,
      data_size = u32(len(tile.data)),
    }
    bytes_written, err := os.write_ptr(
      file,
      &tile_entry,
      size_of(Nav_Mesh_Tile_Entry),
    )
    if err != os.ERROR_NONE || bytes_written != size_of(Nav_Mesh_Tile_Entry) {
      log.errorf("Failed to write tile entry for tile %d", i)
      return false
    }
    bytes_written, err = os.write(file, tile.data)
    if err != os.ERROR_NONE || bytes_written != len(tile.data) {
      log.errorf("Failed to write tile data for tile %d", i)
      return false
    }
  }
  log.infof("Saved navmesh with %d tiles to: %s", tile_count, filepath)
  return true
}

// load_navmesh_from_file reads a mesh written by save_navmesh_to_file.
load_navmesh_from_file :: proc(
  filepath: string,
  allocator := context.allocator,
) -> (
  ^Nav_Mesh,
  bool,
) {
  context.allocator = allocator
  file, err := os.open(filepath, os.O_RDONLY)
  if err != os.ERROR_NONE {
    log.errorf("Failed to open navmesh file: %s", filepath)
    return nil, false
  }
  defer os.close(file)
  file_header: Nav_Mesh_File_Header
  _, err = os.read_ptr(file, &file_header, size_of(Nav_Mesh_File_Header))
  if err != os.ERROR_NONE {
    log.error("Failed to read navmesh file header")
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
  tiles_loaded := u32(0)
  for i in 0 ..< file_header.tile_count {
    tile_entry: Nav_Mesh_Tile_Entry
    bytes_read, err := os.read_ptr(
      file,
      &tile_entry,
      size_of(Nav_Mesh_Tile_Entry),
    )
    if err != os.ERROR_NONE || bytes_read != size_of(Nav_Mesh_Tile_Entry) {
      log.errorf("Failed to read tile entry %d", i)
      nav_mesh_destroy(nav_mesh)
      free(nav_mesh, allocator)
      return nil, false
    }
    tile_data := make([]u8, tile_entry.data_size, allocator)
    bytes_read, err = os.read(file, tile_data)
    if err != os.ERROR_NONE || bytes_read != len(tile_data) {
      log.errorf("Failed to read tile data for tile %d", i)
      delete(tile_data, allocator)
      nav_mesh_destroy(nav_mesh)
      free(nav_mesh, allocator)
      return nil, false
    }
    _, add_status := nav_mesh_add_tile(
      nav_mesh,
      tile_data,
      DT_TILE_FREE_DATA,
      tile_entry.ref,
    )
    if !status_succeeded(add_status) {
      log.errorf("Failed to add tile %d to navigation mesh", i)
      delete(tile_data, allocator)
      nav_mesh_destroy(nav_mesh)
      free(nav_mesh, allocator)
      return nil, false
    }
    tiles_loaded += 1
  }
  log.infof("Loaded navmesh with %d tiles from: %s", tiles_loaded, filepath)
  return nav_mesh, true
}

// save_navmesh_data_to_file writes raw single-tile data to filepath.
save_navmesh_data_to_file :: proc(data: []u8, filepath: string) -> bool {
  file, err := os.open(filepath, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.perm(0o644))
  if err != os.ERROR_NONE {
    log.errorf("Failed to create navmesh data file: %s", filepath)
    return false
  }
  defer os.close(file)
  _, err = os.write(file, data)
  if err != os.ERROR_NONE {
    log.error("Failed to write navmesh data")
    return false
  }
  log.infof("Saved navmesh data (%d bytes) to: %s", len(data), filepath)
  return true
}

// load_navmesh_data_from_file reads raw single-tile data written by save_navmesh_data_to_file.
load_navmesh_data_from_file :: proc(
  filepath: string,
  allocator := context.allocator,
) -> (
  []u8,
  bool,
) {
  context.allocator = allocator
  data, read_err := os.read_entire_file(filepath, allocator)
  if read_err != nil {
    log.errorf("Failed to read navmesh data file: %s", filepath)
    return nil, false
  }
  log.infof("Loaded navmesh data (%d bytes) from: %s", len(data), filepath)
  return data, true
}

// load_navmesh_for_runtime loads a mesh from filepath and initializes a query on it.
load_navmesh_for_runtime :: proc(
  filepath: string,
  allocator := context.allocator,
) -> (
  ^Nav_Mesh,
  ^Nav_Mesh_Query,
  bool,
) {
  context.allocator = allocator
  nav_mesh, load_ok := load_navmesh_from_file(filepath, allocator)
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
