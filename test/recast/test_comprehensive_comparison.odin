#+feature dynamic-literals
package test_recast

import "core:testing"
import "core:log"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:math"
import nav "../../mjolnir/navigation/recast"

// Test result structure for comparison
Test_Result :: struct {
    stage: string,
    count: int,
    values: [dynamic]f32,
    details: string,
}

// Save results to file for comparison
save_results :: proc(filename: string, results: []Test_Result) {
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    
    for r in results {
        strings.write_string(&builder, fmt.tprintf("Stage: %s\n", r.stage))
        strings.write_string(&builder, fmt.tprintf("Count: %d\n", r.count))
        if len(r.values) > 0 {
            strings.write_string(&builder, "Values: ")
            for i in 0..<min(len(r.values), 10) {
                strings.write_string(&builder, fmt.tprintf("%f ", r.values[i]))
            }
            if len(r.values) > 10 {
                strings.write_string(&builder, "...")
            }
            strings.write_string(&builder, "\n")
        }
        if r.details != "" {
            strings.write_string(&builder, fmt.tprintf("Details: %s\n", r.details))
        }
        strings.write_string(&builder, "\n")
    }
    
    os.write_entire_file(filename, transmute([]u8)strings.to_string(builder))
}

// Count spans in heightfield
count_spans :: proc(hf: ^nav.Heightfield) -> int {
    count := 0
    for z in 0..<hf.height {
        for x in 0..<hf.width {
            s := hf.spans[x + z * hf.width]
            for s != nil {
                count += 1
                s = s.next
            }
        }
    }
    return count
}

// Count walkable spans
count_walkable_spans :: proc(hf: ^nav.Heightfield) -> int {
    count := 0
    for z in 0..<hf.height {
        for x in 0..<hf.width {
            s := hf.spans[x + z * hf.width]
            for s != nil {
                if s.area != nav.RC_NULL_AREA {
                    count += 1
                }
                s = s.next
            }
        }
    }
    return count
}

// Get span distribution by quadrant
get_span_distribution :: proc(hf: ^nav.Heightfield, quadrants: ^[4]int) {
    mid_x := hf.width / 2
    mid_z := hf.height / 2
    quadrants[0] = 0
    quadrants[1] = 0
    quadrants[2] = 0
    quadrants[3] = 0
    
    for z in 0..<hf.height {
        for x in 0..<hf.width {
            s := hf.spans[x + z * hf.width]
            for s != nil {
                if s.area != nav.RC_NULL_AREA {
                    quad := 0
                    if x < mid_x && z < mid_z do quad = 2  // SW
                    else if x >= mid_x && z < mid_z do quad = 3  // SE
                    else if x < mid_x && z >= mid_z do quad = 1  // NW
                    else do quad = 0  // NE
                    quadrants[quad] += 1
                }
                s = s.next
            }
        }
    }
}

@(test)
test_complete_pipeline :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    log.info("=== COMPREHENSIVE ODIN RECAST PIPELINE TEST ===")
    
    results := make([dynamic]Test_Result)
    defer delete(results)
    
    // Step 1: Create simple test geometry (matching C++)
    vertices := [][3]f32{
        // Ground plane
        {0, 0, 0},
        {10, 0, 0},
        {10, 0, 10},
        {0, 0, 10},
        // Small obstacle
        {4, 0, 4},
        {6, 0, 4},
        {6, 2, 4},
        {4, 2, 4},
        {4, 0, 6},
        {6, 0, 6},
        {6, 2, 6},
        {4, 2, 6},
    }
    
    indices := []i32{
        // Ground
        0, 1, 2,
        0, 2, 3,
        // Obstacle sides
        4, 5, 6,
        4, 6, 7,
        5, 9, 10,
        5, 10, 6,
        9, 8, 11,
        9, 11, 10,
        8, 4, 7,
        8, 7, 11,
    }
    
    areas := make([]u8, 10)
    defer delete(areas)
    for i in 0..<10 {
        areas[i] = nav.RC_WALKABLE_AREA
    }
    
    nverts := 12
    ntris := 10
    
    append(&results, Test_Result{
        stage = "Input Geometry",
        count = ntris,
        values = {},
        details = fmt.tprintf("Triangles: %d", ntris),
    })
    
    // Step 2: Calculate bounds
    bmin, bmax := nav.calc_bounds(vertices)
    
    log.infof("Bounds: (%.2f, %.2f, %.2f) to (%.2f, %.2f, %.2f)", 
              bmin.x, bmin.y, bmin.z, bmax.x, bmax.y, bmax.z)
    
    append(&results, Test_Result{
        stage = "Bounds",
        count = 0,
        values = {bmin.x, bmin.y, bmin.z, bmax.x, bmax.y, bmax.z},
        details = "",
    })
    
    // Step 3: Setup config
    cfg := nav.Config{
        cs = 0.3,
        ch = 0.2,
        walkable_slope_angle = 45.0,
        walkable_height = 10,
        walkable_climb = 4,
        walkable_radius = 2,
        max_edge_len = 12,
        max_simplification_error = 1.3,
        min_region_area = 8,
        merge_region_area = 20,
        max_verts_per_poly = 6,
        detail_sample_dist = 6.0,
        detail_sample_max_error = 1.0,
        bmin = bmin,
        bmax = bmax,
    }
    
    cfg.width, cfg.height = nav.calc_grid_size(cfg.bmin, cfg.bmax, cfg.cs)
    
    log.infof("Grid size: %d x %d", cfg.width, cfg.height)
    append(&results, Test_Result{
        stage = "Grid Size",
        count = 0,
        values = {f32(cfg.width), f32(cfg.height)},
        details = "",
    })
    
    // Step 4: Create heightfield
    hf := new(nav.Heightfield)
    defer nav.free_heightfield(hf)
    
    if !nav.create_heightfield(hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch) {
        log.error("Failed to create heightfield")
        testing.fail(t)
        return
    }
    
    // Step 5: Mark walkable triangles
    nav.mark_walkable_triangles(cfg.walkable_slope_angle, vertices, indices, areas)
    
    walkable_count := 0
    for i in 0..<ntris {
        if areas[i] != nav.RC_NULL_AREA {
            walkable_count += 1
        }
    }
    log.infof("Walkable triangles: %d/%d", walkable_count, ntris)
    append(&results, Test_Result{
        stage = "Walkable Triangles",
        count = walkable_count,
        values = {},
        details = "",
    })
    
    // Step 6: Rasterize triangles
    if !nav.rasterize_triangles(vertices, indices, areas, hf, cfg.walkable_climb) {
        log.error("Failed to rasterize triangles")
        testing.fail(t)
        return
    }
    
    total_spans := count_spans(hf)
    walkable_spans := count_walkable_spans(hf)
    quadrants: [4]int
    get_span_distribution(hf, &quadrants)
    
    log.info("After rasterization:")
    log.infof("  Total spans: %d", total_spans)
    log.infof("  Walkable spans: %d", walkable_spans)
    log.infof("  Distribution (NE,NW,SW,SE): %d,%d,%d,%d", 
              quadrants[0], quadrants[1], quadrants[2], quadrants[3])
    
    append(&results, Test_Result{
        stage = "Rasterization",
        count = total_spans,
        values = {f32(walkable_spans), f32(quadrants[0]), f32(quadrants[1]), 
                  f32(quadrants[2]), f32(quadrants[3])},
        details = fmt.tprintf("Total spans: %d", total_spans),
    })
    
    // Step 7: Filter walkable surfaces
    nav.filter_low_hanging_walkable_obstacles(int(cfg.walkable_climb), hf)
    nav.filter_ledge_spans(int(cfg.walkable_height), int(cfg.walkable_climb), hf)
    nav.filter_walkable_low_height_spans(int(cfg.walkable_height), hf)
    
    filtered_spans := count_walkable_spans(hf)
    get_span_distribution(hf, &quadrants)
    
    log.info("After filtering:")
    log.infof("  Walkable spans: %d", filtered_spans)
    log.infof("  Distribution (NE,NW,SW,SE): %d,%d,%d,%d", 
              quadrants[0], quadrants[1], quadrants[2], quadrants[3])
    
    append(&results, Test_Result{
        stage = "Filtering",
        count = filtered_spans,
        values = {f32(quadrants[0]), f32(quadrants[1]), 
                  f32(quadrants[2]), f32(quadrants[3])},
        details = fmt.tprintf("Filtered spans: %d", filtered_spans),
    })
    
    // Step 8: Build compact heightfield
    chf := new(nav.Compact_Heightfield)
    defer nav.free_compact_heightfield(chf)
    
    if !nav.build_compact_heightfield(cfg.walkable_height, cfg.walkable_climb, hf, chf) {
        log.error("Failed to build compact heightfield")
        testing.fail(t)
        return
    }
    
    log.info("Compact heightfield:")
    log.infof("  Span count: %d", chf.span_count)
    log.infof("  Max regions: %d", chf.max_regions)
    
    append(&results, Test_Result{
        stage = "Compact Heightfield",
        count = int(chf.span_count),
        values = {},
        details = fmt.tprintf("Spans: %d", chf.span_count),
    })
    
    // Step 9: Erode walkable area
    if !nav.erode_walkable_area(cfg.walkable_radius, chf) {
        log.error("Failed to erode walkable area")
        testing.fail(t)
        return
    }
    
    // Step 10: Build distance field
    if !nav.build_distance_field(chf) {
        log.error("Failed to build distance field")
        testing.fail(t)
        return
    }
    
    // Step 11: Build regions
    if !nav.build_regions(chf, 0, cfg.min_region_area, cfg.merge_region_area) {
        log.error("Failed to build regions")
        testing.fail(t)
        return
    }
    
    log.infof("Regions: %d", chf.max_regions)
    append(&results, Test_Result{
        stage = "Regions",
        count = int(chf.max_regions),
        values = {},
        details = "",
    })
    
    // Step 12: Build contours
    cset := nav.alloc_contour_set()
    defer nav.free_contour_set(cset)
    
    if !nav.build_contours(chf, cfg.max_simplification_error, cfg.max_edge_len, cset) {
        log.error("Failed to build contours")
        testing.fail(t)
        return
    }
    
    log.infof("Contours: %d", len(cset.conts))
    append(&results, Test_Result{
        stage = "Contours",
        count = len(cset.conts),
        values = {},
        details = "",
    })
    
    // Step 13: Build polygon mesh
    pmesh := nav.alloc_poly_mesh()
    defer nav.free_poly_mesh(pmesh)
    
    if !nav.build_poly_mesh(cset, cfg.max_verts_per_poly, pmesh) {
        log.error("Failed to build polygon mesh")
        testing.fail(t)
        return
    }
    
    log.info("Polygon mesh:")
    log.infof("  Vertices: %d", len(pmesh.verts))
    log.infof("  Polygons: %d", pmesh.npolys)
    
    append(&results, Test_Result{
        stage = "Polygon Mesh",
        count = int(pmesh.npolys),
        values = {f32(len(pmesh.verts))},
        details = fmt.tprintf("Verts: %d", len(pmesh.verts)),
    })
    
    // Step 14: Build detail mesh
    dmesh := nav.alloc_poly_mesh_detail()
    defer nav.free_poly_mesh_detail(dmesh)
    
    if !nav.build_poly_mesh_detail(pmesh, chf, cfg.detail_sample_dist, cfg.detail_sample_max_error, dmesh) {
        log.error("Failed to build detail mesh")
        testing.fail(t)
        return
    }
    
    log.info("Detail mesh:")
    log.infof("  Meshes: %d", len(dmesh.meshes))
    log.infof("  Vertices: %d", len(dmesh.verts))
    log.infof("  Triangles: %d", len(dmesh.tris))
    
    append(&results, Test_Result{
        stage = "Detail Mesh",
        count = len(dmesh.meshes),
        values = {f32(len(dmesh.verts)), f32(len(dmesh.tris))},
        details = fmt.tprintf("Verts: %d, Tris: %d", len(dmesh.verts), len(dmesh.tris)),
    })
    
    // Save results for comparison
    save_results("odin_test_results.txt", results[:])
    log.info("\n=== Results saved to odin_test_results.txt ===")
}