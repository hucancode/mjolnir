package navigation_detour

import "core:math"
import "core:slice"
import "../recast"
import "../../geometry"

// Memory-mapped navmesh data that eliminates manual pointer arithmetic
Navmesh_Memory_Map :: struct {
    data:              []u8,
    header:            ^Mesh_Header,
    vertices:          [][3]f32,
    polygons:          []Poly,
    links:             []Link,
    detail_meshes:     []Poly_Detail,
    detail_vertices:   [][3]f32,
    detail_triangles:  [][4]u8,
    bv_nodes:          []BV_Node,
    off_mesh_conns:    []Off_Mesh_Connection,
}

// Create memory map from raw data - replaces all pointer arithmetic
navmesh_create_memory_map :: proc(data: []u8) -> (Navmesh_Memory_Map, recast.Status) {
    if len(data) < size_of(Mesh_Header) do return {}, {.Invalid_Param}

    memory_map: Navmesh_Memory_Map
    memory_map.data = data
    memory_map.header = cast(^Mesh_Header)raw_data(data)

    // Use slice syntax to avoid pointer arithmetic
    offset := size_of(Mesh_Header)

    if memory_map.header.vert_count > 0 {
        vert_bytes := offset + size_of([3]f32) * int(memory_map.header.vert_count)
        if vert_bytes > len(data) do return {}, {.Invalid_Param}
        memory_map.vertices = slice.from_ptr(cast(^[3]f32)&data[offset], int(memory_map.header.vert_count))
        offset = vert_bytes
    }

    if memory_map.header.poly_count > 0 {
        poly_bytes := offset + size_of(Poly) * int(memory_map.header.poly_count)
        if poly_bytes > len(data) do return {}, {.Invalid_Param}
        memory_map.polygons = slice.from_ptr(cast(^Poly)&data[offset], int(memory_map.header.poly_count))
        offset = poly_bytes
    }

    if memory_map.header.max_link_count > 0 {
        link_bytes := offset + size_of(Link) * int(memory_map.header.max_link_count)
        if link_bytes > len(data) do return {}, {.Invalid_Param}
        memory_map.links = slice.from_ptr(cast(^Link)&data[offset], int(memory_map.header.max_link_count))
        offset = link_bytes
    }

    if memory_map.header.detail_mesh_count > 0 {
        detail_mesh_bytes := offset + size_of(Poly_Detail) * int(memory_map.header.detail_mesh_count)
        if detail_mesh_bytes > len(data) do return {}, {.Invalid_Param}
        memory_map.detail_meshes = slice.from_ptr(cast(^Poly_Detail)&data[offset], int(memory_map.header.detail_mesh_count))
        offset = detail_mesh_bytes
    }

    if memory_map.header.detail_vert_count > 0 {
        detail_vert_bytes := offset + size_of([3]f32) * int(memory_map.header.detail_vert_count)
        if detail_vert_bytes > len(data) do return {}, {.Invalid_Param}
        memory_map.detail_vertices = slice.from_ptr(cast(^[3]f32)&data[offset], int(memory_map.header.detail_vert_count))
        offset = detail_vert_bytes
    }

    if memory_map.header.detail_tri_count > 0 {
        detail_tri_bytes := offset + size_of([4]u8) * int(memory_map.header.detail_tri_count)
        if detail_tri_bytes > len(data) do return {}, {.Invalid_Param}
        memory_map.detail_triangles = slice.from_ptr(cast(^[4]u8)&data[offset], int(memory_map.header.detail_tri_count))
        offset = detail_tri_bytes
    }

    if memory_map.header.bv_node_count > 0 {
        bv_bytes := offset + size_of(BV_Node) * int(memory_map.header.bv_node_count)
        if bv_bytes > len(data) do return {}, {.Invalid_Param}
        memory_map.bv_nodes = slice.from_ptr(cast(^BV_Node)&data[offset], int(memory_map.header.bv_node_count))
        offset = bv_bytes
    }

    if memory_map.header.off_mesh_con_count > 0 {
        off_mesh_bytes := offset + size_of(Off_Mesh_Connection) * int(memory_map.header.off_mesh_con_count)
        if off_mesh_bytes > len(data) do return {}, {.Invalid_Param}
        memory_map.off_mesh_conns = slice.from_ptr(cast(^Off_Mesh_Connection)&data[offset], int(memory_map.header.off_mesh_con_count))
        offset = off_mesh_bytes
    }

    return memory_map, {.Success}
}

// Calculate tile index using slice indexing
get_tile_index :: proc(nav_mesh: ^Nav_Mesh, tile: ^Mesh_Tile) -> u32 {
    if tile == nil do return 0

    // Use slice offset calculation (much more efficient than loop)
    base_ptr := raw_data(nav_mesh.tiles)
    tile_ptr := rawptr(tile)
    offset := int(uintptr(tile_ptr) - uintptr(base_ptr))
    return u32(offset / size_of(Mesh_Tile))
}

nav_mesh_init :: proc(nav_mesh: ^Nav_Mesh, params: ^Nav_Mesh_Params) -> recast.Status {
    nav_mesh.params = params^
    nav_mesh.orig = params.orig
    nav_mesh.tile_width = params.tile_width
    nav_mesh.tile_height = params.tile_height
    nav_mesh.max_tiles = params.max_tiles

    nav_mesh.tile_lut_size = 1
    for nav_mesh.tile_lut_size < nav_mesh.max_tiles {
        nav_mesh.tile_lut_size *= 2
    }
    nav_mesh.tile_lut_mask = nav_mesh.tile_lut_size - 1

    nav_mesh.tiles = make([]Mesh_Tile, nav_mesh.max_tiles)
    nav_mesh.pos_lookup = make([]^Mesh_Tile, nav_mesh.tile_lut_size)

    nav_mesh.next_free = nil
    for i := nav_mesh.max_tiles - 1; i >= 0; i -= 1 {
        nav_mesh.tiles[i].salt = 1
        nav_mesh.tiles[i].next = nav_mesh.next_free
        nav_mesh.next_free = &nav_mesh.tiles[i]
    }

    tile_bits_needed := geometry.ilog2(geometry.next_pow2(u32(params.max_tiles)))
    poly_bits_needed := geometry.ilog2(geometry.next_pow2(u32(params.max_polys)))
    nav_mesh.tile_bits = tile_bits_needed
    nav_mesh.poly_bits = poly_bits_needed

    nav_mesh.salt_bits = min(31, 32 - nav_mesh.tile_bits - nav_mesh.poly_bits)
    if nav_mesh.salt_bits < 10 do return {.Invalid_Param}

    return {.Success}
}

nav_mesh_destroy :: proc(nav_mesh: ^Nav_Mesh) {
    for i in 0..<nav_mesh.max_tiles {
        if nav_mesh.tiles[i].header != nil {
            nav_mesh_remove_tile(nav_mesh, get_tile_ref(nav_mesh, &nav_mesh.tiles[i]))
        }
    }

    delete(nav_mesh.tiles)
    delete(nav_mesh.pos_lookup)
    nav_mesh^ = {}
}

nav_mesh_add_tile :: proc(nav_mesh: ^Nav_Mesh, data: []u8, flags: i32, last_ref: recast.Tile_Ref = recast.INVALID_TILE_REF) -> (tile_ref: recast.Tile_Ref, status: recast.Status) {
    header, parse_status := parse_mesh_header(data)
    if recast.status_failed(parse_status) do return recast.INVALID_TILE_REF, parse_status

    tile: ^Mesh_Tile
    if last_ref != recast.INVALID_TILE_REF {
        tile_index := decode_tile_ref(nav_mesh, last_ref)
        if tile_index < u32(nav_mesh.max_tiles) {
            tile = &nav_mesh.tiles[tile_index]
            if tile.salt == decode_tile_ref_salt(nav_mesh, last_ref) {
                unlink_tile(nav_mesh, tile)
            } else {
                tile = nil
            }
        }
    }

    if tile == nil {
        if nav_mesh.next_free == nil do return recast.INVALID_TILE_REF, {.Out_Of_Memory}
        tile = nav_mesh.next_free
        nav_mesh.next_free = tile.next
        tile.next = nil
    }

    result := setup_tile_data(tile, data, header, flags)
    if recast.status_failed(result) do return recast.INVALID_TILE_REF, result

    h := compute_tile_hash(header.x, header.y, nav_mesh.tile_lut_mask)
    tile.next = nav_mesh.pos_lookup[h]
    nav_mesh.pos_lookup[h] = tile

    connect_int_links(nav_mesh, tile)

    connect_ext_links(nav_mesh, tile)

    return get_tile_ref(nav_mesh, tile), {.Success}
}

nav_mesh_remove_tile :: proc(nav_mesh: ^Nav_Mesh, ref: recast.Tile_Ref) -> recast.Status {
    tile, get_status := get_tile_by_ref(nav_mesh, ref)
    if recast.status_failed(get_status) do return get_status

    disconnect_ext_links(nav_mesh, tile)

    h := compute_tile_hash(tile.header.x, tile.header.y, nav_mesh.tile_lut_mask)
    prev: ^Mesh_Tile = nil
    cur := nav_mesh.pos_lookup[h]
    for cur != nil {
        if cur == tile {
            if prev != nil {
                prev.next = cur.next
            } else {
                nav_mesh.pos_lookup[h] = cur.next
            }
            break
        }
        prev = cur
        cur = cur.next
    }

    free_tile_data(tile)

    tile.salt = (tile.salt + 1) & ((1 << nav_mesh.salt_bits) - 1)
    tile.header = nil
    tile.flags = 0

    tile.next = nav_mesh.next_free
    nav_mesh.next_free = tile

    return {.Success}
}

get_tile_by_ref :: proc(nav_mesh: ^Nav_Mesh, ref: recast.Tile_Ref) -> (^Mesh_Tile, recast.Status) {
    if ref == recast.INVALID_TILE_REF do return nil, {.Invalid_Param}

    tile_index := decode_tile_ref(nav_mesh, ref)
    salt := decode_tile_ref_salt(nav_mesh, ref)

    if tile_index >= u32(nav_mesh.max_tiles) do return nil, {.Invalid_Param}

    tile := &nav_mesh.tiles[tile_index]
    if tile.salt != salt || tile.header == nil do return nil, {.Invalid_Param}

    return tile, {.Success}
}

get_tile_at :: proc(nav_mesh: ^Nav_Mesh, x, y: i32, layer: i32) -> ^Mesh_Tile {
    h := compute_tile_hash(x, y, nav_mesh.tile_lut_mask)
    tile := nav_mesh.pos_lookup[h]
    for tile != nil {
        if tile.header != nil &&
           tile.header.x == x &&
           tile.header.y == y &&
           tile.header.layer == layer {
            return tile
        }
        tile = tile.next
    }
    return nil
}

get_tile_ref :: proc(nav_mesh: ^Nav_Mesh, tile: ^Mesh_Tile) -> recast.Tile_Ref {
    if tile == nil do return recast.INVALID_TILE_REF

    // Calculate tile index
    tile_index := get_tile_index(nav_mesh, tile)
    return recast.Tile_Ref(encode_tile_ref(nav_mesh, tile.salt, tile_index))
}

// Get polygon by reference
get_tile_and_poly_by_ref :: proc(nav_mesh: ^Nav_Mesh, ref: recast.Poly_Ref) -> (^Mesh_Tile, ^Poly, recast.Status) {
    if nav_mesh == nil {
        return nil, nil, {.Invalid_Param}
    }

    if ref == recast.INVALID_POLY_REF {
        return nil, nil, {.Invalid_Param}
    }

    salt, tile_index, poly_index := decode_poly_id(nav_mesh, ref)

    if tile_index >= u32(nav_mesh.max_tiles) {
        return nil, nil, {.Invalid_Param}
    }

    tile := &nav_mesh.tiles[tile_index]
    if tile.salt != salt || tile.header == nil {
        return nil, nil, {.Invalid_Param}
    }

    if poly_index >= u32(tile.header.poly_count) {
        return nil, nil, {.Invalid_Param}
    }

    poly := &tile.polys[poly_index]
    return tile, poly, {.Success}
}

// Validate polygon reference
is_valid_poly_ref :: proc(nav_mesh: ^Nav_Mesh, ref: recast.Poly_Ref) -> bool {
    if ref == recast.INVALID_POLY_REF {
        return false
    }

    salt, tile_index, poly_index := decode_poly_id(nav_mesh, ref)

    if tile_index >= u32(nav_mesh.max_tiles) {
        return false
    }

    tile := &nav_mesh.tiles[tile_index]
    if tile.salt != salt || tile.header == nil {
        return false
    }

    if poly_index >= u32(tile.header.poly_count) {
        return false
    }

    return true
}

parse_mesh_header :: proc(data: []u8) -> (^Mesh_Header, recast.Status) {
    if len(data) < size_of(Mesh_Header) do return nil, {.Invalid_Param}

    validation_result := validate_tile_data(data)
    if !validation_result.valid do return nil, {.Invalid_Param}

    header := cast(^Mesh_Header)raw_data(data)
    header_status := validate_navmesh_header(header)
    if recast.status_failed(header_status) do return nil, header_status

    return header, {.Success}
}

setup_tile_data :: proc(tile: ^Mesh_Tile, data: []u8, header: ^Mesh_Header, flags: i32) -> recast.Status {
    if !verify_data_layout(data, header) do return {.Invalid_Param}

    tile.data = data
    tile.header = header
    tile.flags = flags

    // Use memory map instead of manual pointer arithmetic
    memory_map, map_status := navmesh_create_memory_map(data)
    if recast.status_failed(map_status) do return map_status

    tile.verts = memory_map.vertices
    tile.polys = memory_map.polygons
    tile.links = memory_map.links
    tile.detail_meshes = memory_map.detail_meshes
    tile.detail_verts = memory_map.detail_vertices
    tile.detail_tris = memory_map.detail_triangles
    tile.bv_tree = memory_map.bv_nodes
    tile.off_mesh_cons = memory_map.off_mesh_conns

    tile.links_free_list = recast.DT_NULL_LINK
    if len(tile.links) > 0 {
        for i in 0..<len(tile.links) - 1 {
            tile.links[i].next = u32(i + 1)
            tile.links[i].ref = recast.INVALID_POLY_REF
        }
        tile.links[len(tile.links) - 1].next = recast.DT_NULL_LINK
        tile.links[len(tile.links) - 1].ref = recast.INVALID_POLY_REF
        tile.links_free_list = 0
    }

    return {.Success}
}

free_tile_data :: proc(tile: ^Mesh_Tile) {
    // Clear slices
    tile.polys = nil
    tile.verts = nil
    tile.links = nil
    tile.detail_meshes = nil
    tile.detail_verts = nil
    tile.detail_tris = nil
    tile.bv_tree = nil
    tile.off_mesh_cons = nil

    // Free data if owned by tile
    if (tile.flags & recast.DT_TILE_FREE_DATA) != 0 {
        delete(tile.data)
    }
    tile.data = nil
}

connect_int_links :: proc(nav_mesh: ^Nav_Mesh, tile: ^Mesh_Tile) {
    if tile.header == nil do return
    base := get_poly_ref_base(nav_mesh, tile)

    for i in 0..<int(tile.header.poly_count) {
        poly := &tile.polys[i]
        poly.first_link = recast.DT_NULL_LINK

        if poly_get_type(poly) == recast.DT_POLYTYPE_OFFMESH_CONNECTION do continue

        if poly.vert_count > recast.DT_VERTS_PER_POLYGON do continue

        for j in 0..<int(poly.vert_count) {
            if poly.neis[j] != 0 {
                neighbor_id := poly.neis[j] & 0x8000 != 0 ? poly.neis[j] & 0x7fff : poly.neis[j] - 1

                if neighbor_id >= u16(tile.header.poly_count) do continue

                if link_idx, ok := allocate_link(tile, u32(i)); ok {
                    link := &tile.links[link_idx]
                    link.ref = base | recast.Poly_Ref(neighbor_id)
                    link.edge = u8(j)
                    link.side = 0xff
                    link.bmin = 0
                    link.bmax = 0

                    // Add to polygon's link list
                    link.next = poly.first_link
                    poly.first_link = link_idx

                }
            }
        }
    }
}

connect_ext_links :: proc(nav_mesh: ^Nav_Mesh, tile: ^Mesh_Tile) {
    if tile.header == nil do return
    for i in 0..<4 do connect_ext_links_side(nav_mesh, tile, i)
}

connect_ext_links_side :: proc(nav_mesh: ^Nav_Mesh, tile: ^Mesh_Tile, side: int) {
    if tile.header == nil do return

    nx := tile.header.x
    ny := tile.header.y

    switch side {
    case 0: nx += 1
    case 1: ny += 1
    case 2: nx -= 1
    case 3: ny -= 1
    }

    neighbor := get_tile_at(nav_mesh, nx, ny, 0)
    if neighbor == nil do return

    MAX_VERTS :: 64
    verts: [MAX_VERTS * 2][3]f32
    nei: [MAX_VERTS * 2]recast.Poly_Ref
    nnei := 0

    for i in 0..<tile.header.poly_count {
        poly := &tile.polys[i]
        nv := int(poly.vert_count)

        for j in 0..<nv {
            if poly.neis[j] != 0 do continue  // Not a border edge

            // Check if this edge is on the specified side
            va := tile.verts[poly.verts[j]]
            vb := tile.verts[poly.verts[(j+1) % nv]]

            if !is_edge_on_tile_border(va, vb, tile.header.bmin, tile.header.bmax, side) {
                continue
            }

            if nnei >= MAX_VERTS * 2 - 2 do break

            verts[nnei] = va
            verts[nnei + 1] = vb
            nei[nnei] = get_poly_ref_base(nav_mesh, tile) | recast.Poly_Ref(i)
            nei[nnei + 1] = nei[nnei]
            nnei += 2
        }
    }

    if nnei == 0 do return
    for i in 0..<neighbor.header.poly_count {
        poly := &neighbor.polys[i]

        if poly.vert_count > recast.DT_VERTS_PER_POLYGON do continue

        nv := int(poly.vert_count)

        for j in 0..<nv {
            if poly.neis[j] != 0 do continue  // Not a border edge

            if poly.verts[j] >= u16(neighbor.header.vert_count) || poly.verts[(j+1) % nv] >= u16(neighbor.header.vert_count) do continue

            va := neighbor.verts[poly.verts[j]]
            vb := neighbor.verts[poly.verts[(j+1) % nv]]

            opposite_side := (side + 2) % 4
            if !is_edge_on_tile_border(va, vb, neighbor.header.bmin, neighbor.header.bmax, opposite_side) do continue

            for k in 0..<nnei-1 {
                if geometry.segment_segment_intersect_2d(verts[k], verts[k+1], va, vb) {
                    // Create bidirectional link
                    poly_ref := get_poly_ref_base(nav_mesh, neighbor) | recast.Poly_Ref(i)

                    poly_idx := u32(nei[k] & recast.Poly_Ref(tile.header.poly_count - 1))
                    if poly_idx >= u32(tile.header.poly_count) do continue

                    if link_idx, ok := allocate_link(tile, poly_idx); ok {
                        link := &tile.links[link_idx]
                        link.ref = poly_ref
                        link.edge = u8(j)
                        link.side = u8(side)
                        link.bmin = 0
                        link.bmax = 255

                        link.next = tile.polys[poly_idx].first_link
                        tile.polys[poly_idx].first_link = link_idx

                        if rev_link_idx, rev_ok := allocate_link(neighbor, u32(i)); rev_ok {
                            rev_link := &neighbor.links[rev_link_idx]
                            rev_link.ref = nei[k]
                            rev_link.edge = u8(j)
                            rev_link.side = u8(opposite_side)
                            rev_link.bmin = 0
                            rev_link.bmax = 255

                            rev_link.next = neighbor.polys[i].first_link
                            neighbor.polys[i].first_link = rev_link_idx
                        }
                    }

                    break
                }
            }
        }
    }
}

disconnect_ext_links :: proc(nav_mesh: ^Nav_Mesh, tile: ^Mesh_Tile) {
    if tile.header == nil {
        return
    }

    // Get base reference for this tile
    base_ref := get_poly_ref_base(nav_mesh, tile)

    // Check all neighboring tiles
    for side in 0..<4 {
        nx := tile.header.x
        ny := tile.header.y

        switch side {
        case 0: nx += 1  // East
        case 1: ny += 1  // North
        case 2: nx -= 1  // West
        case 3: ny -= 1  // South
        }

        neighbor := get_tile_at(nav_mesh, nx, ny, 0)
        if neighbor == nil {
            continue
        }

        // Remove links from neighbor that point to this tile
        for i in 0..<neighbor.header.poly_count {
            poly := &neighbor.polys[i]

            // Traverse link list and remove links to this tile
            prev_link: u32 = recast.DT_NULL_LINK
            link_idx := poly.first_link

            for link_idx != recast.DT_NULL_LINK {
                link := &neighbor.links[link_idx]
                next_link := link.next

                // Check if this link points to the tile being removed
                link_tile_ref := (link.ref >> nav_mesh.poly_bits) >> nav_mesh.salt_bits
                this_tile_ref := (base_ref >> nav_mesh.poly_bits) >> nav_mesh.salt_bits

                if link_tile_ref == this_tile_ref {
                    // Remove this link
                    if prev_link == recast.DT_NULL_LINK {
                        poly.first_link = next_link
                    } else {
                        neighbor.links[prev_link].next = next_link
                    }

                    // Add link back to free list
                    link.next = neighbor.links_free_list
                    neighbor.links_free_list = link_idx
                } else {
                    prev_link = link_idx
                }

                link_idx = next_link
            }
        }
    }
}

allocate_link :: proc(tile: ^Mesh_Tile, poly: u32) -> (u32, bool) {
    if tile.links_free_list == recast.DT_NULL_LINK {
        return recast.DT_NULL_LINK, false
    }

    if tile.links_free_list >= u32(len(tile.links)) {
        return recast.DT_NULL_LINK, false
    }

    link_idx := tile.links_free_list
    tile.links_free_list = tile.links[link_idx].next
    return link_idx, true
}

get_poly_ref_base :: proc(nav_mesh: ^Nav_Mesh, tile: ^Mesh_Tile) -> recast.Poly_Ref {
    if tile == nil {
        return recast.Poly_Ref(0)
    }

    // Calculate tile index
    tile_index := get_tile_index(nav_mesh, tile)

    // Encode reference with salt, tile index, and zero polygon index
    salt := tile.salt & ((1 << nav_mesh.salt_bits) - 1)
    return recast.Poly_Ref((salt << (nav_mesh.tile_bits + nav_mesh.poly_bits)) |
                             (tile_index << nav_mesh.poly_bits))
}

// Utility functions

compute_tile_hash :: proc(x: i32, y: i32, mask: i32) -> i32 {
    h1: u32 = 0x8da6b343
    h2: u32 = 0xd8163841
    h := transmute(i32)h1 * x + transmute(i32)h2 * y
    return h & mask
}

unlink_tile :: proc(nav_mesh: ^Nav_Mesh, tile: ^Mesh_Tile) {
    // Remove tile from free list
    if nav_mesh.next_free == tile {
        nav_mesh.next_free = tile.next
        return
    }

    prev := nav_mesh.next_free
    for prev != nil && prev.next != tile {
        prev = prev.next
    }

    if prev != nil {
        prev.next = tile.next
    }
}

// Tile reference encoding
encode_tile_ref :: proc(nav_mesh: ^Nav_Mesh, salt: u32, tile_index: u32) -> u32 {
    return (salt << nav_mesh.tile_bits) | tile_index
}

decode_tile_ref :: proc(nav_mesh: ^Nav_Mesh, ref: recast.Tile_Ref) -> u32 {
    tile_mask := (u32(1) << nav_mesh.tile_bits) - 1
    return u32(ref) & tile_mask
}

decode_tile_ref_salt :: proc(nav_mesh: ^Nav_Mesh, ref: recast.Tile_Ref) -> u32 {
    salt_mask := (u32(1) << nav_mesh.salt_bits) - 1
    return (u32(ref) >> nav_mesh.tile_bits) & salt_mask
}

// Helper functions for external link connection

// Check if an edge is on a specific border of a tile
is_edge_on_tile_border :: proc(va, vb: [3]f32, bmin, bmax: [3]f32, side: int) -> bool {
    switch side {
    case 0:  // East border (max X)
        return math.abs(va.x - bmax.x) < math.F32_EPSILON && math.abs(vb.x - bmax.x) < math.F32_EPSILON
    case 1:  // North border (max Z)
        return math.abs(va.z - bmax.z) < math.F32_EPSILON && math.abs(vb.z - bmax.z) < math.F32_EPSILON
    case 2:  // West border (min X)
        return math.abs(va.x - bmin.x) < math.F32_EPSILON && math.abs(vb.x - bmin.x) < math.F32_EPSILON
    case 3:  // South border (min Z)
        return math.abs(va.z - bmin.z) < math.F32_EPSILON && math.abs(vb.z - bmin.z) < math.F32_EPSILON
    }
    return false
}
