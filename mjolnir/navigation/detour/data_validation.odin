package navigation_detour

import "core:log"
import "../recast"

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

    header := cast(^Mesh_Header)raw_data(data)


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


validate_navmesh_header :: proc(header: ^Mesh_Header) -> recast.Status {
    if header == nil do return {.Invalid_Param}
    if header.poly_count < 0 || header.vert_count < 0 do return {.Invalid_Param}
    return {.Success}
}


verify_data_layout :: proc(data: []u8, header: ^Mesh_Header) -> bool {
    _, map_status := navmesh_create_memory_map(data)
    return !recast.status_failed(map_status)
}
