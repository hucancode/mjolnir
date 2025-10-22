package navigation_detour

import "core:math"
import "core:math/linalg"
import "../recast"

create_navmesh :: proc(pmesh: ^recast.Poly_Mesh, dmesh: ^recast.Poly_Mesh_Detail,
                      walkable_height: f32, walkable_radius: f32, walkable_climb: f32) -> (nav_mesh: ^Nav_Mesh, ok: bool) {
    params := Create_Nav_Mesh_Data_Params{
        poly_mesh = pmesh,
        poly_mesh_detail = dmesh,
        walkable_height = walkable_height,
        walkable_radius = walkable_radius,
        walkable_climb = walkable_climb,
    }
    nav_data, data_status := create_nav_mesh_data(&params)
    if recast.status_failed(data_status) do return nil, false
    nav_mesh = new(Nav_Mesh)
    mesh_params := Nav_Mesh_Params{
        orig = pmesh.bmin,
        tile_width = (pmesh.bmax - pmesh.bmin).x,
        tile_height = (pmesh.bmax - pmesh.bmin).z,
        max_tiles = 1,
        max_polys = 1024,
    }
    init_status := nav_mesh_init(nav_mesh, &mesh_params)
    if recast.status_failed(init_status) {
        free(nav_mesh)
        return nil, false
    }
    _, add_status := nav_mesh_add_tile(nav_mesh, nav_data, recast.DT_TILE_FREE_DATA)
    if recast.status_failed(add_status) {
        nav_mesh_destroy(nav_mesh)
        free(nav_mesh)
        return nil, false
    }
    return nav_mesh, true
}

find_path_points :: proc(query: ^Nav_Mesh_Query, start_pos: [3]f32, end_pos: [3]f32,
                        filter: ^Query_Filter, path: [][3]f32) -> (path_count: int, status: recast.Status) {
    if len(path) == 0 do return 0, {.Buffer_Too_Small}
    half_extents := [3]f32{5.0, 5.0, 5.0}
    start_status, start_ref, start_nearest := find_nearest_poly(query, start_pos, half_extents, filter)
    if recast.status_failed(start_status) || start_ref == recast.INVALID_POLY_REF do return 0, start_status
    end_status, end_ref, end_nearest := find_nearest_poly(query, end_pos, half_extents, filter)
    if recast.status_failed(end_status) || end_ref == recast.INVALID_POLY_REF do return 0, end_status
    if start_ref == end_ref {
        path[0] = start_nearest
        if linalg.length2(end_nearest - start_nearest) > 0.0001 {
            path[1] = end_nearest
            return 2, {.Success}
        }
        return 1, {.Success}
    }
    poly_path := make([]recast.Poly_Ref, len(path))
    defer delete(poly_path)
    path_status, poly_path_count := find_path(query, start_ref, end_ref, start_nearest, end_nearest,
                                             filter, poly_path, i32(len(path)))
    if recast.status_failed(path_status) || poly_path_count == 0 do return 0, path_status
    straight_path := make([]Straight_Path_Point, len(path))
    defer delete(straight_path)
    straight_path_flags := make([]u8, len(path))
    defer delete(straight_path_flags)
    straight_path_refs := make([]recast.Poly_Ref, len(path))
    defer delete(straight_path_refs)
    straight_status, straight_path_count := find_straight_path(query, start_nearest, end_nearest,
                                                              poly_path[:poly_path_count], poly_path_count,
                                                              straight_path, straight_path_flags, straight_path_refs,
                                                              i32(len(path)), 0)
    if recast.status_failed(straight_status) do return 0, straight_status
    path_count = 0
    last_pos := [3]f32{math.F32_MAX, math.F32_MAX, math.F32_MAX}
    for i in 0..<int(straight_path_count) {
        pos := straight_path[i].pos
        if linalg.length2(pos - last_pos) > 0.0001 {
            path[path_count] = pos
            path_count += 1
            last_pos = pos
        }
    }
    return path_count, {.Success}
}

Poly :: struct {
    first_link:   u32,
    verts:        [recast.DT_VERTS_PER_POLYGON]u16,
    neis:         [recast.DT_VERTS_PER_POLYGON]u16,
    flags:        u16,
    vert_count:   u8,
    area_and_type: u8,
}

Link :: struct {
    ref:   recast.Poly_Ref,
    next:  u32,
    edge:  u8,
    side:  u8,
    bmin:  u8,
    bmax:  u8,
}

BV_Node :: struct {
    bmin: [3]u16,
    bmax: [3]u16,
    i:    i32,
}

Off_Mesh_Connection :: struct {
    start:   [3]f32,
    end:     [3]f32,
    rad:     f32,
    poly:    u16,
    flags:   u8,
    side:    u8,
    user_id: u32,
}

Mesh_Header :: struct {
    magic:               i32,
    version:             i32,
    x:                   i32,
    y:                   i32,
    layer:               i32,
    user_id:             u32,
    poly_count:          i32,
    vert_count:          i32,
    max_link_count:      i32,
    detail_mesh_count:   i32,
    detail_vert_count:   i32,
    detail_tri_count:    i32,
    bv_node_count:       i32,
    off_mesh_con_count:  i32,
    off_mesh_base:       i32,
    walkable_height:     f32,
    walkable_radius:     f32,
    walkable_climb:      f32,
    bmin:                [3]f32,
    bmax:                [3]f32,
    bv_quant_factor:     f32,
}

Mesh_Tile :: struct {
    salt:              u32,
    links_free_list:   u32,
    header:            ^Mesh_Header,
    polys:             []Poly,
    verts:             [][3]f32,
    links:             []Link,
    detail_meshes:     []Poly_Detail,
    detail_verts:      [][3]f32,
    detail_tris:       [][4]u8,
    bv_tree:           []BV_Node,
    off_mesh_cons:     []Off_Mesh_Connection,
    data:              []u8,
    flags:             i32,
    next:              ^Mesh_Tile,
}

Nav_Mesh_Params :: struct {
    orig:        [3]f32,
    tile_width:  f32,
    tile_height: f32,
    max_tiles:   i32,
    max_polys:   i32,
}

Nav_Mesh :: struct {
    params:         Nav_Mesh_Params,
    orig:           [3]f32,
    tile_width:     f32,
    tile_height:    f32,
    max_tiles:      i32,
    tile_lut_size:  i32,
    tile_lut_mask:  i32,
    pos_lookup:     []^Mesh_Tile,
    next_free:      ^Mesh_Tile,
    tiles:          []Mesh_Tile,
    salt_bits:      u32,
    tile_bits:      u32,
    poly_bits:      u32,
}

Query_Filter :: struct {
    area_cost:     [recast.DT_MAX_AREAS]f32,
    include_flags: u16,
    exclude_flags: u16,
}

Raycast_Hit :: struct {
    t:              f32,
    hit_normal:     [3]f32,
    hit_edge_index: i32,
    path:           []recast.Poly_Ref,
    path_count:     i32,
    path_cost:      f32,
}

Straight_Path_Point :: struct {
    pos:   [3]f32,
    flags: u8,
    ref:   recast.Poly_Ref,
}

Poly_Detail :: struct {
    vert_base:  u32,
    tri_base:   u32,
    vert_count: u8,
    tri_count:  u8,
}

Straight_Path_Flags :: enum u8 {
    Start                = 0x01,
    End                  = 0x02,
    Off_Mesh_Connection  = 0x04,
}

Find_Path_Options :: enum u8 {
    Any_Angle = 0x02,
}

Raycast_Options :: enum u8 {
    Use_Costs = 0x01,
}

Straight_Path_Options :: enum u8 {
    Area_Crossings = 0x01,
    All_Crossings  = 0x02,
}

Poly_Query :: struct {
    process: proc(ref: recast.Poly_Ref, tile: ^Mesh_Tile, poly: ^Poly, user_data: rawptr),
    user_data: rawptr,
}

poly_set_area :: proc(poly: ^Poly, area: u8) {
    poly.area_and_type = (poly.area_and_type & 0xc0) | (area & 0x3f)
}

poly_set_type :: proc(poly: ^Poly, type: u8) {
    poly.area_and_type = (poly.area_and_type & 0x3f) | (type << 6)
}

poly_get_area :: proc(poly: ^Poly) -> u8 {
    return poly.area_and_type & 0x3f
}

poly_get_type :: proc(poly: ^Poly) -> u8 {
    return poly.area_and_type >> 6
}

query_filter_init :: proc(filter: ^Query_Filter) {
    filter.include_flags = 0xffff
    filter.exclude_flags = 0
    for i in 0..<recast.DT_MAX_AREAS do filter.area_cost[i] = 1.0
}

query_filter_pass_filter :: proc(filter: ^Query_Filter, ref: recast.Poly_Ref, tile: ^Mesh_Tile, poly: ^Poly) -> bool {
    return (poly.flags & filter.include_flags) != 0 && (poly.flags & filter.exclude_flags) == 0
}

query_filter_get_cost :: proc(filter: ^Query_Filter, pa, pb: [3]f32,
                             prev_ref: recast.Poly_Ref, prev_tile: ^Mesh_Tile, prev_poly: ^Poly,
                             cur_ref: recast.Poly_Ref, cur_tile: ^Mesh_Tile, cur_poly: ^Poly,
                             next_ref: recast.Poly_Ref, next_tile: ^Mesh_Tile, next_poly: ^Poly) -> f32 {
    cost := linalg.distance(pa, pb)
    area := poly_get_area(cur_poly)
    if area < recast.DT_MAX_AREAS do cost *= filter.area_cost[area]
    return cost
}

encode_poly_id :: proc(nav_mesh: ^Nav_Mesh, salt: u32, tile_index: u32, poly_index: u32) -> recast.Poly_Ref {
    return recast.Poly_Ref((salt << (nav_mesh.poly_bits + nav_mesh.tile_bits)) |
                           (tile_index << nav_mesh.poly_bits) | poly_index)
}

decode_poly_id :: proc(nav_mesh: ^Nav_Mesh, ref: recast.Poly_Ref) -> (salt: u32, tile_index: u32, poly_index: u32) {
    if nav_mesh == nil do return 0, 0, 0
    salt_mask := (u32(1) << nav_mesh.salt_bits) - 1
    tile_mask := (u32(1) << nav_mesh.tile_bits) - 1
    poly_mask := (u32(1) << nav_mesh.poly_bits) - 1
    salt = (u32(ref) >> (nav_mesh.poly_bits + nav_mesh.tile_bits)) & salt_mask
    tile_index = (u32(ref) >> nav_mesh.poly_bits) & tile_mask
    poly_index = u32(ref) & poly_mask
    return
}

get_poly_index :: proc(nav_mesh: ^Nav_Mesh, ref: recast.Poly_Ref) -> u32 {
    if nav_mesh == nil do return 0
    return u32(ref) & ((u32(1) << nav_mesh.poly_bits) - 1)
}

calc_tile_loc :: proc(nav_mesh: ^Nav_Mesh, pos: [3]f32) -> (tx: i32, ty: i32, status: recast.Status) {
    if nav_mesh == nil do return 0, 0, {.Invalid_Param}
    if nav_mesh.tile_width <= 0 || nav_mesh.tile_height <= 0 do return 0, 0, {.Invalid_Param}
    offset := pos - nav_mesh.orig
    tx = i32(math.floor(offset.x / nav_mesh.tile_width))
    ty = i32(math.floor(offset.z / nav_mesh.tile_height))
    return tx, ty, {.Success}
}

get_detail_tri_edge_flags :: proc(tri_flags: u8, edge_index: i32) -> i32 {
    return i32((tri_flags >> (u8(edge_index) * 2)) & 0x3)
}
