package test_recast

import "core:testing"
import "core:log"
import "core:time" 
import nav_recast "../../mjolnir/navigation/recast"

@(test)
test_recast_detail_compilation :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Simple compilation test to ensure all functions are accessible
    log.info("Testing Recast detail mesh compilation...")
    
    // Test data structure allocation
    dmesh := nav_recast.rc_alloc_poly_mesh_detail()
    testing.expect(t, dmesh != nil, "Should allocate detail mesh successfully")
    
    // Test validation with empty mesh
    valid := nav_recast.validate_poly_mesh_detail(dmesh)
    testing.expect(t, !valid, "Empty detail mesh should be invalid")
    
    // Clean up
    nav_recast.rc_free_poly_mesh_detail(dmesh)
    
    log.info("✓ Recast detail mesh compilation test passed")
}

@(test)
test_simple_detail_mesh_build :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    log.info("Testing simple detail mesh build...")
    
    // Create minimal working example
    pmesh := nav_recast.rc_alloc_poly_mesh()
    defer nav_recast.rc_free_poly_mesh(pmesh)
    
    chf := nav_recast.rc_alloc_compact_heightfield()
    defer nav_recast.rc_free_compact_heightfield(chf)
    
    dmesh := nav_recast.rc_alloc_poly_mesh_detail()
    defer nav_recast.rc_free_poly_mesh_detail(dmesh)
    
    // Set up minimal polygon mesh (single triangle)
    pmesh.npolys = 1
    pmesh.nvp = 3
    pmesh.bmin = {0, 0, 0}
    pmesh.bmax = {1, 1, 1}
    pmesh.cs = 0.1
    pmesh.ch = 0.1
    
    pmesh.verts = make([][3]u16, 3)
    pmesh.verts[0] = {0, 0, 0}
    pmesh.verts[1] = {10, 0, 0}
    pmesh.verts[2] = {5, 0, 10}
    
    pmesh.polys = make([]u16, 6)  // 1 poly * 3 verts * 2 (verts + neighbors)
    pmesh.polys[0] = 0; pmesh.polys[1] = 1; pmesh.polys[2] = 2
    pmesh.polys[3] = nav_recast.RC_MESH_NULL_IDX
    pmesh.polys[4] = nav_recast.RC_MESH_NULL_IDX  
    pmesh.polys[5] = nav_recast.RC_MESH_NULL_IDX
    
    pmesh.regs = make([]u16, 1)
    pmesh.flags = make([]u16, 1) 
    pmesh.areas = make([]u8, 1)
    pmesh.areas[0] = nav_recast.RC_WALKABLE_AREA
    
    // Set up minimal compact heightfield
    chf.width = 2
    chf.height = 2
    chf.span_count = 4
    chf.bmin = pmesh.bmin
    chf.bmax = pmesh.bmax
    chf.cs = pmesh.cs
    chf.ch = pmesh.ch
    
    chf.cells = make([]nav_recast.Rc_Compact_Cell, 4)
    chf.spans = make([]nav_recast.Rc_Compact_Span, 4)
    
    for i in 0..<4 {
        cell := &chf.cells[i]
        cell.index = u32(i)
        cell.count = 1
        
        span := &chf.spans[i]
        span.y = 0
        span.h = 1
    }
    
    // Try to build detail mesh
    success := nav_recast.rc_build_poly_mesh_detail(pmesh, chf, 0.5, 1.0, dmesh)
    testing.expect(t, success, "Should build detail mesh successfully")
    
    if success {
        valid := nav_recast.validate_poly_mesh_detail(dmesh)
        testing.expect(t, valid, "Built detail mesh should be valid")
        
        log.infof("Built detail mesh: %d meshes, %d vertices, %d triangles", 
                  len(dmesh.meshes), len(dmesh.verts), len(dmesh.tris))
    }
    
    log.info("✓ Simple detail mesh build test passed")
}