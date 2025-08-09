package test_detour

import "core:testing"
import "core:log"
import "core:math"
import "core:time"
import nav_detour "../../mjolnir/navigation/detour"
import nav_recast "../../mjolnir/navigation/recast"

@(test)
test_bv_tree_construction :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create test polymesh matching C++ test
    mesh: nav_recast.Poly_Mesh
    mesh.cs = 0.3
    mesh.ch = 0.2
    mesh.nvp = 6
    mesh.npolys = 4
    
    mesh.bmin = {0.0, 0.0, 0.0}
    mesh.bmax = {10.0, 2.0, 10.0}
    
    // Create vertices (already quantized)
    verts := [][3]u16{
        {0, 0, 0},      // vertex 0
        {10, 0, 0},     // vertex 1
        {10, 0, 10},    // vertex 2
        {0, 0, 10},     // vertex 3
        {0, 5, 0},      // vertex 4
        {10, 5, 0},     // vertex 5
        {10, 5, 10},    // vertex 6
        {0, 5, 10},     // vertex 7
    }
    mesh.verts = verts
    
    // Create polygons (4 triangles)
    polys := make([]u16, 4 * 6 * 2)
    for i in 0..<len(polys) {
        polys[i] = nav_recast.RC_MESH_NULL_IDX
    }
    
    // Bottom triangle 1: 0,1,2
    polys[0] = 0
    polys[1] = 1
    polys[2] = 2
    
    // Bottom triangle 2: 0,2,3
    polys[12] = 0
    polys[13] = 2
    polys[14] = 3
    
    // Top triangle 1: 4,5,6
    polys[24] = 4
    polys[25] = 5
    polys[26] = 6
    
    // Top triangle 2: 4,6,7
    polys[36] = 4
    polys[37] = 6
    polys[38] = 7
    
    mesh.polys = polys
    
    // Create areas and flags
    areas := []u8{1, 1, 1, 1}
    flags := []u16{1, 1, 1, 1}
    mesh.areas = areas
    mesh.flags = flags
    
    log.info("Test polymesh info:")
    log.infof("  cs=%f, ch=%f", mesh.cs, mesh.ch)
    log.infof("  npolys=%d, nverts=%d", mesh.npolys, len(mesh.verts))
    log.infof("  bmin=[%f,%f,%f]", mesh.bmin[0], mesh.bmin[1], mesh.bmin[2])
    log.infof("  bmax=[%f,%f,%f]", mesh.bmax[0], mesh.bmax[1], mesh.bmax[2])
    
    log.info("\nVertices (quantized):")
    for v, i in mesh.verts {
        log.infof("  Vertex %d: [%d, %d, %d]", i, v[0], v[1], v[2])
    }
    
    log.info("\nPolygons:")
    for i in 0..<mesh.npolys {
        log.infof("  Poly %d: ", i)
        for j in 0..<mesh.nvp {
            v := mesh.polys[i * mesh.nvp * 2 + j]
            if v != nav_recast.RC_MESH_NULL_IDX {
                log.infof("    vert %d", v)
            }
        }
    }
    
    // Build BV tree
    nodes := make([]nav_detour.BV_Node, 4)
    nav_detour.build_bv_tree(&mesh, nodes, 4, nil)
    
    log.info("\nOdin BV Tree Nodes:")
    for node, i in nodes {
        log.infof("Node %d: bmin=[%d,%d,%d], bmax=[%d,%d,%d], i=%d",
                  i, node.bmin[0], node.bmin[1], node.bmin[2],
                  node.bmax[0], node.bmax[1], node.bmax[2], node.i)
    }
    
    // Expected values from C++ (with Y remapping)
    expected := []struct{
        bmin: [3]u16,
        bmax: [3]u16,
        i: i32,
    }{
        {{0,0,0}, {10,0,10}, 0},   // Bottom triangle 1
        {{0,0,0}, {10,0,10}, 1},   // Bottom triangle 2
        {{0,3,0}, {10,4,10}, 2},   // Top triangle 1 (Y remapped from 5 to 3-4)
        {{0,3,0}, {10,4,10}, 3},   // Top triangle 2 (Y remapped from 5 to 3-4)
    }
    
    log.info("\nComparison with expected C++ values:")
    for i in 0..<4 {
        node := nodes[i]
        exp := expected[i]
        
        log.infof("Node %d:", i)
        log.infof("  Odin:    bmin=[%d,%d,%d], bmax=[%d,%d,%d], i=%d",
                  node.bmin[0], node.bmin[1], node.bmin[2],
                  node.bmax[0], node.bmax[1], node.bmax[2], node.i)
        log.infof("  Expected: bmin=[%d,%d,%d], bmax=[%d,%d,%d], i=%d",
                  exp.bmin[0], exp.bmin[1], exp.bmin[2],
                  exp.bmax[0], exp.bmax[1], exp.bmax[2], exp.i)
        
        // Check if they match
        bmin_match := node.bmin == exp.bmin
        bmax_match := node.bmax == exp.bmax
        i_match := node.i == exp.i
        
        if !bmin_match || !bmax_match || !i_match {
            log.errorf("  MISMATCH! bmin_match=%v, bmax_match=%v, i_match=%v",
                      bmin_match, bmax_match, i_match)
            testing.fail(t)
        } else {
            log.info("  ✓ MATCH")
        }
    }
    
    delete(polys)
    delete(nodes)
}

// Helper to manually calculate what the bounds should be
@(test)
test_bv_bounds_calculation :: proc(t: ^testing.T) {
    log.info("Testing BV bounds calculation logic:")
    
    cs: f32 = 0.3
    ch: f32 = 0.2
    ch_cs_ratio := ch / cs
    
    log.infof("ch/cs ratio: %f", ch_cs_ratio)
    
    // Test Y coordinate remapping
    test_y_values := []u16{0, 5, 10}
    
    for y in test_y_values {
        y_float := f32(y) * ch_cs_ratio
        y_floor := u16(math.floor(y_float))
        y_ceil := u16(math.ceil(y_float))
        
        log.infof("Y=%d -> float=%f -> floor=%d, ceil=%d", 
                  y, y_float, y_floor, y_ceil)
    }
}