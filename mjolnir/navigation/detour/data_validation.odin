package navigation_detour

import "core:log"
import "../recast"

Endianness :: enum {
    Little,
    Big,
}

get_system_endianness :: proc() -> Endianness {
    test_value: u32 = 0x12345678
    test_bytes := cast(^[4]u8)(&test_value)

    if test_bytes[0] == 0x78 {
        return .Little
    } else {
        return .Big
    }
}

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

convert_header_endianness :: proc(header: ^Mesh_Header, from_endianness: Endianness) {
    system_endianness := get_system_endianness()

    if from_endianness == system_endianness do return

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

    for i in 0..<3 {
        header.bmin[i] = byte_swap_f32(header.bmin[i])
        header.bmax[i] = byte_swap_f32(header.bmax[i])
    }

    header.bv_quant_factor = byte_swap_f32(header.bv_quant_factor)
}

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

    if magic_little == cast(u32)recast.DT_NAVMESH_MAGIC {
        return .Little, true
    } else if magic_big == cast(u32)recast.DT_NAVMESH_MAGIC {
        return .Big, true
    }

    return .Little, false
}

EXPECTED_DT_MESH_HEADER_SIZE :: 100
EXPECTED_DT_POLY_SIZE :: 32
EXPECTED_DT_LINK_SIZE :: 12
EXPECTED_DT_POLY_DETAIL_SIZE :: 12
EXPECTED_DT_BV_NODE_SIZE :: 16
EXPECTED_DT_OFF_MESH_CONNECTION_SIZE :: 36

NAVMESH_DATA_FORMAT_VERSION :: 7
MINIMUM_SUPPORTED_VERSION :: 6
MAXIMUM_FUTURE_VERSION :: 10

Version_Features :: struct {
    has_bv_tree:              bool,
    has_detail_meshes:        bool,
    has_off_mesh_connections: bool,
    has_extended_header:      bool,
    supports_large_worlds:    bool,
}

// TODO: allow this to run contextless
// @(init)
validate_struct_sizes :: proc() {
    header_size := size_of(Mesh_Header)
    if header_size != EXPECTED_DT_MESH_HEADER_SIZE {
        log.fatalf("Mesh_Header size mismatch: got %d, expected %d", header_size, EXPECTED_DT_MESH_HEADER_SIZE)
    }

    poly_size := size_of(Poly)
    if poly_size != EXPECTED_DT_POLY_SIZE {
        log.fatalf("Poly size mismatch: got %d, expected %d", poly_size, EXPECTED_DT_POLY_SIZE)
    }

    link_size := size_of(Link)
    if link_size != EXPECTED_DT_LINK_SIZE {
        log.fatalf("Link size mismatch: got %d, expected %d", link_size, EXPECTED_DT_LINK_SIZE)
    }

    detail_size := size_of(Poly_Detail)
    if detail_size != EXPECTED_DT_POLY_DETAIL_SIZE {
        log.fatalf("Poly_Detail size mismatch: got %d, expected %d", detail_size, EXPECTED_DT_POLY_DETAIL_SIZE)
    }

    bv_size := size_of(BV_Node)
    if bv_size != EXPECTED_DT_BV_NODE_SIZE {
        log.fatalf("BV_Node size mismatch: got %d, expected %d", bv_size, EXPECTED_DT_BV_NODE_SIZE)
    }

    offmesh_size := size_of(Off_Mesh_Connection)
    if offmesh_size != EXPECTED_DT_OFF_MESH_CONNECTION_SIZE {
        log.fatalf("Off_Mesh_Connection size mismatch: got %d, expected %d", offmesh_size, EXPECTED_DT_OFF_MESH_CONNECTION_SIZE)
    }
}

Data_Validation_Result :: struct {
    valid:        bool,
    error_count:  int,
    errors:       [16]string,
}

validate_tile_data :: proc(data: []u8) -> (result: Data_Validation_Result) {
    result.valid = true

    add_error :: proc(result: ^Data_Validation_Result, message: string) {
        if result.error_count < len(result.errors) {
            result.errors[result.error_count] = message
            result.error_count += 1
        }
        result.valid = false
    }

    if len(data) < size_of(Mesh_Header) {
        add_error(&result, "Tile data too small for header")
        return
    }

    data_endianness, endian_ok := detect_data_endianness(data)
    if !endian_ok {
        add_error(&result, "Cannot detect data endianness - invalid or corrupt magic number")
        return
    }

    system_endianness := get_system_endianness()

    header := cast(^Mesh_Header)raw_data(data)

    if data_endianness != system_endianness {
        convert_header_endianness(header, data_endianness)
    }

    if header.magic != recast.DT_NAVMESH_MAGIC {
        add_error(&result, "Invalid magic number in tile header")
    }

    if header.version != NAVMESH_DATA_FORMAT_VERSION {
        if header.version < MINIMUM_SUPPORTED_VERSION {
            add_error(&result, "Unsupported tile data version (too old)")
        } else if header.version > NAVMESH_DATA_FORMAT_VERSION {
            add_error(&result, "Unsupported tile data version (too new)")
        }
    }

    if header.poly_count < 0 || header.vert_count < 0 ||
       header.max_link_count < 0 || header.detail_mesh_count < 0 ||
       header.detail_vert_count < 0 || header.detail_tri_count < 0 ||
       header.bv_node_count < 0 || header.off_mesh_con_count < 0 {
        add_error(&result, "Negative count in header (corrupt data)")
    }

    MAX_REASONABLE_POLYS :: 100_000
    MAX_REASONABLE_VERTS :: 500_000
    MAX_REASONABLE_LINKS :: 1_000_000

    if header.poly_count > MAX_REASONABLE_POLYS ||
       header.vert_count > MAX_REASONABLE_VERTS ||
       header.max_link_count > MAX_REASONABLE_LINKS {
        add_error(&result, "Header counts exceed reasonable limits")
    }

    expected_size := calculate_expected_tile_size(header)
    if len(data) < expected_size {
        add_error(&result, "Tile data smaller than expected from header")
    }

    for i in 0..<3 {
        if header.bmin[i] > header.bmax[i] {
            add_error(&result, "Invalid bounding box (min > max)")
            break
        }
        if header.bmin[i] != header.bmin[i] || header.bmax[i] != header.bmax[i] {
            add_error(&result, "NaN values in bounding box")
            break
        }
    }

    if header.walkable_height <= 0 || header.walkable_radius <= 0 || header.walkable_climb < 0 {
        add_error(&result, "Invalid walkable parameters")
    }

    return
}

calculate_expected_tile_size :: proc(header: ^Mesh_Header) -> int {
    size := size_of(Mesh_Header)
    size += size_of([3]f32) * int(header.vert_count)
    size += size_of(Poly) * int(header.poly_count)
    size += size_of(Link) * int(header.max_link_count)
    size += size_of(Poly_Detail) * int(header.detail_mesh_count)
    size += size_of([3]f32) * int(header.detail_vert_count)
    size += 4 * int(header.detail_tri_count)
    size += size_of(BV_Node) * int(header.bv_node_count)
    size += size_of(Off_Mesh_Connection) * int(header.off_mesh_con_count)
    return size
}

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
        features.has_bv_tree = true
        features.has_detail_meshes = true
        features.has_off_mesh_connections = true
        features.has_extended_header = true
        features.supports_large_worlds = true
    }

    return features
}

validate_navmesh_header :: proc(header: ^Mesh_Header) -> recast.Status {
    if header == nil do return {.Invalid_Param}
    if header.magic != recast.DT_NAVMESH_MAGIC do return {.Wrong_Magic}
    if header.version < MINIMUM_SUPPORTED_VERSION do return {.Wrong_Version}
    if header.version > MAXIMUM_FUTURE_VERSION do return {.Wrong_Version}
    if header.poly_count < 0 || header.vert_count < 0 do return {.Invalid_Param}
    return {.Success}
}

calculate_data_checksum :: proc(data: []u8) -> u32 {
    checksum: u32 = 0x12345678
    for x in data {
        checksum = checksum * 33 + u32(x)
    }
    return checksum
}

verify_data_layout :: proc(data: []u8, header: ^Mesh_Header) -> bool {
    if len(data) < size_of(Mesh_Header) do return false
    offset := size_of(Mesh_Header)
    if header.vert_count > 0 {
        vert_ptr := uintptr(raw_data(data)) + uintptr(offset)
        if vert_ptr % uintptr(align_of([3]f32)) != 0 do return false
        offset += size_of([3]f32) * int(header.vert_count)
    }
    if header.poly_count > 0 {
        poly_ptr := uintptr(raw_data(data)) + uintptr(offset)
        if poly_ptr % uintptr(align_of(Poly)) != 0 do return false
    }
    return true
}

log_struct_layout_info :: proc() {
    log.infof("Mesh_Header: size=%d, align=%d", size_of(Mesh_Header), align_of(Mesh_Header))
    log.infof("Poly: size=%d, align=%d", size_of(Poly), align_of(Poly))
    log.infof("Link: size=%d, align=%d", size_of(Link), align_of(Link))
    log.infof("Poly_Detail: size=%d, align=%d", size_of(Poly_Detail), align_of(Poly_Detail))
    log.infof("BV_Node: size=%d, align=%d", size_of(BV_Node), align_of(BV_Node))
    log.infof("Off_Mesh_Connection: size=%d, align=%d", size_of(Off_Mesh_Connection), align_of(Off_Mesh_Connection))
}
