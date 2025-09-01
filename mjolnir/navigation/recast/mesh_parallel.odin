package navigation_recast

import "core:sync"
import "core:thread"
import "core:slice"
import "core:log"
import "core:mem"
import "core:math"
import "core:math/linalg"
import "base:runtime"

// Multi-threaded mesh building configuration
Parallel_Mesh_Config :: struct {
    max_workers:       int,     // Maximum number of worker threads (0 = auto)
    chunk_size:        int,     // Number of contours per work chunk
    enable_vertex_weld: bool,   // Enable vertex welding optimization
    weld_tolerance:    f32,     // Tolerance for vertex welding
}

// Default parallel mesh building configuration
PARALLEL_MESH_DEFAULT_CONFIG :: Parallel_Mesh_Config{
    max_workers = 0,           // Auto-detect CPU cores
    chunk_size = 32,           // Process 32 contours per chunk
    enable_vertex_weld = true,
    weld_tolerance = 0.1,
}

// Work item for processing contours
Contour_Work_Item :: struct {
    contour_start:     int,           // Starting contour index
    contour_count:     int,           // Number of contours to process
    nvp:              i32,            // Max vertices per polygon
    worker_id:        int,            // Worker thread ID
}

// Result from processing a chunk of contours
Contour_Work_Result :: struct {
    vertices:         [dynamic]Mesh_Vertex,
    polygons:         [dynamic]Poly_Build,
    vertex_buckets:   []Vertex_Bucket,
    success:          bool,
    worker_id:        int,
}

// Context for mesh building with parallel support
Mesh_Build_Context :: struct {
    contour_set:      ^Contour_Set,
    config:           Parallel_Mesh_Config,

    // Work distribution
    work_queue:       [dynamic]Contour_Work_Item,

    // Result collection
    results:          [dynamic]Contour_Work_Result,
}

// Parallel worker context
Parallel_Worker_Context :: struct {
    build_ctx:      ^Mesh_Build_Context,
    work_index:     int,
    results_mutex:  sync.Mutex,
    work_mutex:     sync.Mutex,
}

// Worker thread procedure
parallel_mesh_worker :: proc(data: rawptr) {
    worker_ctx := cast(^Parallel_Worker_Context)data
    worker_id := sync.current_thread_id()

    for {
        // Get next work item (work stealing)
        sync.mutex_lock(&worker_ctx.work_mutex)
        if worker_ctx.work_index >= len(worker_ctx.build_ctx.work_queue) {
            sync.mutex_unlock(&worker_ctx.work_mutex)
            break
        }

        work_item := worker_ctx.build_ctx.work_queue[worker_ctx.work_index]
        work_item.worker_id = int(worker_id)
        worker_ctx.work_index += 1
        sync.mutex_unlock(&worker_ctx.work_mutex)

        // Process work item
        result := process_contour_chunk(worker_ctx.build_ctx, work_item)

        // Store result
        sync.mutex_lock(&worker_ctx.results_mutex)
        append(&worker_ctx.build_ctx.results, result)
        sync.mutex_unlock(&worker_ctx.results_mutex)
    }
}

// Build polygon mesh using multiple threads
build_poly_mesh_parallel :: proc(cset: ^Contour_Set, nvp: i32, pmesh: ^Poly_Mesh,
                                   config: Parallel_Mesh_Config = PARALLEL_MESH_DEFAULT_CONFIG) -> bool {
    if cset == nil || pmesh == nil do return false
    if len(cset.conts) == 0 do return false
    if nvp < 3 do return false

    return _build_mesh_parallel_impl(cset, nvp, pmesh, config)
}

// Internal implementation with proper error handling
_build_mesh_parallel_impl :: proc(cset: ^Contour_Set, nvp: i32, pmesh: ^Poly_Mesh, config: Parallel_Mesh_Config) -> bool {
    log.infof("Building polygon mesh in parallel from %d contours, max verts per poly: %d", len(cset.conts), nvp)

    // Determine number of worker threads
    num_workers := config.max_workers
    if num_workers <= 0 {
        // Fallback for auto-detection
        num_workers = max(1, 4) // Default to 4 threads if runtime info not available
    }
    num_workers = min(num_workers, int(len(cset.conts))) // Don't use more workers than contours

    log.infof("Using %d worker threads for mesh building", num_workers)

    // Initialize mesh
    // Initialize arrays - poly count determined by array lengths
    pmesh.maxpolys = 0
    pmesh.nvp = nvp
    pmesh.bmin = cset.bmin
    pmesh.bmax = cset.bmax
    pmesh.cs = cset.cs
    pmesh.ch = cset.ch
    pmesh.border_size = cset.border_size
    pmesh.max_edge_error = cset.max_error

    // Create build context
    build_ctx := Mesh_Build_Context{
        contour_set = cset,
        config = config,
        work_queue = make([dynamic]Contour_Work_Item),
        results = make([dynamic]Contour_Work_Result),
    }
    defer {
        delete(build_ctx.work_queue)
        // Results will be cleaned up after merging
    }

    // Note: Synchronization primitives would be initialized here for true parallel processing

    // Create work items
    if !create_work_items(&build_ctx) {
        log.error("Failed to create work items")
        return false
    }

    // Debug: Immediate check after work items creation
    log.infof("Work items created successfully, queue length: %d", len(build_ctx.work_queue))

    // Process work items in parallel using thread pool
    work_queue_len := len(build_ctx.work_queue)
    log.infof("Starting to process %d work items with %d workers", work_queue_len, num_workers)

    if work_queue_len == 0 {
        log.warn("No work items to process")
        return false
    }

    // Parallel processing with work stealing
    if num_workers > 1 {
        // Create worker context
        worker_ctx := Parallel_Worker_Context{
            build_ctx = &build_ctx,
            work_index = 0,
            results_mutex = {},
            work_mutex = {},
        }

        // Create thread pool
        thread_pool := make([]^thread.Thread, num_workers)
        defer delete(thread_pool)

        // Launch worker threads
        for i in 0..<num_workers {
            thread_pool[i] = thread.create_and_start_with_data(&worker_ctx, parallel_mesh_worker, context)
        }

        // Wait for completion
        for i in 0..<num_workers {
            thread.join(thread_pool[i])
            thread.destroy(thread_pool[i])
        }
    } else {
        // Fallback to sequential processing
        for work_idx := 0; work_idx < work_queue_len; work_idx += 1 {
            if work_idx >= len(build_ctx.work_queue) {
                log.errorf("Work queue index out of bounds: %d >= %d", work_idx, len(build_ctx.work_queue))
                break
            }

            work_item := build_ctx.work_queue[work_idx]
            work_item.worker_id = 0

            result := process_contour_chunk(&build_ctx, work_item)
            append(&build_ctx.results, result)
        }
    }

    log.infof("All worker threads completed, merging results from %d chunks", len(build_ctx.results))

    // Merge results and build final mesh
    success := merge_worker_results(&build_ctx, pmesh)

    // Clean up results
    for &result in build_ctx.results {
        delete(result.vertices)
        for &poly in result.polygons {
            delete(poly.verts)
        }
        delete(result.polygons)
        delete(result.vertex_buckets)
    }
    delete(build_ctx.results)

    if !success {
        log.error("Failed to merge worker results")
        return false
    }

    log.infof("Successfully built polygon mesh in parallel: %d vertices, %d polygons", len(pmesh.verts), pmesh.npolys)
    return true
}

// Create work items for distributing contours across threads
create_work_items :: proc(build_ctx: ^Mesh_Build_Context) -> bool {
    chunk_size := build_ctx.config.chunk_size
    total_contours := int(len(build_ctx.contour_set.conts))

    log.infof("Creating work items: total_contours=%d, chunk_size=%d", total_contours, chunk_size)

    // Infinite loop protection
    if chunk_size <= 0 {
        log.errorf("Invalid chunk size: %d", chunk_size)
        return false
    }

    if total_contours <= 0 {
        log.warnf("No contours to process: %d", total_contours)
        return false
    }

    max_iterations := (total_contours / chunk_size) + 2 // Expected iterations + safety margin
    iteration_count := 0

    for start := 0; start < total_contours; start += chunk_size {
        iteration_count += 1
        if iteration_count > max_iterations {
            log.errorf("Work item creation exceeded maximum iterations (%d), possible infinite loop", max_iterations)
            return false
        }

        count := min(chunk_size, total_contours - start)

        log.debugf("Creating work item: start=%d, count=%d, iteration=%d", start, count, iteration_count)

        work_item := Contour_Work_Item{
            contour_start = start,
            contour_count = count,
            nvp = 6, // Default vertices per polygon
        }

        append(&build_ctx.work_queue, work_item)
    }

    log.infof("Created %d work items for %d contours (chunk size: %d)",
              len(build_ctx.work_queue), total_contours, chunk_size)

    return len(build_ctx.work_queue) > 0
}

// Note: Full threading implementation can be added later when Odin threading API stabilizes

// Process a chunk of contours in a worker thread
process_contour_chunk :: proc(build_ctx: ^Mesh_Build_Context, work_item: Contour_Work_Item) -> Contour_Work_Result {
    result := Contour_Work_Result{
        worker_id = work_item.worker_id,
        success = false,
    }

    cset := build_ctx.contour_set
    nvp := work_item.nvp

    // Estimate sizes for this chunk
    max_vertices := 0
    max_polygons := 0

    for i in work_item.contour_start..<(work_item.contour_start + work_item.contour_count) {
        if i >= int(len(cset.conts)) do break
        cont := &cset.conts[i]
        if len(cont.verts) < 3 do continue
        max_vertices += len(cont.verts)
        max_polygons += len(cont.verts) - 2
    }

    if max_vertices == 0 {
        result.success = true // Empty chunk is valid
        return result
    }

    // Allocate local structures
    result.vertices = make([dynamic]Mesh_Vertex, 0, max_vertices)
    result.polygons = make([dynamic]Poly_Build, 0, max_polygons)
    result.vertex_buckets = make([]Vertex_Bucket, RC_VERTEX_BUCKET_COUNT)

    // Initialize vertex buckets
    for &bucket in result.vertex_buckets {
        bucket.first = -1
    }

    // Temporary work arrays
    triangles := make([dynamic]i32, 0, max_polygons * 3)
    defer delete(triangles)

    contour_indices := make([dynamic]i32, 0, 32)
    defer delete(contour_indices)

    vert_coords := make([dynamic][3]u16, 0, max_vertices)
    defer delete(vert_coords)

    // Process contours in this chunk
    processed_count := 0
    expected_iterations := work_item.contour_count
    log.infof("Worker %d: Processing %d contours from %d to %d",
              work_item.worker_id, expected_iterations,
              work_item.contour_start, work_item.contour_start + work_item.contour_count - 1)

    for i in work_item.contour_start..<(work_item.contour_start + work_item.contour_count) {
        if i >= int(len(cset.conts)) {
            log.warnf("Worker %d: Contour index %d exceeds total contours %d", work_item.worker_id, i, len(cset.conts))
            break
        }

        cont := &cset.conts[i]
        if len(cont.verts) < 3 {
            log.debugf("Worker %d: Skipping contour %d with %d vertices", work_item.worker_id, i, len(cont.verts))
            continue
        }

        log.debugf("Worker %d: Processing contour %d with %d vertices", work_item.worker_id, i, len(cont.verts))

        // Convert contour vertices to mesh vertices
        resize(&contour_indices, len(cont.verts))

        for j in 0..<len(cont.verts) {
            v := cont.verts[j]
            vert_idx := add_vertex(u16(v[0]), u16(v[1]), u16(v[2]), &result.vertices, result.vertex_buckets)
            contour_indices[j] = vert_idx
        }

        // Build coordinate array for triangulation
        resize(&vert_coords, len(result.vertices))
        for v_idx in 0..<len(result.vertices) {
            vert_coords[v_idx] = {result.vertices[v_idx].x, result.vertices[v_idx].y, result.vertices[v_idx].z}
        }

        // Triangulate the contour
        clear(&triangles)
        if triangulate_polygon_u16(vert_coords[:], contour_indices[:], &triangles) {
            // Merge triangles into polygons
            merge_triangles_into_polygons(triangles[:], &result.polygons, nvp, cont.area, cont.reg)
            processed_count += 1
        } else {
            log.warnf("Worker %d: Failed to triangulate contour %d", work_item.worker_id, i)
        }
    }

    log.debugf("Worker %d: Processed %d/%d contours, generated %d vertices, %d polygons",
               work_item.worker_id, processed_count, work_item.contour_count,
               len(result.vertices), len(result.polygons))

    result.success = processed_count > 0 || work_item.contour_count == 0
    return result
}

// Merge results from all worker threads into final mesh
merge_worker_results :: proc(build_ctx: ^Mesh_Build_Context, pmesh: ^Poly_Mesh) -> bool {
    if len(build_ctx.results) == 0 {
        log.warn("No worker results to merge")
        return false
    }

    nvp := pmesh.nvp

    // Count total vertices and polygons
    total_vertices := 0
    total_polygons := 0

    for &result in build_ctx.results {
        if !result.success do continue
        total_vertices += len(result.vertices)
        total_polygons += len(result.polygons)
    }

    if total_vertices == 0 || total_polygons == 0 {
        log.warn("No valid geometry generated by workers")
        return false
    }

    log.infof("Merging results: %d total vertices, %d total polygons", total_vertices, total_polygons)

    // Global vertex welding for thread-local duplicates
    final_vertices := make([dynamic]Mesh_Vertex, 0, total_vertices)
    defer delete(final_vertices)

    global_buckets := make([]Vertex_Bucket, RC_VERTEX_BUCKET_COUNT)
    defer delete(global_buckets)
    for &bucket in global_buckets {
        bucket.first = -1
    }

    // Vertex remapping for each worker result
    vertex_remaps := make([][]i32, len(build_ctx.results))
    defer {
        for remap in vertex_remaps {
            delete(remap)
        }
        delete(vertex_remaps)
    }

    // Merge and deduplicate vertices
    for result_idx in 0..<len(build_ctx.results) {
        result := &build_ctx.results[result_idx]
        if !result.success do continue

        vertex_remaps[result_idx] = make([]i32, len(result.vertices))

        for v_idx in 0..<len(result.vertices) {
            vertex := result.vertices[v_idx]
            global_idx := add_vertex(vertex.x, vertex.y, vertex.z, &final_vertices, global_buckets)
            vertex_remaps[result_idx][v_idx] = global_idx
        }
    }

    // Apply vertex welding if enabled
    if build_ctx.config.enable_vertex_weld && build_ctx.config.weld_tolerance > 0 {
        weld_vertices(&final_vertices, build_ctx.config.weld_tolerance, vertex_remaps[:])
    }

    // Allocate final mesh arrays
    pmesh.maxpolys = i32(total_polygons)

    pmesh.verts = make([][3]u16, len(final_vertices))
    pmesh.polys = make([]u16, total_polygons * int(nvp) * 2)
    pmesh.regs = make([]u16, total_polygons)
    pmesh.flags = make([]u16, total_polygons)
    pmesh.areas = make([]u8, total_polygons)

    // Initialize polygon data
    for i in 0..<len(pmesh.polys) {
        pmesh.polys[i] = RC_MESH_NULL_IDX
    }

    // Copy final vertices
    for i in 0..<len(final_vertices) {
        vertex := final_vertices[i]
        pmesh.verts[i] = [3]u16{vertex.x, vertex.y, vertex.z}
    }

    // Copy polygons with remapped vertex indices
    poly_idx := 0
    for result_idx in 0..<len(build_ctx.results) {
        result := &build_ctx.results[result_idx]
        if !result.success do continue

        remap := vertex_remaps[result_idx]

        for poly_i in 0..<len(result.polygons) {
            poly := result.polygons[poly_i]
            pi := poly_idx * int(nvp) * 2

            // Copy remapped vertex indices
            for j in 0..<len(poly.verts) {
                original_vert := poly.verts[j]
                remapped_vert := remap[original_vert]
                pmesh.polys[pi + int(j)] = u16(remapped_vert)
            }

            // Set polygon attributes
            pmesh.regs[poly_idx] = poly.reg
            pmesh.areas[poly_idx] = poly.area
            pmesh.flags[poly_idx] = 1  // Default walkable flag

            poly_idx += 1
        }
    }

    // Build edge connectivity
    edges := make([dynamic]Mesh_Edge, 0, total_polygons * 3)
    defer delete(edges)

    if build_mesh_edges(pmesh, &edges, i32(total_polygons * 3)) {
        update_polygon_neighbors(pmesh, edges[:])
        log.infof("Built %d edges for polygon connectivity", len(edges))
    } else {
        log.warn("Failed to build mesh edges")
    }

    // Validate final mesh
    if !validate_poly_mesh(pmesh) {
        log.error("Generated invalid polygon mesh")
        return false
    }

    return true
}

// Weld vertices that are within tolerance distance
weld_vertices :: proc(vertices: ^[dynamic]Mesh_Vertex, tolerance: f32, vertex_remaps: [][]i32) {
    if len(vertices) == 0 do return

    log.infof("Welding %d vertices with tolerance %f", len(vertices), tolerance)

    tolerance_sq := tolerance * tolerance
    weld_map := make([]i32, len(vertices))
    defer delete(weld_map)

    // Initialize weld map to identity
    for i in 0..<len(vertices) {
        weld_map[i] = i32(i)
    }

    // Find vertices to weld (simple O(n²) approach for now)
    welded_count := 0
    for i in 0..<len(vertices) {
        if weld_map[i] != i32(i) do continue // Already welded

        v1 := vertices[i]
        for j in (i+1)..<len(vertices) {
            if weld_map[j] != i32(j) do continue // Already welded

            v2 := vertices[j]

            // Calculate distance squared using vector operations
            diff := [3]f32{f32(v2.x) - f32(v1.x), f32(v2.y) - f32(v1.y), f32(v2.z) - f32(v1.z)}
            dist_sq := linalg.length2(diff)

            if dist_sq <= tolerance_sq {
                weld_map[j] = i32(i)  // Weld j to i
                welded_count += 1
            }
        }
    }

    // Update vertex remaps to account for welding
    for remap in vertex_remaps {
        for &vertex_idx in remap {
            vertex_idx = weld_map[vertex_idx]
        }
    }

    log.infof("Welded %d vertex pairs", welded_count)
}
