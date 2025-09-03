package test_recast

import "core:testing"
import "core:log"
import "core:fmt"
import "core:time"
import nav "../../mjolnir/navigation/recast"
import nav_loader "../../mjolnir/navigation"

@(test)
test_floor_5_obstacles_simple :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Load the floor_with_5_obstacles.obj mesh
    vertices, indices, areas, ok := nav_loader.load_obj_to_navmesh_input("assets/floor_with_5_obstacles.obj")
    if !ok {
        testing.fail(t)
        log.error("Failed to load floor_with_5_obstacles.obj")
        return
    }
    defer {
        delete(vertices)
        delete(indices)
        delete(areas)
    }

    log.infof("Loaded mesh: %d verts, %d indices",
             len(vertices), len(indices))

    cfg := nav.Config{}
    cfg.cs = 0.3
    cfg.ch = 0.2
    cfg.walkable_slope_angle = 45.0
    cfg.walkable_height = 10
    cfg.walkable_climb = 4
    cfg.walkable_radius = 2
    cfg.max_edge_len = 12
    cfg.max_simplification_error = 1.3
    cfg.min_region_area = 64
    cfg.merge_region_area = 400
    cfg.max_verts_per_poly = 6
    cfg.detail_sample_dist = 6.0
    cfg.detail_sample_max_error = 1.0

    // Build navigation mesh
    log.info("=== Building navigation mesh ===")
    pmesh, dmesh, build_ok := nav.build_navmesh(vertices, indices, areas, cfg)
    if !build_ok {
        log.error("Failed to build navigation mesh")
        testing.fail(t)
        return
    }
    defer {
        if pmesh != nil do nav.free_poly_mesh(pmesh)
        if dmesh != nil do nav.free_poly_mesh_detail(dmesh)
    }

    log.infof("\n=== PolyMesh Result ===")
    log.infof("nverts: %d, npolys: %d, maxpolys: %d, nvp: %d",
             len(pmesh.verts), pmesh.npolys, pmesh.maxpolys, pmesh.nvp)

    // Print first 10 vertices
    log.info("First vertices (x,y,z):")
    for i in 0..<min(10, len(pmesh.verts)) {
        v := pmesh.verts[i]
        log.infof("  [%d]: %d, %d, %d", i, v.x, v.y, v.z)
    }

    // Print first 5 polygons
    log.info("First polygons:")
    for i in 0..<min(5, int(pmesh.npolys)) {
        p_start := int(i) * int(pmesh.nvp) * 2
        fmt.printf("  [%d]: ", i)
        for j in 0..<int(pmesh.nvp) {
            if pmesh.polys[p_start + j] == nav.RC_MESH_NULL_IDX do break
            fmt.printf("%d ", pmesh.polys[p_start + j])
        }
        fmt.printf("(area: %d, reg: %d)\n", pmesh.areas[i], pmesh.regs[i])
    }

    // Verify mesh was built successfully
    testing.expect(t, pmesh.npolys > 0, "Should generate polygons")
    testing.expect(t, len(pmesh.verts) > 0, "Should generate vertices")

    log.info("✓ Navigation mesh built successfully")
}
