package navigation_detour

import "core:mem"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:log"
import nav_recast "../recast"

// Initialize navigation mesh with parameters
dt_nav_mesh_init :: proc(nav_mesh: ^Dt_Nav_Mesh, params: ^Dt_Nav_Mesh_Params) -> nav_recast.Status {
    nav_mesh.params = params^
    nav_mesh.orig = params.orig
    nav_mesh.tile_width = params.tile_width
    nav_mesh.tile_height = params.tile_height
    nav_mesh.max_tiles = params.max_tiles
    
    // Calculate tile lookup size (next power of 2)
    nav_mesh.tile_lut_size = 1
    for nav_mesh.tile_lut_size < nav_mesh.max_tiles {
        nav_mesh.tile_lut_size *= 2
    }
    nav_mesh.tile_lut_mask = nav_mesh.tile_lut_size - 1
    
    // Allocate tiles
    nav_mesh.tiles = make([]Dt_Mesh_Tile, nav_mesh.max_tiles)
    nav_mesh.pos_lookup = make([]^Dt_Mesh_Tile, nav_mesh.tile_lut_size)
    
    // Initialize free list
    nav_mesh.next_free = nil
    for i := nav_mesh.max_tiles - 1; i >= 0; i -= 1 {
        nav_mesh.tiles[i].salt = 1
        nav_mesh.tiles[i].next = nav_mesh.next_free
        nav_mesh.next_free = &nav_mesh.tiles[i]
    }
    
    // Calculate ID encoding parameters
    tile_bits_needed := dt_ilog2(dt_next_pow2(u32(params.max_tiles)))
    poly_bits_needed := dt_ilog2(dt_next_pow2(u32(params.max_polys)))
    
    // Use 32-bit references
    nav_mesh.salt_bits = max(1, min(15, 32 - tile_bits_needed - poly_bits_needed))
    nav_mesh.tile_bits = max(1, min(28, tile_bits_needed))
    nav_mesh.poly_bits = max(1, 32 - nav_mesh.salt_bits - nav_mesh.tile_bits)
    
    return {.Success}
}

// Clean up navigation mesh
dt_nav_mesh_destroy :: proc(nav_mesh: ^Dt_Nav_Mesh) {
    // Clean up all tiles first
    for i in 0..<nav_mesh.max_tiles {
        if nav_mesh.tiles[i].header != nil {
            dt_nav_mesh_remove_tile(nav_mesh, dt_get_tile_ref(nav_mesh, &nav_mesh.tiles[i]))
        }
    }
    
    delete(nav_mesh.tiles)
    delete(nav_mesh.pos_lookup)
    nav_mesh^ = {}
}

// Add tile to navigation mesh
dt_nav_mesh_add_tile :: proc(nav_mesh: ^Dt_Nav_Mesh, data: []u8, flags: i32, last_ref: nav_recast.Tile_Ref = nav_recast.INVALID_TILE_REF) -> (tile_ref: nav_recast.Tile_Ref, status: nav_recast.Status) {
    // Parse tile data
    header, parse_status := dt_parse_mesh_header(data)
    if nav_recast.status_failed(parse_status) {
        return nav_recast.INVALID_TILE_REF, parse_status
    }
    
    // Get free tile
    tile: ^Dt_Mesh_Tile
    if last_ref != nav_recast.INVALID_TILE_REF {
        // Try to reuse the specified tile reference
        tile_index := dt_decode_tile_ref(nav_mesh, last_ref)
        if tile_index < u32(nav_mesh.max_tiles) {
            tile = &nav_mesh.tiles[tile_index]
            if tile.salt == dt_decode_tile_ref_salt(nav_mesh, last_ref) {
                // Remove from free list if it's there
                dt_unlink_tile(nav_mesh, tile)
            } else {
                tile = nil
            }
        }
    }
    
    if tile == nil {
        if nav_mesh.next_free == nil {
            return nav_recast.INVALID_TILE_REF, {.Out_Of_Memory}
        }
        tile = nav_mesh.next_free
        nav_mesh.next_free = tile.next
        tile.next = nil
    }
    
    // Parse and setup tile data
    result := dt_setup_tile_data(tile, data, header, flags)
    if nav_recast.status_failed(result) {
        return nav_recast.INVALID_TILE_REF, result
    }
    
    // Insert into tile grid
    h := dt_compute_tile_hash(header.x, header.y, nav_mesh.tile_lut_mask)
    tile.next = nav_mesh.pos_lookup[h]
    nav_mesh.pos_lookup[h] = tile
    
    // Connect internal links
    dt_connect_int_links(nav_mesh, tile)
    
    // Connect external links to neighbors
    dt_connect_ext_links(nav_mesh, tile)
    
    return dt_get_tile_ref(nav_mesh, tile), {.Success}
}

// Remove tile from navigation mesh
dt_nav_mesh_remove_tile :: proc(nav_mesh: ^Dt_Nav_Mesh, ref: nav_recast.Tile_Ref) -> nav_recast.Status {
    tile, get_status := dt_get_tile_by_ref(nav_mesh, ref)
    if nav_recast.status_failed(get_status) {
        return get_status
    }
    
    // Disconnect external links from neighbors
    dt_disconnect_ext_links(nav_mesh, tile)
    
    // Remove from tile grid
    h := dt_compute_tile_hash(tile.header.x, tile.header.y, nav_mesh.tile_lut_mask)
    prev: ^Dt_Mesh_Tile = nil
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
    
    // Free tile data
    dt_free_tile_data(tile)
    
    // Reset tile
    tile.salt = (tile.salt + 1) & ((1 << nav_mesh.salt_bits) - 1)
    tile.header = nil
    tile.flags = 0
    
    // Add back to free list
    tile.next = nav_mesh.next_free
    nav_mesh.next_free = tile
    
    return {.Success}
}

// Get tile by reference
dt_get_tile_by_ref :: proc(nav_mesh: ^Dt_Nav_Mesh, ref: nav_recast.Tile_Ref) -> (^Dt_Mesh_Tile, nav_recast.Status) {
    if ref == nav_recast.INVALID_TILE_REF {
        return nil, {.Invalid_Param}
    }
    
    tile_index := dt_decode_tile_ref(nav_mesh, ref)
    salt := dt_decode_tile_ref_salt(nav_mesh, ref)
    
    if tile_index >= u32(nav_mesh.max_tiles) {
        return nil, {.Invalid_Param}
    }
    
    tile := &nav_mesh.tiles[tile_index]
    if tile.salt != salt || tile.header == nil {
        return nil, {.Invalid_Param}
    }
    
    return tile, {.Success}
}

// Get tile at grid position
dt_get_tile_at :: proc(nav_mesh: ^Dt_Nav_Mesh, x: i32, y: i32, layer: i32) -> ^Dt_Mesh_Tile {
    h := dt_compute_tile_hash(x, y, nav_mesh.tile_lut_mask)
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

// Get tile reference
dt_get_tile_ref :: proc(nav_mesh: ^Dt_Nav_Mesh, tile: ^Dt_Mesh_Tile) -> nav_recast.Tile_Ref {
    if tile == nil {
        return nav_recast.INVALID_TILE_REF
    }
    
    // Calculate tile index
    tile_index := u32(uintptr(tile) - uintptr(&nav_mesh.tiles[0])) / size_of(Dt_Mesh_Tile)
    return nav_recast.Tile_Ref(dt_encode_tile_ref(nav_mesh, tile.salt, tile_index))
}

// Get polygon by reference
dt_get_tile_and_poly_by_ref :: proc(nav_mesh: ^Dt_Nav_Mesh, ref: nav_recast.Poly_Ref) -> (^Dt_Mesh_Tile, ^Dt_Poly, nav_recast.Status) {
    if nav_mesh == nil {
        return nil, nil, {.Invalid_Param}
    }
    
    if ref == nav_recast.INVALID_POLY_REF {
        return nil, nil, {.Invalid_Param}
    }
    
    salt, tile_index, poly_index := dt_decode_poly_id(nav_mesh, ref)
    
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
dt_is_valid_poly_ref :: proc(nav_mesh: ^Dt_Nav_Mesh, ref: nav_recast.Poly_Ref) -> bool {
    if ref == nav_recast.INVALID_POLY_REF {
        return false
    }
    
    salt, tile_index, poly_index := dt_decode_poly_id(nav_mesh, ref)
    
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

// Helper functions

dt_parse_mesh_header :: proc(data: []u8) -> (^Dt_Mesh_Header, nav_recast.Status) {
    if len(data) < size_of(Dt_Mesh_Header) {
        return nil, {.Invalid_Param}
    }
    
    // Validate raw tile data before parsing
    validation_result := validate_tile_data(data)
    if !validation_result.valid {
        log.errorf("Tile data validation failed:")
        for i in 0..<validation_result.error_count {
            log.errorf("  - %s", validation_result.errors[i])
        }
        return nil, {.Invalid_Param}
    }
    
    // Cast first part of data to header
    header := cast(^Dt_Mesh_Header)raw_data(data)
    
    // Enhanced header validation with detailed error reporting
    header_status := validate_navmesh_header(header)
    if nav_recast.status_failed(header_status) {
        return nil, header_status
    }
    
    return header, {.Success}
}

dt_setup_tile_data :: proc(tile: ^Dt_Mesh_Tile, data: []u8, header: ^Dt_Mesh_Header, flags: i32) -> nav_recast.Status {
    // Validate data layout before proceeding
    if !verify_data_layout(data, header) {
        log.errorf("Data layout verification failed")
        return {.Invalid_Param}
    }
    
    // Store data
    tile.data = data
    tile.header = header
    tile.flags = flags
    
    // Calculate data layout offsets using validated format specification
    // Data format: [Header][Vertices][Polygons][Links][DetailMeshes][DetailVerts][DetailTris][BVTree][OffMeshConnections]
    offset := size_of(Dt_Mesh_Header)
    
    // Vertices - first data section per navmesh format specification
    if header.vert_count > 0 {
        // Verify alignment requirements
        vert_ptr := uintptr(raw_data(data)) + uintptr(offset)
        if vert_ptr % uintptr(align_of([3]f32)) != 0 {
            log.errorf("Vertex data alignment error: ptr=0x%x, required_align=%d", vert_ptr, align_of([3]f32))
            return {.Invalid_Param}
        }
        
        verts_ptr := cast(^[3]f32)(vert_ptr)
        tile.verts = slice.from_ptr(verts_ptr, int(header.vert_count))
        offset += size_of([3]f32) * int(header.vert_count)
    }
    
    // Polygons - second data section per navmesh format specification
    if header.poly_count > 0 {
        // Verify alignment requirements
        poly_ptr_addr := uintptr(raw_data(data)) + uintptr(offset)
        if poly_ptr_addr % uintptr(align_of(Dt_Poly)) != 0 {
            log.errorf("Polygon data alignment error: ptr=0x%x, required_align=%d", poly_ptr_addr, align_of(Dt_Poly))
            return {.Invalid_Param}
        }
        
        poly_ptr := cast(^Dt_Poly)(poly_ptr_addr)
        tile.polys = slice.from_ptr(poly_ptr, int(header.poly_count))
        offset += size_of(Dt_Poly) * int(header.poly_count)
    }
    
    // Links - third data section per navmesh format specification
    if header.max_link_count > 0 {
        link_ptr_addr := uintptr(raw_data(data)) + uintptr(offset)
        if link_ptr_addr % uintptr(align_of(Dt_Link)) != 0 {
            log.errorf("Link data alignment error: ptr=0x%x, required_align=%d", link_ptr_addr, align_of(Dt_Link))
            return {.Invalid_Param}
        }
        
        link_ptr := cast(^Dt_Link)(link_ptr_addr)
        tile.links = slice.from_ptr(link_ptr, int(header.max_link_count))
        offset += size_of(Dt_Link) * int(header.max_link_count)
    }
    
    // Detail meshes - fourth data section per navmesh format specification
    if header.detail_mesh_count > 0 {
        detail_mesh_ptr_addr := uintptr(raw_data(data)) + uintptr(offset)
        if detail_mesh_ptr_addr % uintptr(align_of(Dt_Poly_Detail)) != 0 {
            log.errorf("Detail mesh data alignment error: ptr=0x%x, required_align=%d", detail_mesh_ptr_addr, align_of(Dt_Poly_Detail))
            return {.Invalid_Param}
        }
        
        detail_mesh_ptr := cast(^Dt_Poly_Detail)(detail_mesh_ptr_addr)
        tile.detail_meshes = slice.from_ptr(detail_mesh_ptr, int(header.detail_mesh_count))
        offset += size_of(Dt_Poly_Detail) * int(header.detail_mesh_count)
    }
    
    // Detail vertices - fifth data section per navmesh format specification
    if header.detail_vert_count > 0 {
        detail_verts_ptr_addr := uintptr(raw_data(data)) + uintptr(offset)
        if detail_verts_ptr_addr % uintptr(align_of([3]f32)) != 0 {
            log.errorf("Detail vertex data alignment error: ptr=0x%x, required_align=%d", detail_verts_ptr_addr, align_of([3]f32))
            return {.Invalid_Param}
        }
        
        detail_verts_ptr := cast(^[3]f32)(detail_verts_ptr_addr)
        tile.detail_verts = slice.from_ptr(detail_verts_ptr, int(header.detail_vert_count))
        offset += size_of([3]f32) * int(header.detail_vert_count)
    }
    
    // Detail triangles - sixth data section per navmesh format specification
    if header.detail_tri_count > 0 {
        // Detail triangles are [4]u8 arrays, so we need to cast properly
        detail_tri_ptr := cast(^[4]u8)(uintptr(raw_data(data)) + uintptr(offset))
        tile.detail_tris = slice.from_ptr(detail_tri_ptr, int(header.detail_tri_count))
        offset += size_of([4]u8) * int(header.detail_tri_count)
    }
    
    // BV tree - seventh data section per navmesh format specification
    if header.bv_node_count > 0 {
        bv_node_ptr_addr := uintptr(raw_data(data)) + uintptr(offset)
        if bv_node_ptr_addr % uintptr(align_of(Dt_BV_Node)) != 0 {
            log.errorf("BV node data alignment error: ptr=0x%x, required_align=%d", bv_node_ptr_addr, align_of(Dt_BV_Node))
            return {.Invalid_Param}
        }
        
        bv_node_ptr := cast(^Dt_BV_Node)(bv_node_ptr_addr)
        tile.bv_tree = slice.from_ptr(bv_node_ptr, int(header.bv_node_count))
        offset += size_of(Dt_BV_Node) * int(header.bv_node_count)
    }
    
    // Off-mesh connections - eighth data section per navmesh format specification
    if header.off_mesh_con_count > 0 {
        off_mesh_ptr_addr := uintptr(raw_data(data)) + uintptr(offset)
        if off_mesh_ptr_addr % uintptr(align_of(Dt_Off_Mesh_Connection)) != 0 {
            log.errorf("Off-mesh connection data alignment error: ptr=0x%x, required_align=%d", off_mesh_ptr_addr, align_of(Dt_Off_Mesh_Connection))
            return {.Invalid_Param}
        }
        
        off_mesh_ptr := cast(^Dt_Off_Mesh_Connection)(off_mesh_ptr_addr)
        tile.off_mesh_cons = slice.from_ptr(off_mesh_ptr, int(header.off_mesh_con_count))
        offset += size_of(Dt_Off_Mesh_Connection) * int(header.off_mesh_con_count)
    }
    
    // Verify that we've consumed the expected amount of data
    expected_size := calculate_expected_tile_size(header)
    if offset != expected_size {
        log.warnf("Data layout size mismatch: consumed %d bytes, expected %d bytes", offset, expected_size)
        // This is a warning rather than an error as some versions may have padding
    }
    
    // Initialize links free list
    tile.links_free_list = nav_recast.DT_NULL_LINK
    if len(tile.links) > 0 {
        for i in 0..<len(tile.links) - 1 {
            tile.links[i].next = u32(i + 1)
            tile.links[i].ref = nav_recast.INVALID_POLY_REF
        }
        tile.links[len(tile.links) - 1].next = nav_recast.DT_NULL_LINK
        tile.links[len(tile.links) - 1].ref = nav_recast.INVALID_POLY_REF
        tile.links_free_list = 0
    }
    
    return {.Success}
}

dt_free_tile_data :: proc(tile: ^Dt_Mesh_Tile) {
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
    if (tile.flags & nav_recast.DT_TILE_FREE_DATA) != 0 {
        delete(tile.data)
    }
    tile.data = nil
}

dt_connect_int_links :: proc(nav_mesh: ^Dt_Nav_Mesh, tile: ^Dt_Mesh_Tile) {
    if tile.header == nil {
        return
    }
    
    base := dt_get_poly_ref_base(nav_mesh, tile)
    
    for i in 0..<int(tile.header.poly_count) {
        poly := &tile.polys[i]
        poly.first_link = nav_recast.DT_NULL_LINK
        
        if dt_poly_get_type(poly) == nav_recast.DT_POLYTYPE_OFFMESH_CONNECTION {
            continue
        }
        
        // Validate polygon vertex count
        if poly.vert_count > nav_recast.DT_VERTS_PER_POLYGON {
            log.errorf("Polygon %d has invalid vert_count %d (max %d), skipping polygon", 
                      i, poly.vert_count, nav_recast.DT_VERTS_PER_POLYGON)
            continue
        }
        
        // Build internal connections
        for j in 0..<int(poly.vert_count) {
            if poly.neis[j] != 0 {
                // Validate neighbor reference
                neighbor_id := poly.neis[j] - 1
                if neighbor_id >= u16(tile.header.poly_count) {
                    log.warnf("Polygon %d edge %d has invalid neighbor %d (max %d)", 
                             i, j, neighbor_id, tile.header.poly_count - 1)
                    continue
                }
                
                if link_idx, ok := dt_allocate_link(tile, u32(i)); ok {
                    link := &tile.links[link_idx]
                    link.ref = base | nav_recast.Poly_Ref(neighbor_id)
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

dt_connect_ext_links :: proc(nav_mesh: ^Dt_Nav_Mesh, tile: ^Dt_Mesh_Tile) {
    if tile.header == nil {
        return
    }
    
    // Connect with neighbors in all 4 directions
    for i in 0..<4 {
        dt_connect_ext_links_side(nav_mesh, tile, i)
    }
}

dt_connect_ext_links_side :: proc(nav_mesh: ^Dt_Nav_Mesh, tile: ^Dt_Mesh_Tile, side: int) {
    if tile.header == nil {
        return
    }
    
    // Calculate neighbor tile coordinates based on side
    nx := tile.header.x
    ny := tile.header.y
    
    switch side {
    case 0: nx += 1  // East
    case 1: ny += 1  // North
    case 2: nx -= 1  // West
    case 3: ny -= 1  // South
    }
    
    // Find neighbor tile
    neighbor := dt_get_tile_at(nav_mesh, nx, ny, 0)
    if neighbor == nil {
        return
    }
    
    // Find border segments on this tile's side
    MAX_VERTS :: 64
    verts: [MAX_VERTS * 2][3]f32
    nei: [MAX_VERTS * 2]nav_recast.Poly_Ref
    nnei := 0
    
    // Collect border vertices from this tile
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
            nei[nnei] = dt_get_poly_ref_base(nav_mesh, tile) | nav_recast.Poly_Ref(i)
            nei[nnei + 1] = nei[nnei]
            nnei += 2
        }
    }
    
    if nnei == 0 do return
    
    // Find matching segments in neighbor tile
    for i in 0..<neighbor.header.poly_count {
        poly := &neighbor.polys[i]
        
        // Validate neighbor polygon vertex count
        if poly.vert_count > nav_recast.DT_VERTS_PER_POLYGON {
            log.warnf("Neighbor polygon %d has invalid vert_count %d, skipping", i, poly.vert_count)
            continue
        }
        
        nv := int(poly.vert_count)
        
        for j in 0..<nv {
            if poly.neis[j] != 0 do continue  // Not a border edge
            
            // Validate vertex indices
            if poly.verts[j] >= u16(neighbor.header.vert_count) || 
               poly.verts[(j+1) % nv] >= u16(neighbor.header.vert_count) {
                log.warnf("Neighbor polygon %d has invalid vertex indices", i)
                continue
            }
            
            // Check if this edge is on the opposite side
            va := neighbor.verts[poly.verts[j]]
            vb := neighbor.verts[poly.verts[(j+1) % nv]]
            
            opposite_side := (side + 2) % 4
            if !is_edge_on_tile_border(va, vb, neighbor.header.bmin, neighbor.header.bmax, opposite_side) {
                continue
            }
            
            // Find matching segments
            for k in 0..<nnei-1 {
                if segment_intersects(verts[k], verts[k+1], va, vb) {
                    // Create bidirectional link
                    poly_ref := dt_get_poly_ref_base(nav_mesh, neighbor) | nav_recast.Poly_Ref(i)
                    
                    // Validate polygon index
                    poly_idx := u32(nei[k] & nav_recast.Poly_Ref(tile.header.poly_count - 1))
                    if poly_idx >= u32(tile.header.poly_count) {
                        log.warnf("Invalid polygon index %d for external link", poly_idx)
                        continue
                    }
                    
                    // Add link from this tile to neighbor
                    if link_idx, ok := dt_allocate_link(tile, poly_idx); ok {
                        link := &tile.links[link_idx]
                        link.ref = poly_ref
                        link.edge = u8(j)
                        link.side = u8(side)
                        link.bmin = 0
                        link.bmax = 255
                        
                        // Add to polygon's link list
                        link.next = tile.polys[poly_idx].first_link
                        tile.polys[poly_idx].first_link = link_idx
                        
                        // Add reverse link from neighbor to this tile
                        if rev_link_idx, rev_ok := dt_allocate_link(neighbor, u32(i)); rev_ok {
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

dt_disconnect_ext_links :: proc(nav_mesh: ^Dt_Nav_Mesh, tile: ^Dt_Mesh_Tile) {
    if tile.header == nil {
        return
    }
    
    // Get base reference for this tile
    base_ref := dt_get_poly_ref_base(nav_mesh, tile)
    
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
        
        neighbor := dt_get_tile_at(nav_mesh, nx, ny, 0)
        if neighbor == nil {
            continue
        }
        
        // Remove links from neighbor that point to this tile
        for i in 0..<neighbor.header.poly_count {
            poly := &neighbor.polys[i]
            
            // Traverse link list and remove links to this tile
            prev_link: u32 = nav_recast.DT_NULL_LINK
            link_idx := poly.first_link
            
            for link_idx != nav_recast.DT_NULL_LINK {
                link := &neighbor.links[link_idx]
                next_link := link.next
                
                // Check if this link points to the tile being removed
                link_tile_ref := (link.ref >> nav_mesh.poly_bits) >> nav_mesh.salt_bits
                this_tile_ref := (base_ref >> nav_mesh.poly_bits) >> nav_mesh.salt_bits
                
                if link_tile_ref == this_tile_ref {
                    // Remove this link
                    if prev_link == nav_recast.DT_NULL_LINK {
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

dt_allocate_link :: proc(tile: ^Dt_Mesh_Tile, poly: u32) -> (u32, bool) {
    if tile.links_free_list == nav_recast.DT_NULL_LINK {
        return nav_recast.DT_NULL_LINK, false
    }
    
    if tile.links_free_list >= u32(len(tile.links)) {
        return nav_recast.DT_NULL_LINK, false
    }
    
    link_idx := tile.links_free_list
    tile.links_free_list = tile.links[link_idx].next
    return link_idx, true
}

dt_get_poly_ref_base :: proc(nav_mesh: ^Dt_Nav_Mesh, tile: ^Dt_Mesh_Tile) -> nav_recast.Poly_Ref {
    if tile == nil {
        return nav_recast.Poly_Ref(0)
    }
    
    // Calculate tile index
    tile_index := u32(uintptr(tile) - uintptr(&nav_mesh.tiles[0])) / size_of(Dt_Mesh_Tile)
    
    // Encode reference with salt, tile index, and zero polygon index
    salt := tile.salt & ((1 << nav_mesh.salt_bits) - 1)
    return nav_recast.Poly_Ref((salt << (nav_mesh.tile_bits + nav_mesh.poly_bits)) | 
                             (tile_index << nav_mesh.poly_bits))
}

// Utility functions

dt_compute_tile_hash :: proc(x: i32, y: i32, mask: i32) -> i32 {
    // Use constants that fit in i32 range
    h1: i32 = -1918454949  // 0x8da6b343 as signed i32
    h2: i32 = -669632447   // 0xd8163841 as signed i32
    h := h1 * x + h2 * y
    return h & mask
}

dt_unlink_tile :: proc(nav_mesh: ^Dt_Nav_Mesh, tile: ^Dt_Mesh_Tile) {
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

dt_ilog2 :: proc(v: u32) -> u32 {
    r := u32(0)
    val := v
    for val != 0 {
        r += 1
        val >>= 1
    }
    return r
}

dt_next_pow2 :: proc(v: u32) -> u32 {
    val := v - 1
    val |= val >> 1
    val |= val >> 2
    val |= val >> 4
    val |= val >> 8
    val |= val >> 16
    return val + 1
}

// Tile reference encoding
dt_encode_tile_ref :: proc(nav_mesh: ^Dt_Nav_Mesh, salt: u32, tile_index: u32) -> u32 {
    return (salt << nav_mesh.tile_bits) | tile_index
}

dt_decode_tile_ref :: proc(nav_mesh: ^Dt_Nav_Mesh, ref: nav_recast.Tile_Ref) -> u32 {
    tile_mask := (u32(1) << nav_mesh.tile_bits) - 1
    return u32(ref) & tile_mask
}

dt_decode_tile_ref_salt :: proc(nav_mesh: ^Dt_Nav_Mesh, ref: nav_recast.Tile_Ref) -> u32 {
    salt_mask := (u32(1) << nav_mesh.salt_bits) - 1
    return (u32(ref) >> nav_mesh.tile_bits) & salt_mask
}

// Helper functions for external link connection

// Check if an edge is on a specific border of a tile
is_edge_on_tile_border :: proc(va, vb: [3]f32, bmin, bmax: [3]f32, side: int) -> bool {
    EPSILON :: 0.01
    
    switch side {
    case 0:  // East border (max X)
        return math.abs(va.x - bmax.x) < EPSILON && math.abs(vb.x - bmax.x) < EPSILON
    case 1:  // North border (max Z)
        return math.abs(va.z - bmax.z) < EPSILON && math.abs(vb.z - bmax.z) < EPSILON
    case 2:  // West border (min X)
        return math.abs(va.x - bmin.x) < EPSILON && math.abs(vb.x - bmin.x) < EPSILON
    case 3:  // South border (min Z)
        return math.abs(va.z - bmin.z) < EPSILON && math.abs(vb.z - bmin.z) < EPSILON
    }
    return false
}

// Check if two line segments intersect in 2D (XZ plane)
segment_intersects :: proc(a1, a2, b1, b2: [3]f32) -> bool {
    EPSILON :: 0.01
    
    // Extract 2D coordinates (X, Z)
    ax1, az1 := a1.x, a1.z
    ax2, az2 := a2.x, a2.z
    bx1, bz1 := b1.x, b1.z
    bx2, bz2 := b2.x, b2.z
    
    // Check for overlap in segment bounds
    min_ax, max_ax := min(ax1, ax2), max(ax1, ax2)
    min_az, max_az := min(az1, az2), max(az1, az2)
    min_bx, max_bx := min(bx1, bx2), max(bx1, bx2)
    min_bz, max_bz := min(bz1, bz2), max(bz1, bz2)
    
    // Check if bounding boxes overlap
    if max_ax < min_bx - EPSILON || min_ax > max_bx + EPSILON ||
       max_az < min_bz - EPSILON || min_az > max_bz + EPSILON {
        return false
    }
    
    // For border segments, they should overlap if they're on the same line
    // Check if segments are collinear and overlapping
    dx1 := ax2 - ax1
    dz1 := az2 - az1
    dx2 := bx2 - bx1
    dz2 := bz2 - bz1
    
    // Cross product to check if lines are parallel
    cross := dx1 * dz2 - dz1 * dx2
    if math.abs(cross) > EPSILON {
        return false  // Not parallel
    }
    
    // Lines are parallel, check if they're on the same line
    dx3 := bx1 - ax1
    dz3 := bz1 - az1
    cross2 := dx1 * dz3 - dz1 * dx3
    if math.abs(cross2) > EPSILON {
        return false  // Parallel but not collinear
    }
    
    // Segments are collinear, check if they overlap
    return true
}

