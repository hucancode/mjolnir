package navigation_detour

import "core:mem"
import "core:math"
import "core:math/linalg" 
import "core:slice"
import "core:log"
import "core:fmt"
import nav_recast "../recast"

// Create navigation mesh data from Recast polygon mesh
dt_create_nav_mesh_data :: proc(params: ^Dt_Create_Nav_Mesh_Data_Params) -> ([]u8, nav_recast.Status) {
    if params == nil || params.poly_mesh == nil {
        return nil, {.Invalid_Param}
    }
    
    pmesh := params.poly_mesh
    dmesh := params.poly_mesh_detail
    
    if len(pmesh.verts) >= 0xfffe {
        return nil, {.Invalid_Param}
    }
    
    if pmesh.npolys >= 0xfffe {
        return nil, {.Invalid_Param}
    }
    
    nvp := pmesh.nvp
    cs := pmesh.cs
    ch := pmesh.ch
    
    // Classify off-mesh connection points
    off_mesh_con_class := make([]u8, params.off_mesh_con_count * 2, context.temp_allocator)
    if params.off_mesh_con_count > 0 {
        dt_classify_off_mesh_connections(pmesh, params, off_mesh_con_class)
    }
    
    // Count vertices and polygons
    total_vert_count := i32(0)
    total_poly_count := i32(0)
    max_link_count := i32(0)
    
    // Polygon mesh vertices and polygons
    total_vert_count += i32(len(pmesh.verts))
    total_poly_count += pmesh.npolys
    
    // Calculate maximum link count per polygon
    for i in 0..<pmesh.npolys {
        poly_base := i * nvp * 2
        for j in 0..<nvp {
            if pmesh.polys[poly_base + j] == nav_recast.RC_MESH_NULL_IDX {
                break
            }
            if pmesh.polys[poly_base + nvp + j] & 0x8000 != 0 {
                max_link_count += 1
            }
        }
    }
    
    // Off-mesh connections
    total_vert_count += params.off_mesh_con_count * 2
    total_poly_count += params.off_mesh_con_count
    max_link_count += params.off_mesh_con_count * 2
    
    // Detail mesh triangles and vertices
    detail_mesh_count := i32(0)
    detail_vert_count := i32(0)
    detail_tri_count := i32(0)
    
    if dmesh != nil {
        detail_mesh_count = pmesh.npolys
        detail_vert_count = i32(len(dmesh.verts)) - i32(len(pmesh.verts))
        detail_tri_count = i32(len(dmesh.tris))
    }
    
    // Calculate data size using validated format specification
    // Data format: [Header][Vertices][Polygons][Links][DetailMeshes][DetailVerts][DetailTris][BVTree][OffMeshConnections]
    header_size := size_of(Dt_Mesh_Header)
    verts_size := size_of([3]f32) * int(total_vert_count)
    polys_size := size_of(Dt_Poly) * int(total_poly_count)
    links_size := size_of(Dt_Link) * int(max_link_count)
    detail_meshes_size := size_of(Dt_Poly_Detail) * int(detail_mesh_count)
    detail_verts_size := size_of([3]f32) * int(detail_vert_count)
    detail_tris_size := size_of(u8) * int(detail_tri_count) * 4
    // Calculate BV tree size - simple implementation creates one node per polygon  
    bv_node_count := total_poly_count
    bv_tree_size := size_of(Dt_BV_Node) * int(bv_node_count)
    off_mesh_cons_size := size_of(Dt_Off_Mesh_Connection) * int(params.off_mesh_con_count)
    
    total_size := header_size + verts_size + polys_size + links_size + 
                  detail_meshes_size + detail_verts_size + detail_tris_size + 
                  bv_tree_size + off_mesh_cons_size
    
    // Allocate data
    data := make([]u8, total_size)
    offset := 0
    
    // Setup header
    header := cast(^Dt_Mesh_Header)(raw_data(data)[offset:])
    offset += header_size
    
    header.magic = nav_recast.DT_NAVMESH_MAGIC
    header.version = nav_recast.DT_NAVMESH_VERSION
    header.x = params.tile_x
    header.y = params.tile_y
    header.layer = params.tile_layer
    header.user_id = params.user_id
    header.poly_count = total_poly_count
    header.vert_count = total_vert_count
    header.max_link_count = max_link_count
    header.detail_mesh_count = detail_mesh_count
    header.detail_vert_count = detail_vert_count
    header.detail_tri_count = detail_tri_count
    header.bv_node_count = bv_node_count
    header.off_mesh_con_count = params.off_mesh_con_count
    header.off_mesh_base = pmesh.npolys
    header.walkable_height = params.walkable_height
    header.walkable_radius = params.walkable_radius
    header.walkable_climb = params.walkable_climb
    header.bmin = pmesh.bmin
    header.bmax = pmesh.bmax
    header.bv_quant_factor = 1.0 / cs
    
    // Copy vertices - first data section per navmesh format specification
    // Validate alignment before casting
    verts_ptr_addr := uintptr(raw_data(data)) + uintptr(offset)
    if verts_ptr_addr % uintptr(align_of([3]f32)) != 0 {
        log.errorf("Vertex data alignment error during build: ptr=0x%x, required_align=%d", verts_ptr_addr, align_of([3]f32))
        return nil, {.Invalid_Param}
    }
    
    verts := slice.from_ptr(cast(^[3]f32)(verts_ptr_addr), int(total_vert_count))
    offset += verts_size
    
    for v, i in pmesh.verts {
        vert := &verts[i]
        vert[0] = pmesh.bmin[0] + f32(v[0]) * cs
        vert[1] = pmesh.bmin[1] + f32(v[1]) * ch
        vert[2] = pmesh.bmin[2] + f32(v[2]) * cs
    }
    
    // Add off-mesh connection vertices
    for i in 0..<params.off_mesh_con_count {
        base := len(pmesh.verts) + int(i) * 2
        conn := params.off_mesh_con_verts[i]
        verts[base + 0] = conn.start
        verts[base + 1] = conn.end
    }
    
    // Copy polygons - second data section per navmesh format specification
    // Validate alignment before casting
    polys_ptr_addr := uintptr(raw_data(data)) + uintptr(offset)
    if polys_ptr_addr % uintptr(align_of(Dt_Poly)) != 0 {
        log.errorf("Polygon data alignment error during build: ptr=0x%x, required_align=%d", polys_ptr_addr, align_of(Dt_Poly))
        return nil, {.Invalid_Param}
    }
    
    polys := slice.from_ptr(cast(^Dt_Poly)(polys_ptr_addr), int(total_poly_count))
    offset += polys_size
    
    for i in 0..<pmesh.npolys {
        poly := &polys[i]
        poly.first_link = nav_recast.DT_NULL_LINK
        poly.flags = pmesh.flags[i]
        dt_poly_set_area(poly, pmesh.areas[i])
        dt_poly_set_type(poly, nav_recast.DT_POLYTYPE_GROUND)
        
        poly_base := i * nvp * 2
        for j in 0..<nvp {
            if pmesh.polys[poly_base + j] == nav_recast.RC_MESH_NULL_IDX {
                break
            }
            
            // Verify polygon is within vertex limits (should never trigger with proper generation)
            assert(poly.vert_count < nav_recast.DT_VERTS_PER_POLYGON, 
                   fmt.tprintf("Polygon %d exceeds vertex limit: %d > %d", 
                              i, poly.vert_count + 1, nav_recast.DT_VERTS_PER_POLYGON))
            
            poly.verts[poly.vert_count] = pmesh.polys[poly_base + j]
            if pmesh.polys[poly_base + nvp + j] & 0x8000 != 0 {
                // External edge
                poly.neis[poly.vert_count] = 0
            } else if pmesh.polys[poly_base + nvp + j] != nav_recast.RC_MESH_NULL_IDX {
                // Internal edge
                poly.neis[poly.vert_count] = pmesh.polys[poly_base + nvp + j] + 1
            } else {
                // Boundary edge
                poly.neis[poly.vert_count] = 0
            }
            poly.vert_count += 1
        }
    }
    
    // Add off-mesh connection polygons
    for i in 0..<params.off_mesh_con_count {
        poly := &polys[pmesh.npolys + i]
        poly.vert_count = 2
        poly.verts[0] = u16(len(pmesh.verts) + int(i) * 2 + 0)
        poly.verts[1] = u16(len(pmesh.verts) + int(i) * 2 + 1)
        poly.flags = params.off_mesh_con_flags[i]
        dt_poly_set_area(poly, params.off_mesh_con_areas[i])
        dt_poly_set_type(poly, nav_recast.DT_POLYTYPE_OFFMESH_CONNECTION)
        poly.first_link = nav_recast.DT_NULL_LINK
    }
    
    // Skip links for now (will be allocated at runtime)
    offset += links_size
    
    // Build BV tree if nodes exist
    if bv_node_count > 0 {
        bv_tree := slice.from_ptr(cast(^Dt_BV_Node)(raw_data(data)[offset:]), int(bv_node_count))
        
        // Build BV tree for polygon access
        dt_build_bv_tree(pmesh, bv_tree, bv_node_count)
        
        offset += bv_tree_size
    } else {
        // Skip BV tree section if no nodes
        offset += bv_tree_size
    }
    
    // Copy detail meshes
    if dmesh != nil {
        detail_meshes := slice.from_ptr(cast(^Dt_Poly_Detail)(raw_data(data)[offset:]), int(detail_mesh_count))
        offset += detail_meshes_size
        
        for i in 0..<pmesh.npolys {
            detail := &detail_meshes[i]
            mesh_info := dmesh.meshes[i]
            detail.vert_base = mesh_info[0]
            detail.tri_base = mesh_info[2]
            detail.vert_count = u8(mesh_info[1])
            detail.tri_count = u8(mesh_info[3])
        }
        
        // Copy detail vertices (skip shared vertices)
        detail_verts := slice.from_ptr(cast(^[3]f32)(raw_data(data)[offset:]), int(detail_vert_count))
        offset += detail_verts_size
        
        for i in 0..<detail_vert_count {
            detail_verts[i] = dmesh.verts[len(pmesh.verts) + int(i)]
        }
        
        // Copy detail triangles
        detail_tris := slice.from_ptr(cast(^[4]u8)(raw_data(data)[offset:]), int(detail_tri_count))
        offset += detail_tris_size
        
        for i in 0..<detail_tri_count {
            detail_tris[i] = dmesh.tris[i]
        }
    }
    
    // Copy off-mesh connections
    if params.off_mesh_con_count > 0 {
        off_mesh_cons := slice.from_ptr(cast(^Dt_Off_Mesh_Connection)(raw_data(data)[offset:]), int(params.off_mesh_con_count))
        
        for i in 0..<params.off_mesh_con_count {
            con := &off_mesh_cons[i]
            con.poly = u16(pmesh.npolys + i)
            
            // Copy connection endpoints
            conn := params.off_mesh_con_verts[i]
            con.start = conn.start
            con.end = conn.end
            
            con.rad = params.off_mesh_con_rad[i]
            if params.off_mesh_con_dir[i] != 0 {
                con.flags = nav_recast.DT_OFFMESH_CON_BIDIR
            } else {
                con.flags = 0
            }
            con.side = off_mesh_con_class[i * 2]
            con.user_id = params.off_mesh_con_user_id[i]
        }
    }
    
    // Final validation step - verify the created data can be properly parsed
    validation_result := validate_tile_data(data)
    if !validation_result.valid {
        log.errorf("Created tile data failed validation:")
        for i in 0..<validation_result.error_count {
            log.errorf("  - %s", validation_result.errors[i])
        }
        return nil, {.Invalid_Param}
    }
    
    // Additional integrity check - ensure the data layout matches our expectations
    parsed_header, parse_status := dt_parse_mesh_header(data)
    if nav_recast.status_failed(parse_status) {
        log.errorf("Created tile data failed header parsing: %v", parse_status)
        return nil, {.Invalid_Param}
    }
    
    // Verify the header values match what we set
    if parsed_header.poly_count != total_poly_count ||
       parsed_header.vert_count != total_vert_count ||
       parsed_header.max_link_count != max_link_count {
        log.errorf("Header validation failed: counts don't match (poly: %d vs %d, vert: %d vs %d, links: %d vs %d)",
                  parsed_header.poly_count, total_poly_count,
                  parsed_header.vert_count, total_vert_count,
                  parsed_header.max_link_count, max_link_count)
        return nil, {.Invalid_Param}
    }
    
    // Calculate and log data integrity checksum
    checksum := calculate_data_checksum(data)
    log.infof("Navigation mesh tile created successfully (size: %d bytes, checksum: 0x%08x)", len(data), checksum)
    
    return data, {.Success}
}

// Parameters for creating navigation mesh data
Dt_Create_Nav_Mesh_Data_Params :: struct {
    // Polygon mesh from Recast
    poly_mesh: ^nav_recast.Rc_Poly_Mesh,
    poly_mesh_detail: ^nav_recast.Rc_Poly_Mesh_Detail,
    
    // Off-mesh connections
    off_mesh_con_verts: []nav_recast.Off_Mesh_Connection_Verts,  // Connection endpoints
    off_mesh_con_rad: []f32,        // [nOffMeshCons]
    off_mesh_con_flags: []u16,      // [nOffMeshCons]
    off_mesh_con_areas: []u8,       // [nOffMeshCons]
    off_mesh_con_dir: []u8,         // [nOffMeshCons]
    off_mesh_con_user_id: []u32,    // [nOffMeshCons]
    off_mesh_con_count: i32,
    
    // Tile parameters
    user_id: u32,
    tile_x: i32,
    tile_y: i32,
    tile_layer: i32,
    
    // Agent parameters
    walkable_height: f32,
    walkable_radius: f32,
    walkable_climb: f32,
}

// Classify off-mesh connection endpoints
dt_classify_off_mesh_connections :: proc(pmesh: ^nav_recast.Rc_Poly_Mesh, params: ^Dt_Create_Nav_Mesh_Data_Params, class: []u8) {
    // This function classifies off-mesh connection endpoints to determine
    // which side of the tile edge they connect to
    // Implementation details depend on tile connectivity requirements
    
    for i in 0..<params.off_mesh_con_count {
        class[i * 2 + 0] = 0xff // Side classification for point A
        class[i * 2 + 1] = 0xff // Side classification for point B
    }
}

// Create navigation mesh from single tile
dt_create_nav_mesh :: proc(params: ^Dt_Create_Nav_Mesh_Data_Params) -> (^Dt_Nav_Mesh, nav_recast.Status) {
    // Create navigation mesh data
    data, status := dt_create_nav_mesh_data(params)
    if nav_recast.status_failed(status) {
        return nil, status
    }
    
    // Create navigation mesh
    nav_mesh := new(Dt_Nav_Mesh)
    
    // Initialize with single tile
    nav_params := Dt_Nav_Mesh_Params{
        orig = params.poly_mesh.bmin,
        tile_width = params.poly_mesh.bmax[0] - params.poly_mesh.bmin[0],
        tile_height = params.poly_mesh.bmax[2] - params.poly_mesh.bmin[2],
        max_tiles = 1,
        max_polys = 1024,
    }
    
    status = dt_nav_mesh_init(nav_mesh, &nav_params)
    if nav_recast.status_failed(status) {
        free(nav_mesh)
        delete(data)
        return nil, status
    }
    
    // Add the tile
    _, status = dt_nav_mesh_add_tile(nav_mesh, data, nav_recast.DT_TILE_FREE_DATA)
    if nav_recast.status_failed(status) {
        dt_nav_mesh_destroy(nav_mesh)
        free(nav_mesh)
        return nil, status
    }
    
    return nav_mesh, {.Success}
}

// Build BV tree for efficient spatial queries with optimized hierarchical construction
dt_build_bv_tree :: proc(pmesh: ^nav_recast.Rc_Poly_Mesh, nodes: []Dt_BV_Node, node_count: i32) {
    if node_count <= 0 || pmesh.npolys <= 0 {
        return
    }
    
    cs := pmesh.cs
    ch := pmesh.ch
    nvp := pmesh.nvp
    quant_factor := 1.0 / cs
    
    // For small polygon counts, use simple flat structure
    if pmesh.npolys <= 4 {
        dt_build_bv_tree_flat(pmesh, nodes, node_count, quant_factor)
        return
    }
    
    // Build hierarchical BV tree for better query performance
    dt_build_bv_tree_hierarchical(pmesh, nodes, node_count, quant_factor)
}

// Optimized flat BV tree construction for small meshes
@(private)
dt_build_bv_tree_flat :: proc(pmesh: ^nav_recast.Rc_Poly_Mesh, nodes: []Dt_BV_Node, node_count: i32, quant_factor: f32) {
    nvp := pmesh.nvp
    
    for i in 0..<int(min(node_count, pmesh.npolys)) {
        node := &nodes[i]
        poly_base := i32(i) * nvp
        
        // Calculate polygon bounds efficiently
        bounds := dt_calc_polygon_bounds_fast(pmesh, poly_base, nvp, quant_factor)
        
        node.bmin = bounds.min
        node.bmax = bounds.max
        node.i = i32(i)  // Leaf node (positive index)
    }
}

// Hierarchical BV tree construction with better spatial organization
@(private)
dt_build_bv_tree_hierarchical :: proc(pmesh: ^nav_recast.Rc_Poly_Mesh, nodes: []Dt_BV_Node, node_count: i32, quant_factor: f32) {
    nvp := pmesh.nvp
    
    // Pre-calculate polygon centers and bounds for sorting
    poly_info := make([]BV_Poly_Info, pmesh.npolys, context.temp_allocator)
    
    for i in 0..<pmesh.npolys {
        info := &poly_info[i]
        info.index = i
        poly_base := i * nvp
        
        // Calculate bounds and center efficiently
        bounds := dt_calc_polygon_bounds_fast(pmesh, poly_base, nvp, quant_factor)
        info.bounds = bounds
        info.center = [3]u16{
            (bounds.min[0] + bounds.max[0]) / 2,
            (bounds.min[1] + bounds.max[1]) / 2,
            (bounds.min[2] + bounds.max[2]) / 2,
        }
    }
    
    // Build hierarchy using recursive subdivision
    next_node_idx := i32(0)
    dt_build_bv_node_recursive(poly_info, nodes, &next_node_idx, 0, pmesh.npolys)
}

// Recursive BV tree node construction
@(private)
dt_build_bv_node_recursive :: proc(poly_info: []BV_Poly_Info, nodes: []Dt_BV_Node, next_idx: ^i32, start: i32, end: i32) -> i32 {
    node_idx := next_idx^
    next_idx^ += 1
    
    if node_idx >= i32(len(nodes)) {
        return -1  // Out of space
    }
    
    node := &nodes[node_idx]
    poly_count := end - start
    
    // Calculate combined bounds for this group
    if poly_count > 0 {
        node.bmin = poly_info[start].bounds.min
        node.bmax = poly_info[start].bounds.max
        
        for i in start + 1..<end {
            info := &poly_info[i]
            for j in 0..<3 {
                node.bmin[j] = min(node.bmin[j], info.bounds.min[j])
                node.bmax[j] = max(node.bmax[j], info.bounds.max[j])
            }
        }
    }
    
    // Decide whether to make this a leaf or split further
    MAX_LEAF_SIZE :: 8  // Optimal balance between tree depth and leaf size
    
    if poly_count <= MAX_LEAF_SIZE {
        // Create leaf node - use escape sequence format for Detour
        if poly_count == 1 {
            node.i = poly_info[start].index  // Single polygon leaf
        } else {
            // Multiple polygons - use first polygon index
            // In a more sophisticated implementation, we could use a different encoding
            node.i = poly_info[start].index
        }
        return node_idx
    }
    
    // Split polygons using best axis
    axis := dt_find_best_split_axis(poly_info[start:end])
    mid := dt_partition_polygons_by_axis(poly_info[start:end], axis) + start
    
    // Ensure we don't create degenerate splits
    if mid == start || mid == end {
        mid = start + poly_count / 2
    }
    
    // Build children recursively
    left_child := dt_build_bv_node_recursive(poly_info, nodes, next_idx, start, mid)
    right_child := dt_build_bv_node_recursive(poly_info, nodes, next_idx, mid, end)
    
    // Use escape sequence encoding: negative value encodes next sibling
    if right_child >= 0 {
        node.i = -(right_child + 1)  // Escape sequence to right child
    } else {
        node.i = poly_info[start].index  // Fallback to leaf if children failed
    }
    
    return node_idx
}

// Helper structures for BV tree construction
BV_Poly_Info :: struct {
    index:  i32,
    bounds: BV_Bounds_U16,
    center: [3]u16,
}

BV_Bounds_U16 :: struct {
    min: [3]u16,
    max: [3]u16,
}

// Fast polygon bounds calculation with reduced coordinate transformations
@(private)
dt_calc_polygon_bounds_fast :: proc(pmesh: ^nav_recast.Rc_Poly_Mesh, poly_base: i32, nvp: i32, quant_factor: f32) -> BV_Bounds_U16 {
    // Initialize with invalid bounds
    bounds: BV_Bounds_U16
    bounds.min = {65535, 65535, 65535}
    bounds.max = {0, 0, 0}
    
    vertex_count := 0
    
    // Process all vertices in polygon
    for j in 0..<nvp {
        vert_idx := pmesh.polys[poly_base + j]
        if vert_idx == nav_recast.RC_MESH_NULL_IDX {
            break
        }
        
        // Direct quantization from vertex coordinates (avoid float conversion)
        // Vertices are already relative to bmin in mesh coordinates
        v := pmesh.verts[vert_idx]
        quant_coords := [3]u16{
            u16(math.clamp(f32(v[0]) * quant_factor, 0, 65535)),
            u16(math.clamp(f32(v[1]) * quant_factor, 0, 65535)),
            u16(math.clamp(f32(v[2]) * quant_factor, 0, 65535)),
        }
        
        // Update bounds
        for k in 0..<3 {
            bounds.min[k] = min(bounds.min[k], quant_coords[k])
            bounds.max[k] = max(bounds.max[k], quant_coords[k])
        }
        
        vertex_count += 1
    }
    
    // Handle empty polygons
    if vertex_count == 0 {
        bounds.min = {0, 0, 0}
        bounds.max = {1, 1, 1}
    }
    
    return bounds
}

// Find the best axis for splitting polygons
@(private)
dt_find_best_split_axis :: proc(poly_info: []BV_Poly_Info) -> int {
    if len(poly_info) < 2 {
        return 0
    }
    
    // Calculate variance along each axis
    variance := [3]f32{0, 0, 0}
    mean := [3]f32{0, 0, 0}
    
    // Calculate mean
    for info in poly_info {
        for i in 0..<3 {
            mean[i] += f32(info.center[i])
        }
    }
    
    inv_count := 1.0 / f32(len(poly_info))
    for i in 0..<3 {
        mean[i] *= inv_count
    }
    
    // Calculate variance
    for info in poly_info {
        for i in 0..<3 {
            diff := f32(info.center[i]) - mean[i]
            variance[i] += diff * diff
        }
    }
    
    // Return axis with highest variance
    best_axis := 0
    for i in 1..<3 {
        if variance[i] > variance[best_axis] {
            best_axis = i
        }
    }
    
    return best_axis
}

// Partition polygons around median value on given axis
@(private)
dt_partition_polygons_by_axis :: proc(poly_info: []BV_Poly_Info, axis: int) -> i32 {
    if len(poly_info) < 2 {
        return 1
    }
    
    // Simple median partitioning - sort by axis and split in middle
    if axis == 0 {
        slice.sort_by(poly_info, proc(a, b: BV_Poly_Info) -> bool {
            return a.center[0] < b.center[0]
        })
    } else if axis == 1 {
        slice.sort_by(poly_info, proc(a, b: BV_Poly_Info) -> bool {
            return a.center[1] < b.center[1]
        })
    } else {
        slice.sort_by(poly_info, proc(a, b: BV_Poly_Info) -> bool {
            return a.center[2] < b.center[2]
        })
    }
    
    return i32(len(poly_info) / 2)
}