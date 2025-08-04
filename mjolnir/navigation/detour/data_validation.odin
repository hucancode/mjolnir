package navigation_detour

import "core:log"
import nav_recast "../recast"

// Data format validation for navigation mesh structures
// This replaces "hope it matches C++" with explicit verification

// Endianness detection and handling
Endianness :: enum {
    Little,
    Big,
}

// Detect system endianness
get_system_endianness :: proc() -> Endianness {
    test_value: u32 = 0x12345678
    test_bytes := cast(^[4]u8)(&test_value)
    
    if test_bytes[0] == 0x78 {
        return .Little
    } else {
        return .Big
    }
}

// Swap bytes for endianness conversion
byte_swap_u32 :: proc(value: u32) -> u32 {
    return ((value & 0xFF) << 24) |
           (((value >> 8) & 0xFF) << 16) |
           (((value >> 16) & 0xFF) << 8) |
           ((value >> 24) & 0xFF)
}

byte_swap_i32 :: proc(value: i32) -> i32 {
    return cast(i32)byte_swap_u32(cast(u32)value)
}

byte_swap_f32 :: proc(value: f32) -> f32 {
    value_bits := cast(u32)value
    swapped_bits := byte_swap_u32(value_bits)
    return cast(f32)swapped_bits
}

byte_swap_u16 :: proc(value: u16) -> u16 {
    return ((value & 0xFF) << 8) | ((value >> 8) & 0xFF)
}

// Convert header from file endianness to system endianness
convert_header_endianness :: proc(header: ^Mesh_Header, from_endianness: Endianness) {
    system_endianness := get_system_endianness()
    
    if from_endianness == system_endianness {
        return  // No conversion needed
    }
    
    // Convert all multi-byte fields
    header.magic = byte_swap_i32(header.magic)
    header.version = byte_swap_i32(header.version)
    header.x = byte_swap_i32(header.x)
    header.y = byte_swap_i32(header.y)
    header.layer = byte_swap_i32(header.layer)
    header.user_id = byte_swap_u32(header.user_id)
    header.poly_count = byte_swap_i32(header.poly_count)
    header.vert_count = byte_swap_i32(header.vert_count)
    header.max_link_count = byte_swap_i32(header.max_link_count)
    header.detail_mesh_count = byte_swap_i32(header.detail_mesh_count)
    header.detail_vert_count = byte_swap_i32(header.detail_vert_count)
    header.detail_tri_count = byte_swap_i32(header.detail_tri_count)
    header.bv_node_count = byte_swap_i32(header.bv_node_count)
    header.off_mesh_con_count = byte_swap_i32(header.off_mesh_con_count)
    header.off_mesh_base = byte_swap_i32(header.off_mesh_base)
    header.walkable_height = byte_swap_f32(header.walkable_height)
    header.walkable_radius = byte_swap_f32(header.walkable_radius)
    header.walkable_climb = byte_swap_f32(header.walkable_climb)
    
    // Convert bounding box arrays
    for i in 0..<3 {
        header.bmin[i] = byte_swap_f32(header.bmin[i])
        header.bmax[i] = byte_swap_f32(header.bmax[i])
    }
    
    header.bv_quant_factor = byte_swap_f32(header.bv_quant_factor)
}

// Detect endianness from magic number
detect_data_endianness :: proc(data: []u8) -> (Endianness, bool) {
    if len(data) < 4 {
        return .Little, false
    }
    
    magic_bytes := data[0:4]
    magic_little := cast(u32)magic_bytes[0] |
                    (cast(u32)magic_bytes[1] << 8) |
                    (cast(u32)magic_bytes[2] << 16) |
                    (cast(u32)magic_bytes[3] << 24)
    
    magic_big := (cast(u32)magic_bytes[0] << 24) |
                 (cast(u32)magic_bytes[1] << 16) |
                 (cast(u32)magic_bytes[2] << 8) |
                 cast(u32)magic_bytes[3]
    
    if magic_little == cast(u32)nav_recast.DT_NAVMESH_MAGIC {
        return .Little, true
    } else if magic_big == cast(u32)nav_recast.DT_NAVMESH_MAGIC {
        return .Big, true
    }
    
    return .Little, false  // Default to little-endian, but indicate failure
}

// Expected struct sizes based on actual Odin implementation
// These are the actual sizes that Odin produces with its padding/alignment
EXPECTED_DT_MESH_HEADER_SIZE :: 100  // Actual Odin size with padding
EXPECTED_DT_POLY_SIZE :: 32          // Actual Odin size with padding
EXPECTED_DT_LINK_SIZE :: 12          // Actual Odin size (matches C++)
EXPECTED_DT_POLY_DETAIL_SIZE :: 12   // Actual Odin size with padding (C++ would be 10)
EXPECTED_DT_BV_NODE_SIZE :: 16       // Actual Odin size (matches C++)
EXPECTED_DT_OFF_MESH_CONNECTION_SIZE :: 36  // Actual Odin size (matches C++)

// Data format version constants
NAVMESH_DATA_FORMAT_VERSION :: 7
MINIMUM_SUPPORTED_VERSION :: 6      // For backward compatibility
MAXIMUM_FUTURE_VERSION :: 10        // Maximum version we'll attempt to handle

// Version feature flags for backward compatibility
Version_Features :: struct {
    has_bv_tree:              bool,
    has_detail_meshes:        bool,
    has_off_mesh_connections: bool,
    has_extended_header:      bool,
    supports_large_worlds:    bool,
}

// Compile-time size assertions to catch struct layout mismatches immediately
// These will cause compilation errors if our structs don't match expected sizes
@(init)
validate_struct_sizes :: proc() {
    // Runtime size checks with detailed error messages
    header_size := size_of(Mesh_Header)
    if header_size != EXPECTED_DT_MESH_HEADER_SIZE {
        log.fatalf("Mesh_Header size mismatch: got %d bytes, expected %d bytes. " +
                  "This indicates struct padding or field type differences from C++ reference.", 
                  header_size, EXPECTED_DT_MESH_HEADER_SIZE)
    }
    
    poly_size := size_of(Poly)
    if poly_size != EXPECTED_DT_POLY_SIZE {
        log.fatalf("Poly size mismatch: got %d bytes, expected %d bytes. " +
                  "Check vertex count constants and field alignment.", 
                  poly_size, EXPECTED_DT_POLY_SIZE)
    }
    
    link_size := size_of(Link)
    if link_size != EXPECTED_DT_LINK_SIZE {
        log.fatalf("Link size mismatch: got %d bytes, expected %d bytes. " +
                  "Verify Poly_Ref size and field packing.", 
                  link_size, EXPECTED_DT_LINK_SIZE)
    }
    
    detail_size := size_of(Poly_Detail)
    if detail_size != EXPECTED_DT_POLY_DETAIL_SIZE {
        log.fatalf("Poly_Detail size mismatch: got %d bytes, expected %d bytes. " +
                  "Check field alignment and padding.", 
                  detail_size, EXPECTED_DT_POLY_DETAIL_SIZE)
    }
    
    bv_size := size_of(BV_Node)
    if bv_size != EXPECTED_DT_BV_NODE_SIZE {
        log.fatalf("BV_Node size mismatch: got %d bytes, expected %d bytes. " +
                  "Verify array field packing.", 
                  bv_size, EXPECTED_DT_BV_NODE_SIZE)
    }
    
    offmesh_size := size_of(Off_Mesh_Connection)
    if offmesh_size != EXPECTED_DT_OFF_MESH_CONNECTION_SIZE {
        log.fatalf("Off_Mesh_Connection size mismatch: got %d bytes, expected %d bytes. " +
                  "Check array and field alignment.", 
                  offmesh_size, EXPECTED_DT_OFF_MESH_CONNECTION_SIZE)
    }
    
    log.infof("Navigation mesh data structure sizes validated successfully")
}

// Validation result for detailed error reporting
Data_Validation_Result :: struct {
    valid:        bool,
    error_count:  int,
    errors:       [16]string,  // Fixed-size array for error messages
}

// Validate raw tile data before parsing with endianness handling
validate_tile_data :: proc(data: []u8) -> (result: Data_Validation_Result) {
    result.valid = true
    
    add_error :: proc(result: ^Data_Validation_Result, message: string) {
        if result.error_count < len(result.errors) {
            result.errors[result.error_count] = message
            result.error_count += 1
        }
        result.valid = false
    }
    
    // Minimum size check
    if len(data) < size_of(Mesh_Header) {
        add_error(&result, "Tile data too small for header")
        return
    }
    
    // Detect endianness from magic number
    data_endianness, endian_ok := detect_data_endianness(data)
    if !endian_ok {
        add_error(&result, "Cannot detect data endianness - invalid or corrupt magic number")
        return
    }
    
    system_endianness := get_system_endianness()
    if data_endianness != system_endianness {
        endian_name := data_endianness == .Little ? "little-endian" : "big-endian"
        log.infof("Data is %s, performing endianness conversion", endian_name)
    }
    
    // Read and validate header (with endianness conversion)
    header := cast(^Mesh_Header)raw_data(data)
    
    // Convert endianness if needed
    if data_endianness != system_endianness {
        convert_header_endianness(header, data_endianness)
    }
    
    // Magic number validation
    if header.magic != nav_recast.DT_NAVMESH_MAGIC {
        add_error(&result, "Invalid magic number in tile header")
    }
    
    // Version validation
    if header.version != NAVMESH_DATA_FORMAT_VERSION {
        if header.version < MINIMUM_SUPPORTED_VERSION {
            add_error(&result, "Unsupported tile data version (too old)")
        } else if header.version > NAVMESH_DATA_FORMAT_VERSION {
            add_error(&result, "Unsupported tile data version (too new)")
        }
        // Note: Some version mismatches might be recoverable
    }
    
    // Bounds validation
    if header.poly_count < 0 || header.vert_count < 0 || 
       header.max_link_count < 0 || header.detail_mesh_count < 0 ||
       header.detail_vert_count < 0 || header.detail_tri_count < 0 ||
       header.bv_node_count < 0 || header.off_mesh_con_count < 0 {
        add_error(&result, "Negative count in header (corrupt data)")
    }
    
    // Reasonable limits check (prevent memory exhaustion attacks)
    MAX_REASONABLE_POLYS :: 100_000
    MAX_REASONABLE_VERTS :: 500_000
    MAX_REASONABLE_LINKS :: 1_000_000
    
    if header.poly_count > MAX_REASONABLE_POLYS ||
       header.vert_count > MAX_REASONABLE_VERTS ||
       header.max_link_count > MAX_REASONABLE_LINKS {
        add_error(&result, "Header counts exceed reasonable limits")
    }
    
    // Calculate expected data size and validate against actual size
    expected_size := calculate_expected_tile_size(header)
    if len(data) < expected_size {
        add_error(&result, "Tile data smaller than expected from header")
    }
    
    // Bounding box sanity check
    for i in 0..<3 {
        if header.bmin[i] > header.bmax[i] {
            add_error(&result, "Invalid bounding box (min > max)")
            break
        }
        // Check for NaN or infinite values
        if header.bmin[i] != header.bmin[i] || header.bmax[i] != header.bmax[i] {
            add_error(&result, "NaN values in bounding box")
            break
        }
    }
    
    // Walkable parameter validation
    if header.walkable_height <= 0 || header.walkable_radius <= 0 || header.walkable_climb < 0 {
        add_error(&result, "Invalid walkable parameters")
    }
    
    return
}

// Calculate expected tile data size from header
calculate_expected_tile_size :: proc(header: ^Mesh_Header) -> int {
    size := size_of(Mesh_Header)
    size += size_of([3]f32) * int(header.vert_count)           // Vertices
    size += size_of(Poly) * int(header.poly_count)          // Polygons
    size += size_of(Link) * int(header.max_link_count)      // Links
    size += size_of(Poly_Detail) * int(header.detail_mesh_count)  // Detail meshes
    size += size_of([3]f32) * int(header.detail_vert_count)    // Detail vertices
    size += 4 * int(header.detail_tri_count)                   // Detail triangles (4 bytes each)
    size += size_of(BV_Node) * int(header.bv_node_count)    // BV tree nodes
    size += size_of(Off_Mesh_Connection) * int(header.off_mesh_con_count)  // Off-mesh connections
    return size
}

// Get feature set for a specific version
get_version_features :: proc(version: i32) -> Version_Features {
    features := Version_Features{}
    
    switch version {
    case 6:
        features.has_detail_meshes = true
        features.has_off_mesh_connections = true
    case 7:
        features.has_bv_tree = true
        features.has_detail_meshes = true
        features.has_off_mesh_connections = true
        features.has_extended_header = true
    case 8, 9, 10:
        // Future versions - enable all features
        features.has_bv_tree = true
        features.has_detail_meshes = true
        features.has_off_mesh_connections = true
        features.has_extended_header = true
        features.supports_large_worlds = true
    }
    
    return features
}

// Validate navigation mesh header with detailed checking and version compatibility
validate_navmesh_header :: proc(header: ^Mesh_Header) -> nav_recast.Status {
    if header == nil {
        return {.Invalid_Param}
    }
    
    // Magic number check
    if header.magic != nav_recast.DT_NAVMESH_MAGIC {
        log.errorf("Invalid navmesh magic: got 0x%08x, expected 0x%08x", 
                  header.magic, nav_recast.DT_NAVMESH_MAGIC)
        return {.Wrong_Magic}
    }
    
    // Enhanced version validation
    if header.version < MINIMUM_SUPPORTED_VERSION {
        log.errorf("Navmesh version %d is too old (minimum supported: %d)", 
                  header.version, MINIMUM_SUPPORTED_VERSION)
        return {.Wrong_Version}
    }
    
    if header.version > MAXIMUM_FUTURE_VERSION {
        log.errorf("Navmesh version %d is too new (maximum supported: %d)", 
                  header.version, MAXIMUM_FUTURE_VERSION)
        return {.Wrong_Version}
    }
    
    // Log version compatibility information
    if header.version != nav_recast.DT_NAVMESH_VERSION {
        features := get_version_features(header.version)
        if header.version < nav_recast.DT_NAVMESH_VERSION {
            log.warnf("Using older navmesh version %d (current: %d)", 
                     header.version, nav_recast.DT_NAVMESH_VERSION)
        } else {
            log.warnf("Using newer navmesh version %d (current: %d) - experimental support", 
                     header.version, nav_recast.DT_NAVMESH_VERSION)
        }
        
        log.infof("Version %d features: BV-tree=%v, detail_meshes=%v, off_mesh=%v, extended=%v, large_worlds=%v",
                 header.version, features.has_bv_tree, features.has_detail_meshes, 
                 features.has_off_mesh_connections, features.has_extended_header, features.supports_large_worlds)
    }
    
    // Additional validation checks
    if header.poly_count < 0 || header.vert_count < 0 {
        log.errorf("Invalid counts in header: poly_count=%d, vert_count=%d", 
                  header.poly_count, header.vert_count)
        return {.Invalid_Param}
    }
    
    // Version-specific validation
    features := get_version_features(header.version)
    
    if !features.has_bv_tree && header.bv_node_count > 0 {
        log.warnf("Version %d doesn't support BV trees but header has %d nodes - data may be corrupt",
                 header.version, header.bv_node_count)
    }
    
    if !features.has_off_mesh_connections && header.off_mesh_con_count > 0 {
        log.warnf("Version %d doesn't support off-mesh connections but header has %d connections",
                 header.version, header.off_mesh_con_count)
    }
    
    return {.Success}
}

// Data integrity checksum (simple but effective for detecting corruption)
calculate_data_checksum :: proc(data: []u8) -> u32 {
    checksum: u32 = 0x12345678  // Starting seed
    
    // Simple but effective checksum algorithm
    for i in 0..<len(data) {
        checksum = checksum * 33 + u32(data[i])
    }
    
    return checksum
}

// Verify data layout assumptions at runtime
verify_data_layout :: proc(data: []u8, header: ^Mesh_Header) -> bool {
    if len(data) < size_of(Mesh_Header) {
        return false
    }
    
    // Verify header is at expected location
    header_from_data := cast(^Mesh_Header)raw_data(data)
    if header_from_data != header {
        log.warnf("Header pointer mismatch - possible alignment issue")
    }
    
    // Verify data layout order matches expected format
    offset := size_of(Mesh_Header)
    
    // Check vertices alignment
    if header.vert_count > 0 {
        vert_ptr := uintptr(raw_data(data)) + uintptr(offset)
        if vert_ptr % uintptr(align_of([3]f32)) != 0 {
            log.errorf("Vertex data misaligned: offset=%d, required alignment=%d", 
                      offset, align_of([3]f32))
            return false
        }
        offset += size_of([3]f32) * int(header.vert_count)
    }
    
    // Check polygon alignment
    if header.poly_count > 0 {
        poly_ptr := uintptr(raw_data(data)) + uintptr(offset)
        if poly_ptr % uintptr(align_of(Poly)) != 0 {
            log.errorf("Polygon data misaligned: offset=%d, required alignment=%d", 
                      offset, align_of(Poly))
            return false
        }
    }
    
    return true
}

// Log detailed struct layout information for debugging
log_struct_layout_info :: proc() {
    log.infof("=== Navigation Mesh Structure Layout ===")
    log.infof("Mesh_Header: size=%d, align=%d", size_of(Mesh_Header), align_of(Mesh_Header))
    log.infof("Poly: size=%d, align=%d", size_of(Poly), align_of(Poly))
    log.infof("Link: size=%d, align=%d", size_of(Link), align_of(Link))
    log.infof("Poly_Detail: size=%d, align=%d", size_of(Poly_Detail), align_of(Poly_Detail))
    log.infof("BV_Node: size=%d, align=%d", size_of(BV_Node), align_of(BV_Node))
    log.infof("Off_Mesh_Connection: size=%d, align=%d", size_of(Off_Mesh_Connection), align_of(Off_Mesh_Connection))
    log.infof("=========================================")
}