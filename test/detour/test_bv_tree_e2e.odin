package test_detour

import "core:testing"
import "core:log"
import "core:math"
import "core:time"
import nav_detour "../../mjolnir/navigation/detour"
import nav_recast "../../mjolnir/navigation/recast"

@(test)
test_bv_tree_e2e :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    log.info("End-to-end BV tree test - building complete navmesh")
    
    // Create a simple floor mesh
    mesh: nav_recast.Poly_Mesh
    mesh.cs = 0.3
    mesh.ch = 0.2
    mesh.nvp = 6
    mesh.npolys = 2
    
    mesh.bmin = {0.0, 0.0, 0.0}
    mesh.bmax = {10.0, 2.0, 10.0}
    
    // Create vertices for a simple floor
    verts := [][3]u16{
        {0, 0, 0},      // vertex 0
        {33, 0, 0},     // vertex 1 (10/0.3 = 33.33)
        {33, 0, 33},    // vertex 2
        {0, 0, 33},     // vertex 3
    }
    mesh.verts = verts
    
    // Create two triangles forming a square floor
    polys := make([]u16, 2 * 6 * 2)
    for i in 0..<len(polys) {
        polys[i] = nav_recast.RC_MESH_NULL_IDX
    }
    
    // Triangle 1: 0,1,2
    polys[0] = 0
    polys[1] = 1
    polys[2] = 2
    
    // Triangle 2: 0,2,3
    polys[12] = 0
    polys[13] = 2
    polys[14] = 3
    
    mesh.polys = polys
    
    // Create areas and flags
    areas := []u8{nav_recast.RC_WALKABLE_AREA, nav_recast.RC_WALKABLE_AREA}
    flags := []u16{1, 1}
    mesh.areas = areas
    mesh.flags = flags
    
    // Create navmesh data
    params: nav_detour.Create_Nav_Mesh_Data_Params
    params.poly_mesh = &mesh
    params.poly_mesh_detail = nil
    params.walkable_height = 2.0
    params.walkable_radius = 0.6
    params.walkable_climb = 0.9
    params.tile_x = 0
    params.tile_y = 0
    params.tile_layer = 0
    
    nav_data, create_status := nav_detour.create_nav_mesh_data(&params)
    if !nav_recast.status_succeeded(create_status) {
        log.errorf("Failed to create nav mesh data: %v", create_status)
        testing.fail(t)
        return
    }
    defer delete(nav_data)
    
    log.infof("Created navmesh data: %d bytes", len(nav_data))
    
    // Parse the header to verify BV tree
    header := cast(^nav_detour.Mesh_Header)raw_data(nav_data)
    log.infof("Navmesh header: polys=%d, verts=%d, bv_nodes=%d", 
              header.poly_count, header.vert_count, header.bv_node_count)
    
    // Verify BV tree was created
    if header.bv_node_count != 2 {
        log.errorf("Expected 2 BV nodes (one per poly), got %d", header.bv_node_count)
        testing.fail(t)
    }
    
    // Calculate offsets to find BV tree
    header_size := size_of(nav_detour.Mesh_Header)
    verts_size := size_of([3]f32) * int(header.vert_count)
    polys_size := size_of(nav_detour.Poly) * int(header.poly_count)
    links_size := size_of(nav_detour.Link) * int(header.max_link_count)
    detail_meshes_size := size_of(nav_detour.Poly_Detail) * int(header.detail_mesh_count)
    detail_verts_size := size_of([3]f32) * int(header.detail_vert_count)
    detail_tris_size := size_of(u8) * int(header.detail_tri_count) * 4
    
    bv_offset := header_size + verts_size + polys_size + links_size +
                 detail_meshes_size + detail_verts_size + detail_tris_size
    
    // Get BV tree nodes
    bv_nodes := cast(^nav_detour.BV_Node)(raw_data(nav_data)[bv_offset:])
    
    log.info("BV Tree nodes from navmesh data:")
    for i in 0..<int(header.bv_node_count) {
        node := cast(^nav_detour.BV_Node)(uintptr(bv_nodes) + uintptr(i * size_of(nav_detour.BV_Node)))
        log.infof("  Node %d: bmin=[%d,%d,%d], bmax=[%d,%d,%d], i=%d",
                  i, node.bmin[0], node.bmin[1], node.bmin[2],
                  node.bmax[0], node.bmax[1], node.bmax[2], node.i)
        
        // Verify bounds are reasonable (not default values)
        if node.bmax[0] == 1 && node.bmax[1] == 1 && node.bmax[2] == 1 {
            log.error("BV node has invalid bounds (probably using wrong polygon offset)")
            testing.fail(t)
        }
    }
    
    // Now create a navigation mesh and add the tile
    nav_mesh_params: nav_detour.Nav_Mesh_Params
    nav_mesh_params.orig = mesh.bmin
    nav_mesh_params.tile_width = mesh.bmax[0] - mesh.bmin[0]
    nav_mesh_params.tile_height = mesh.bmax[2] - mesh.bmin[2]
    nav_mesh_params.max_tiles = 1
    nav_mesh_params.max_polys = 1024
    
    nav_mesh: nav_detour.Nav_Mesh
    init_status := nav_detour.nav_mesh_init(&nav_mesh, &nav_mesh_params)
    if !nav_recast.status_succeeded(init_status) {
        log.errorf("Failed to init nav mesh: %v", init_status)
        testing.fail(t)
        return
    }
    defer nav_detour.nav_mesh_destroy(&nav_mesh)
    
    // Add the tile
    tile_ref, add_status := nav_detour.nav_mesh_add_tile(&nav_mesh, nav_data, 0)
    if !nav_recast.status_succeeded(add_status) {
        log.errorf("Failed to add tile: %v", add_status)
        testing.fail(t)
        return
    }
    
    log.infof("Successfully added tile with ref: 0x%x", tile_ref)
    
    // Test point location using BV tree
    test_point := [3]f32{5.0, 0.0, 5.0}  // Center of floor
    extent := [3]f32{1.0, 2.0, 1.0}
    
    query: nav_detour.Nav_Mesh_Query
    query_status := nav_detour.nav_mesh_query_init(&query, &nav_mesh, 512)
    if !nav_recast.status_succeeded(query_status) {
        log.errorf("Failed to init query: %v", query_status)
        testing.fail(t)
        return
    }
    defer nav_detour.nav_mesh_query_destroy(&query)
    
    filter: nav_detour.Query_Filter
    nav_detour.query_filter_init(&filter)
    
    find_status, nearest_poly, nearest_point := nav_detour.find_nearest_poly(&query, test_point, extent, &filter)
    if !nav_recast.status_succeeded(find_status) {
        log.errorf("Failed to find nearest poly: %v", find_status)
        testing.fail(t)
        return
    }
    
    log.infof("Found nearest poly: 0x%x at point [%f,%f,%f]", 
              nearest_poly, nearest_point[0], nearest_point[1], nearest_point[2])
    
    if nearest_poly == nav_recast.INVALID_POLY_REF {
        log.error("BV tree query failed - couldn't find polygon at test point")
        testing.fail(t)
    }
    
    log.info("✓ End-to-end BV tree test passed")
    
    delete(polys)
}