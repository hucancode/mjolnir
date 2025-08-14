package test_detour_crowd

import "core:testing"
import "core:mem"
import "core:math"
import "core:math/linalg"
import "core:time"
import "core:fmt"
import recast "../../mjolnir/navigation/recast"
import detour "../../mjolnir/navigation/detour"
import crowd "../../mjolnir/navigation/detour_crowd"

// Create a simple test navigation mesh with multiple polygons
create_test_nav_mesh :: proc(t: ^testing.T) -> ^detour.Nav_Mesh {
    // Create a 3x3 grid of polygons for more interesting pathfinding
    nav_mesh := new(detour.Nav_Mesh)
    
    params := detour.Nav_Mesh_Params{
        orig = {0, 0, 0},
        tile_width = 30.0,
        tile_height = 30.0,
        max_tiles = 1,
        max_polys = 100,
    }
    
    status := detour.nav_mesh_init(nav_mesh, &params)
    if recast.status_failed(status) {
        testing.fail_now(t, "Failed to initialize test navigation mesh")
    }
    
    // Create tile data with a 3x3 grid of polygons
    data := create_grid_tile_data(3, 3, 10.0)
    
    tile_ref, add_status := detour.nav_mesh_add_tile(nav_mesh, data, recast.DT_TILE_FREE_DATA)
    if recast.status_failed(add_status) {
        testing.fail_now(t, "Failed to add test tile to navigation mesh")
    }
    
    // Connect internal links for the tile
    tile, tile_status := detour.get_tile_by_ref(nav_mesh, tile_ref)
    if recast.status_succeeded(tile_status) && tile != nil {
        detour.connect_int_links(nav_mesh, tile)
    }
    
    return nav_mesh
}

// Create tile data for a grid of polygons
create_grid_tile_data :: proc(grid_x, grid_z: i32, cell_size: f32) -> []u8 {
    // Calculate data requirements
    nverts := (grid_x + 1) * (grid_z + 1)
    npolys := grid_x * grid_z
    
    header_size := size_of(detour.Mesh_Header)
    verts_size := size_of([3]f32) * int(nverts)
    polys_size := size_of(detour.Poly) * int(npolys)
    detail_meshes_size := size_of(detour.Poly_Detail) * int(npolys)
    bv_tree_size := size_of(detour.BV_Node) * int(npolys)
    
    // Calculate link count - each polygon can have up to 4 neighbors
    // In a grid, internal polygons have 4 neighbors, edge polygons have 2-3
    // To be safe, allocate max possible: 6 links per polygon to ensure enough space
    link_count := npolys * 6
    links_size := size_of(detour.Link) * int(link_count)
    
    total_size := header_size + verts_size + polys_size + links_size + 
                  detail_meshes_size + bv_tree_size
    
    data := make([]u8, total_size)
    
    // Setup header
    header := cast(^detour.Mesh_Header)raw_data(data)
    header.magic = recast.DT_NAVMESH_MAGIC
    header.version = recast.DT_NAVMESH_VERSION
    header.x = 0
    header.y = 0
    header.layer = 0
    header.poly_count = npolys
    header.vert_count = nverts
    header.max_link_count = link_count
    header.detail_mesh_count = npolys
    header.detail_vert_count = 0
    header.detail_tri_count = 0
    header.bv_node_count = npolys
    header.off_mesh_con_count = 0
    header.off_mesh_base = 0
    header.bmin = {0, 0, 0}
    header.bmax = {f32(grid_x) * cell_size, 1, f32(grid_z) * cell_size}
    header.walkable_height = 2.0
    header.walkable_radius = 0.6
    header.walkable_climb = 0.9
    header.bv_quant_factor = 1.0 / 0.3
    
    offset := uintptr(header_size)
    
    // Setup vertices in a grid
    verts := cast(^[3]f32)(uintptr(raw_data(data)) + offset)
    verts_array := mem.slice_ptr(verts, int(nverts))
    offset += uintptr(verts_size)
    
    vert_idx := 0
    for z in 0..=grid_z {
        for x in 0..=grid_x {
            verts_array[vert_idx] = {f32(x) * cell_size, 0, f32(z) * cell_size}
            vert_idx += 1
        }
    }
    
    // Setup polygons (quads)
    polys := cast(^detour.Poly)(uintptr(raw_data(data)) + offset)
    polys_array := mem.slice_ptr(polys, int(npolys))
    offset += uintptr(polys_size)
    
    poly_idx := 0
    for z in 0..<grid_z {
        for x in 0..<grid_x {
            poly := &polys_array[poly_idx]
            
            // Quad vertices (clockwise for correct portal orientation)
            v0 := u16(z * (grid_x + 1) + x)
            v1 := u16((z + 1) * (grid_x + 1) + x)
            v2 := u16((z + 1) * (grid_x + 1) + x + 1)
            v3 := u16(z * (grid_x + 1) + x + 1)
            
            poly.verts[0] = v0
            poly.verts[1] = v1
            poly.verts[2] = v2
            poly.verts[3] = v3
            poly.vert_count = 4
            
            // Set up neighbor connections
            for i in 0..<recast.DT_VERTS_PER_POLYGON {
                poly.neis[i] = 0  // External by default (0 means no connection)
            }
            
            // Connect to neighbors in grid (updated for clockwise vertices)
            // Edge 0: v0-v1 (left edge)
            // Edge 1: v1-v2 (top edge)  
            // Edge 2: v2-v3 (right edge)
            // Edge 3: v3-v0 (bottom edge)
            if x > 0 {
                // Left neighbor
                poly.neis[0] = u16(poly_idx - 1) | 0x8000  // Internal link to left
            }
            if x < grid_x - 1 {
                // Right neighbor
                poly.neis[2] = u16(poly_idx + 1) | 0x8000  // Internal link to right
            }
            if z > 0 {
                // Bottom neighbor
                poly.neis[3] = u16(i32(poly_idx) - grid_x) | 0x8000  // Internal link to bottom
            }
            if z < grid_z - 1 {
                // Top neighbor
                poly.neis[1] = u16(i32(poly_idx) + grid_x) | 0x8000  // Internal link to top
            }
            
            poly.flags = 1  // Walkable
            detour.poly_set_area(poly, recast.RC_WALKABLE_AREA)
            detour.poly_set_type(poly, recast.DT_POLYTYPE_GROUND)
            
            poly_idx += 1
        }
    }
    
    // Initialize links array (will be properly set up by connect_int_links)
    links := cast(^detour.Link)(uintptr(raw_data(data)) + offset)
    links_array := mem.slice_ptr(links, int(link_count))
    offset += uintptr(links_size)
    
    // Initialize all links to invalid (they'll be set up by connect_int_links)
    for i in 0..<link_count {
        links_array[i].ref = recast.INVALID_POLY_REF
        links_array[i].next = recast.DT_NULL_LINK
        links_array[i].edge = 0
        links_array[i].side = 0
        links_array[i].bmin = 0
        links_array[i].bmax = 0
    }
    
    // Setup detail meshes (simplified - no extra detail)
    detail_meshes := cast(^detour.Poly_Detail)(uintptr(raw_data(data)) + offset)
    detail_meshes_array := mem.slice_ptr(detail_meshes, int(npolys))
    offset += uintptr(detail_meshes_size)
    
    for i in 0..<npolys {
        detail := &detail_meshes_array[i]
        detail.vert_base = 0
        detail.vert_count = 0
        detail.tri_base = 0
        detail.tri_count = 0
    }
    
    // Setup BV tree (simplified)
    bv_tree := cast(^detour.BV_Node)(uintptr(raw_data(data)) + offset)
    bv_tree_array := mem.slice_ptr(bv_tree, int(npolys))
    
    for i in 0..<npolys {
        node := &bv_tree_array[i]
        // Calculate bounds for this polygon
        poly := &polys_array[i]
        
        min_pos := [3]f32{math.F32_MAX, math.F32_MAX, math.F32_MAX}
        max_pos := [3]f32{-math.F32_MAX, -math.F32_MAX, -math.F32_MAX}
        
        for j in 0..<int(poly.vert_count) {
            v := verts_array[poly.verts[j]]
            min_pos = {min(min_pos.x, v.x), min(min_pos.y, v.y), min(min_pos.z, v.z)}
            max_pos = {max(max_pos.x, v.x), max(max_pos.y, v.y), max(max_pos.z, v.z)}
        }
        
        // Quantize bounds
        quant_factor := header.bv_quant_factor
        node.bmin[0] = u16((min_pos.x - header.bmin.x) * quant_factor)
        node.bmin[1] = u16((min_pos.y - header.bmin.y) * quant_factor)
        node.bmin[2] = u16((min_pos.z - header.bmin.z) * quant_factor)
        node.bmax[0] = u16((max_pos.x - header.bmin.x) * quant_factor)
        node.bmax[1] = u16((max_pos.y - header.bmin.y) * quant_factor)
        node.bmax[2] = u16((max_pos.z - header.bmin.z) * quant_factor)
        node.i = i32(i)
    }
    
    return data
}

// Clean up test navigation mesh
destroy_test_nav_mesh :: proc(nav_mesh: ^detour.Nav_Mesh) {
    detour.nav_mesh_destroy(nav_mesh)
    free(nav_mesh)
}

// Test crowd wrapper to manage resources
Test_Crowd_Context :: struct {
    crowd: ^crowd.Crowd,
    nav_query: ^detour.Nav_Mesh_Query,
}

// Create a populated crowd for testing
create_test_crowd :: proc(t: ^testing.T, nav_mesh: ^detour.Nav_Mesh, max_agents: i32 = 10) -> ^crowd.Crowd {
    // Create navigation query
    nav_query := new(detour.Nav_Mesh_Query)
    status := detour.nav_mesh_query_init(nav_query, nav_mesh, 256)
    testing.expect(t, recast.status_succeeded(status), "Failed to init nav query")
    
    // Create crowd
    crowd_system, crowd_status := crowd.crowd_create(max_agents, 2.0, nav_query)
    testing.expect(t, recast.status_succeeded(crowd_status), "Failed to create crowd")
    testing.expect(t, crowd_system != nil, "Crowd system is nil")
    
    return crowd_system
}

// Clean up test crowd
destroy_test_crowd :: proc(crowd_system: ^crowd.Crowd) {
    if crowd_system != nil {
        // Get nav_query from crowd before destroying
        nav_query := crowd_system.nav_query
        
        // Destroy crowd
        crowd.crowd_destroy(crowd_system)
        free(crowd_system)
        
        // Clean up nav_query if it exists
        if nav_query != nil {
            detour.nav_mesh_query_destroy(nav_query)
            free(nav_query)
        }
    }
}

// Helper to add test agent
add_test_agent :: proc(t: ^testing.T, crowd_system: ^crowd.Crowd, pos: [3]f32) -> recast.Agent_Id {
    params := crowd.agent_params_create_default()
    
    agent_id, status := crowd.crowd_add_agent(crowd_system, pos, &params)
    testing.expect(t, recast.status_succeeded(status), "Failed to add agent")
    testing.expect(t, agent_id != recast.Agent_Id(0), "Invalid agent ID")
    
    return agent_id
}

// Helper to check if positions are approximately equal
positions_equal :: proc(a, b: [3]f32, epsilon: f32 = 0.01) -> bool {
    return math.abs(a.x - b.x) < epsilon &&
           math.abs(a.y - b.y) < epsilon &&
           math.abs(a.z - b.z) < epsilon
}

// Helper to check if agent reached target
agent_reached_target :: proc(agent: ^crowd.Crowd_Agent, target: [3]f32, epsilon: f32 = 1.0) -> bool {
    if agent == nil do return false
    return positions_equal(agent.position, target, epsilon)
}

// =============================================================================
// Navigation Mesh Creation Utilities
// =============================================================================

// Create corridor navigation mesh for testing pathfinding through narrow passages
create_corridor_nav_mesh :: proc(t: ^testing.T, length: f32 = 50.0, width: f32 = 3.0) -> ^detour.Nav_Mesh {
    nav_mesh := new(detour.Nav_Mesh)
    
    params := detour.Nav_Mesh_Params{
        orig = {0, 0, 0},
        tile_width = length + 10.0,
        tile_height = width + 10.0,
        max_tiles = 1,
        max_polys = 20,
    }
    
    status := detour.nav_mesh_init(nav_mesh, &params)
    if recast.status_failed(status) {
        testing.fail_now(t, "Failed to initialize corridor navigation mesh")
    }
    
    // Create corridor tile data
    data := create_corridor_tile_data(length, width)
    
    tile_ref, add_status := detour.nav_mesh_add_tile(nav_mesh, data, recast.DT_TILE_FREE_DATA)
    if recast.status_failed(add_status) {
        testing.fail_now(t, "Failed to add corridor tile to navigation mesh")
    }
    
    // Connect internal links for the tile
    tile, tile_status := detour.get_tile_by_ref(nav_mesh, tile_ref)
    if recast.status_succeeded(tile_status) && tile != nil {
        detour.connect_int_links(nav_mesh, tile)
    }
    
    return nav_mesh
}

// Create room navigation mesh for testing open space movement
create_room_nav_mesh :: proc(t: ^testing.T, room_size: f32 = 30.0) -> ^detour.Nav_Mesh {
    nav_mesh := new(detour.Nav_Mesh)
    
    params := detour.Nav_Mesh_Params{
        orig = {0, 0, 0},
        tile_width = room_size + 5.0,
        tile_height = room_size + 5.0,
        max_tiles = 1,
        max_polys = 10,
    }
    
    status := detour.nav_mesh_init(nav_mesh, &params)
    if recast.status_failed(status) {
        testing.fail_now(t, "Failed to initialize room navigation mesh")
    }
    
    // Create room tile data - single large polygon
    data := create_room_tile_data(room_size)
    
    tile_ref, add_status := detour.nav_mesh_add_tile(nav_mesh, data, recast.DT_TILE_FREE_DATA)
    if recast.status_failed(add_status) {
        testing.fail_now(t, "Failed to add room tile to navigation mesh")
    }
    
    // Connect internal links for the tile
    tile, tile_status := detour.get_tile_by_ref(nav_mesh, tile_ref)
    if recast.status_succeeded(tile_status) && tile != nil {
        detour.connect_int_links(nav_mesh, tile)
    }
    
    return nav_mesh
}

// Create corridor tile data
create_corridor_tile_data :: proc(length: f32, width: f32) -> []u8 {
    // Simple corridor: 4 vertices, 1 rectangle polygon
    nverts := i32(4)
    npolys := i32(1)
    
    header_size := size_of(detour.Mesh_Header)
    verts_size := size_of([3]f32) * int(nverts)
    polys_size := size_of(detour.Poly) * int(npolys)
    detail_meshes_size := size_of(detour.Poly_Detail) * int(npolys)
    bv_tree_size := size_of(detour.BV_Node) * int(npolys)
    
    total_size := header_size + verts_size + polys_size + detail_meshes_size + bv_tree_size
    data := make([]u8, total_size)
    
    // Setup header
    header := cast(^detour.Mesh_Header)raw_data(data)
    header.magic = recast.DT_NAVMESH_MAGIC
    header.version = recast.DT_NAVMESH_VERSION
    header.x = 0
    header.y = 0
    header.layer = 0
    header.poly_count = npolys
    header.vert_count = nverts
    header.max_link_count = 0
    header.detail_mesh_count = npolys
    header.detail_vert_count = 0
    header.detail_tri_count = 0
    header.bv_node_count = npolys
    header.off_mesh_con_count = 0
    header.off_mesh_base = 0
    header.bmin = {0, 0, 0}
    header.bmax = {length, 1, width}
    header.walkable_height = 2.0
    header.walkable_radius = 0.6
    header.walkable_climb = 0.9
    header.bv_quant_factor = 1.0 / 0.3
    
    offset := uintptr(header_size)
    
    // Setup vertices (corridor rectangle)
    verts := cast(^[3]f32)(uintptr(raw_data(data)) + offset)
    verts_array := mem.slice_ptr(verts, int(nverts))
    offset += uintptr(verts_size)
    
    verts_array[0] = {0, 0, 0}        // Bottom-left
    verts_array[1] = {length, 0, 0}   // Bottom-right
    verts_array[2] = {length, 0, width} // Top-right
    verts_array[3] = {0, 0, width}    // Top-left
    
    // Setup polygon
    polys := cast(^detour.Poly)(uintptr(raw_data(data)) + offset)
    polys_array := mem.slice_ptr(polys, int(npolys))
    offset += uintptr(polys_size)
    
    poly := &polys_array[0]
    poly.verts[0] = 0
    poly.verts[1] = 1
    poly.verts[2] = 2
    poly.verts[3] = 3
    poly.vert_count = 4
    
    // No internal connections for simple corridor
    for i in 0..<recast.DT_VERTS_PER_POLYGON {
        poly.neis[i] = 0
    }
    
    poly.flags = 1
    detour.poly_set_area(poly, recast.RC_WALKABLE_AREA)
    detour.poly_set_type(poly, recast.DT_POLYTYPE_GROUND)
    
    // Setup detail meshes (simplified)
    detail_meshes := cast(^detour.Poly_Detail)(uintptr(raw_data(data)) + offset)
    detail_meshes_array := mem.slice_ptr(detail_meshes, int(npolys))
    offset += uintptr(detail_meshes_size)
    
    detail := &detail_meshes_array[0]
    detail.vert_base = 0
    detail.vert_count = 0
    detail.tri_base = 0
    detail.tri_count = 0
    
    // Setup BV tree
    bv_tree := cast(^detour.BV_Node)(uintptr(raw_data(data)) + offset)
    bv_tree_array := mem.slice_ptr(bv_tree, int(npolys))
    
    node := &bv_tree_array[0]
    quant_factor := header.bv_quant_factor
    node.bmin[0] = u16((0.0 - header.bmin.x) * quant_factor)
    node.bmin[1] = u16((0.0 - header.bmin.y) * quant_factor)
    node.bmin[2] = u16((0.0 - header.bmin.z) * quant_factor)
    node.bmax[0] = u16((length - header.bmin.x) * quant_factor)
    node.bmax[1] = u16((1.0 - header.bmin.y) * quant_factor)
    node.bmax[2] = u16((width - header.bmin.z) * quant_factor)
    node.i = 0
    
    return data
}

// Create room tile data
create_room_tile_data :: proc(room_size: f32) -> []u8 {
    // Simple room: 4 vertices, 1 rectangle polygon
    nverts := i32(4)
    npolys := i32(1)
    
    header_size := size_of(detour.Mesh_Header)
    verts_size := size_of([3]f32) * int(nverts)
    polys_size := size_of(detour.Poly) * int(npolys)
    detail_meshes_size := size_of(detour.Poly_Detail) * int(npolys)
    bv_tree_size := size_of(detour.BV_Node) * int(npolys)
    
    total_size := header_size + verts_size + polys_size + detail_meshes_size + bv_tree_size
    data := make([]u8, total_size)
    
    // Setup header
    header := cast(^detour.Mesh_Header)raw_data(data)
    header.magic = recast.DT_NAVMESH_MAGIC
    header.version = recast.DT_NAVMESH_VERSION
    header.x = 0
    header.y = 0
    header.layer = 0
    header.poly_count = npolys
    header.vert_count = nverts
    header.max_link_count = 0
    header.detail_mesh_count = npolys
    header.detail_vert_count = 0
    header.detail_tri_count = 0
    header.bv_node_count = npolys
    header.off_mesh_con_count = 0
    header.off_mesh_base = 0
    header.bmin = {0, 0, 0}
    header.bmax = {room_size, 1, room_size}
    header.walkable_height = 2.0
    header.walkable_radius = 0.6
    header.walkable_climb = 0.9
    header.bv_quant_factor = 1.0 / 0.3
    
    offset := uintptr(header_size)
    
    // Setup vertices (room rectangle)
    verts := cast(^[3]f32)(uintptr(raw_data(data)) + offset)
    verts_array := mem.slice_ptr(verts, int(nverts))
    offset += uintptr(verts_size)
    
    verts_array[0] = {0, 0, 0}              // Bottom-left
    verts_array[1] = {room_size, 0, 0}       // Bottom-right
    verts_array[2] = {room_size, 0, room_size} // Top-right
    verts_array[3] = {0, 0, room_size}       // Top-left
    
    // Setup polygon
    polys := cast(^detour.Poly)(uintptr(raw_data(data)) + offset)
    polys_array := mem.slice_ptr(polys, int(npolys))
    offset += uintptr(polys_size)
    
    poly := &polys_array[0]
    poly.verts[0] = 0
    poly.verts[1] = 1
    poly.verts[2] = 2
    poly.verts[3] = 3
    poly.vert_count = 4
    
    for i in 0..<recast.DT_VERTS_PER_POLYGON {
        poly.neis[i] = 0
    }
    
    poly.flags = 1
    detour.poly_set_area(poly, recast.RC_WALKABLE_AREA)
    detour.poly_set_type(poly, recast.DT_POLYTYPE_GROUND)
    
    // Setup detail meshes (simplified)
    detail_meshes := cast(^detour.Poly_Detail)(uintptr(raw_data(data)) + offset)
    detail_meshes_array := mem.slice_ptr(detail_meshes, int(npolys))
    offset += uintptr(detail_meshes_size)
    
    detail := &detail_meshes_array[0]
    detail.vert_base = 0
    detail.vert_count = 0
    detail.tri_base = 0
    detail.tri_count = 0
    
    // Setup BV tree
    bv_tree := cast(^detour.BV_Node)(uintptr(raw_data(data)) + offset)
    bv_tree_array := mem.slice_ptr(bv_tree, int(npolys))
    
    node := &bv_tree_array[0]
    quant_factor := header.bv_quant_factor
    node.bmin[0] = u16((0.0 - header.bmin.x) * quant_factor)
    node.bmin[1] = u16((0.0 - header.bmin.y) * quant_factor)
    node.bmin[2] = u16((0.0 - header.bmin.z) * quant_factor)
    node.bmax[0] = u16((room_size - header.bmin.x) * quant_factor)
    node.bmax[1] = u16((1.0 - header.bmin.y) * quant_factor)
    node.bmax[2] = u16((room_size - header.bmin.z) * quant_factor)
    node.i = 0
    
    return data
}

// =============================================================================
// Performance Measurement Utilities
// =============================================================================

// Performance measurement context
Performance_Context :: struct {
    name: string,
    start_time: time.Time,
    measurements: [dynamic]f64, // in milliseconds
}

// Start performance measurement
performance_start :: proc(name: string) -> Performance_Context {
    return Performance_Context{
        name = name,
        start_time = time.now(),
        measurements = make([dynamic]f64, 0, 100),
    }
}

// Record a measurement
performance_measure :: proc(ctx: ^Performance_Context, label: string = "") {
    elapsed := time.since(ctx.start_time)
    elapsed_ms := f64(time.duration_milliseconds(elapsed))
    append(&ctx.measurements, elapsed_ms)
    
    if label != "" {
        fmt.printf("%s - %s: %.2f ms\n", ctx.name, label, elapsed_ms)
    }
    
    ctx.start_time = time.now() // Reset for next measurement
}

// Get performance statistics
performance_stats :: proc(ctx: ^Performance_Context) -> (avg: f64, min_time: f64, max_time: f64) {
    if len(ctx.measurements) == 0 do return 0, 0, 0
    
    total := f64(0)
    min_time = math.F64_MAX
    max_time = f64(0)
    
    for measurement in ctx.measurements {
        total += measurement
        min_time = min(min_time, measurement)
        max_time = max(max_time, measurement)
    }
    
    avg = total / f64(len(ctx.measurements))
    return
}

// Clean up performance context
performance_destroy :: proc(ctx: ^Performance_Context) {
    delete(ctx.measurements)
}

// =============================================================================
// Crowd Scenario Setup Utilities
// =============================================================================

// Setup bidirectional flow scenario
setup_bidirectional_flow :: proc(t: ^testing.T, crowd_system: ^crowd.Crowd, agent_count: i32) -> (group_a: []recast.Agent_Id, group_b: []recast.Agent_Id) {
    half_count := agent_count / 2
    group_a = make([]recast.Agent_Id, half_count)
    group_b = make([]recast.Agent_Id, half_count)
    
    params := crowd.agent_params_create_default()
    params.separation_weight = 2.0 // Higher separation for flow scenarios
    
    // Group A - left side moving right
    for i in 0..<half_count {
        pos := [3]f32{5.0, 0.0, f32(8 + i * 2)}
        agent_id, status := crowd.crowd_add_agent(crowd_system, pos, &params)
        testing.expect(t, recast.status_succeeded(status), fmt.tprintf("Should add group A agent %d", i))
        group_a[i] = agent_id
    }
    
    // Group B - right side moving left
    for i in 0..<half_count {
        pos := [3]f32{25.0, 0.0, f32(8 + i * 2)}
        agent_id, status := crowd.crowd_add_agent(crowd_system, pos, &params)
        testing.expect(t, recast.status_succeeded(status), fmt.tprintf("Should add group B agent %d", i))
        group_b[i] = agent_id
    }
    
    return
}

// Setup formation scenario
setup_formation :: proc(t: ^testing.T, crowd_system: ^crowd.Crowd, formation_size: i32, center: [3]f32, spacing: f32 = 1.5) -> []recast.Agent_Id {
    agents := make([]recast.Agent_Id, formation_size)
    
    params := crowd.agent_params_create_default()
    params.separation_weight = 1.0 // Lower separation to maintain formation
    params.max_speed = 2.0 // Consistent speed
    
    side_count := i32(math.sqrt(f64(formation_size))) // Square formation
    
    for i in 0..<formation_size {
        row := i / side_count
        col := i % side_count
        
        offset := [3]f32{
            f32(col - side_count/2) * spacing,
            0.0,
            f32(row - side_count/2) * spacing,
        }
        
        pos := center + offset
        agent_id, status := crowd.crowd_add_agent(crowd_system, pos, &params)
        testing.expect(t, recast.status_succeeded(status), fmt.tprintf("Should add formation agent %d", i))
        agents[i] = agent_id
    }
    
    return agents
}

// Calculate average separation between agents
calculate_average_separation :: proc(agents: []recast.Agent_Id, crowd_system: ^crowd.Crowd) -> f32 {
    if len(agents) <= 1 do return 0.0
    
    total_distance := f32(0.0)
    pair_count := 0
    
    for i in 0..<len(agents) {
        agent_i := crowd.crowd_get_agent(crowd_system, agents[i])
        if agent_i == nil do continue
        
        pos_i := crowd.agent_get_position(agent_i)
        
        for j in i+1..<len(agents) {
            agent_j := crowd.crowd_get_agent(crowd_system, agents[j])
            if agent_j == nil do continue
            
            pos_j := crowd.agent_get_position(agent_j)
            distance := linalg.distance(pos_i, pos_j)
            total_distance += distance
            pair_count += 1
        }
    }
    
    if pair_count == 0 do return 0.0
    return total_distance / f32(pair_count)
}

// Check if crowd reached stable state (velocities are low)
crowd_is_stable :: proc(agents: []recast.Agent_Id, crowd_system: ^crowd.Crowd, threshold: f32 = 0.1) -> bool {
    if len(agents) == 0 do return true
    
    for agent_id in agents {
        agent := crowd.crowd_get_agent(crowd_system, agent_id)
        if agent == nil do continue
        
        vel := crowd.agent_get_velocity(agent)
        speed := linalg.length(vel)
        
        if speed > threshold {
            return false
        }
    }
    
    return true
}