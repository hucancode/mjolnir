package test_detour_crowd

import "core:testing"
import "core:mem"
import "core:math"
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
    
    _, add_status := detour.nav_mesh_add_tile(nav_mesh, data, recast.DT_TILE_FREE_DATA)
    if recast.status_failed(add_status) {
        testing.fail_now(t, "Failed to add test tile to navigation mesh")
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
    
    // Calculate link count (each internal edge needs 2 links for bidirectional)
    // Grid has (grid_x-1)*grid_z vertical edges and grid_x*(grid_z-1) horizontal edges
    // Each edge needs 2 links (one for each direction)
    link_count := ((grid_x - 1) * grid_z + grid_x * (grid_z - 1)) * 2
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
            
            // Quad vertices (counter-clockwise)
            v0 := u16(z * (grid_x + 1) + x)
            v1 := u16(z * (grid_x + 1) + x + 1)
            v2 := u16((z + 1) * (grid_x + 1) + x + 1)
            v3 := u16((z + 1) * (grid_x + 1) + x)
            
            poly.verts[0] = v0
            poly.verts[1] = v1
            poly.verts[2] = v2
            poly.verts[3] = v3
            poly.vert_count = 4
            
            // Set up neighbor connections
            for i in 0..<recast.DT_VERTS_PER_POLYGON {
                poly.neis[i] = 0  // External by default (0 means no connection)
            }
            
            // Connect to neighbors in grid
            if x > 0 {
                // Left neighbor
                poly.neis[3] = u16(poly_idx - 1) | 0x8000  // Internal link to left
            }
            if x < grid_x - 1 {
                // Right neighbor
                poly.neis[1] = u16(poly_idx + 1) | 0x8000  // Internal link to right
            }
            if z > 0 {
                // Bottom neighbor
                poly.neis[0] = u16(i32(poly_idx) - grid_x) | 0x8000  // Internal link to bottom
            }
            if z < grid_z - 1 {
                // Top neighbor
                poly.neis[2] = u16(i32(poly_idx) + grid_x) | 0x8000  // Internal link to top
            }
            
            poly.flags = 1  // Walkable
            detour.poly_set_area(poly, recast.RC_WALKABLE_AREA)
            detour.poly_set_type(poly, recast.DT_POLYTYPE_GROUND)
            
            poly_idx += 1
        }
    }
    
    // Skip links for now (would need proper link setup for connections)
    offset += uintptr(links_size)
    
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