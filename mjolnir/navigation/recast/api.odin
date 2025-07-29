package navigation_recast

import "core:log"
import "core:fmt"
import "core:mem"

// Import required functions and types from other files
// Note: In a real implementation, these would be imported or the types would be properly accessible

// ========================================
// ENHANCED CONFIGURATION SYSTEM
// ========================================

// Configuration presets for common use cases
Config_Preset :: enum {
    Fast,         // Fast generation, lower quality
    Balanced,     // Good balance of speed and quality  
    High_Quality, // Maximum quality, slower generation
    Custom,       // User-defined configuration
}

// Enhanced configuration with validation and presets
Enhanced_Config :: struct {
    // Base configuration
    base: Config,
    
    // Detail mesh parameters (not in base config)
    detail_sample_distance:    f32,
    detail_sample_max_error:   f32,
    
    // Performance options
    preset:                    Config_Preset,
    enable_debug_output:       bool,
    enable_validation:         bool,
    enable_parallel_mesh:      bool,
    parallel_mesh_config:      Parallel_Mesh_Config,
    
    // Progress reporting
    progress_callback:         proc(step: Pipeline_Step, progress: f32, message: string),
    
    // Memory management
    use_custom_allocator:      bool,
    allocator:                 mem.Allocator,
}

// Pipeline steps for progress reporting
Pipeline_Step :: enum {
    Initialize,
    Rasterize,
    Filter,
    BuildCompactHeightfield,
    ErodeWalkableArea,
    BuildDistanceField,
    BuildRegions,
    BuildContours,
    BuildPolygonMesh,
    BuildDetailMesh,
    Finalize,
}

// Create configuration from preset
create_config_from_preset :: proc(preset: Config_Preset) -> Enhanced_Config {
    cfg := Enhanced_Config{
        preset = preset,
        enable_debug_output = false,
        enable_validation = true,
        use_custom_allocator = false,
        allocator = context.allocator,
    }
    
    switch preset {
    case .Fast:
        cfg.base = Config{
            cs = 0.5,                      // Larger cell size for speed
            ch = 0.3,
            walkable_slope_angle = 45,
            walkable_height = 6,           // Smaller values for speed
            walkable_climb = 3,
            walkable_radius = 1,
            max_edge_len = 20,             // Longer edges for speed
            max_simplification_error = 2.0, // Higher error tolerance
            min_region_area = 20,          // Larger minimum regions
            merge_region_area = 50,
            max_verts_per_poly = 6,
            detail_sample_dist = 10,       // Proportional to cell size (cs * 20)
            detail_sample_max_error = 2,
        }
        cfg.detail_sample_distance = 10.0
        cfg.detail_sample_max_error = 2.0
        cfg.enable_parallel_mesh = true
        cfg.parallel_mesh_config = Parallel_Mesh_Config{
            max_workers = 0,    // Auto-detect
            chunk_size = 64,    // Large chunks for speed
            enable_vertex_weld = false,  // Skip welding for speed
            weld_tolerance = 0.0,
        }
        
    case .Balanced:
        cfg.base = Config{
            cs = 0.3,
            ch = 0.2,
            walkable_slope_angle = 45,
            walkable_height = 10,
            walkable_climb = 4,
            walkable_radius = 2,
            max_edge_len = 12,
            max_simplification_error = 1.3,
            min_region_area = 8,
            merge_region_area = 20,
            max_verts_per_poly = 6,
            detail_sample_dist = 6,
            detail_sample_max_error = 1,
        }
        cfg.detail_sample_distance = 6.0
        cfg.detail_sample_max_error = 1.0
        cfg.enable_parallel_mesh = true
        cfg.parallel_mesh_config = Parallel_Mesh_Config{
            max_workers = 0,    // Auto-detect
            chunk_size = 32,    // Balanced chunk size
            enable_vertex_weld = true,
            weld_tolerance = 0.1,
        }
        
    case .High_Quality:
        cfg.base = Config{
            cs = 0.15,                     // Smaller cell size for precision
            ch = 0.1,
            walkable_slope_angle = 45,
            walkable_height = 15,          // Higher precision
            walkable_climb = 5,
            walkable_radius = 3,
            max_edge_len = 6,              // Shorter edges for quality
            max_simplification_error = 0.8, // Lower error tolerance
            min_region_area = 4,           // Smaller minimum regions
            merge_region_area = 10,
            max_verts_per_poly = 6,        // Standard polygon vertex count
            detail_sample_dist = 3,        // More detail samples
            detail_sample_max_error = 0.5,
        }
        cfg.detail_sample_distance = 3.0
        cfg.detail_sample_max_error = 0.5
        cfg.enable_parallel_mesh = true
        cfg.parallel_mesh_config = Parallel_Mesh_Config{
            max_workers = 0,    // Auto-detect
            chunk_size = 16,    // Small chunks for quality
            enable_vertex_weld = true,
            weld_tolerance = 0.05,  // Tight tolerance for quality
        }
        
    case .Custom:
        // Start with balanced and let user modify
        cfg = create_config_from_preset(.Balanced)
        cfg.preset = .Custom
    }
    
    return cfg
}

// Validate configuration parameters
validate_enhanced_config :: proc(cfg: ^Enhanced_Config) -> (bool, string) {
    // Validate base configuration first
    if !validate_config(&cfg.base) {
        return false, "Base configuration validation failed"
    }
    
    // Validate detail mesh parameters
    if cfg.detail_sample_distance <= 0 {
        return false, "Detail sample distance must be positive"
    }
    
    if cfg.detail_sample_max_error <= 0 {
        return false, "Detail sample max error must be positive"
    }
    
    // Check for reasonable parameter ranges
    if cfg.base.cs > 2.0 {
        return false, "Cell size too large (max 2.0), will result in poor quality"
    }
    
    if cfg.base.cs < 0.05 {
        return false, "Cell size too small (min 0.05), will be very slow"
    }
    
    if cfg.base.walkable_height < 3 {
        return false, "Walkable height too small (min 3 cells)"
    }
    
    if cfg.base.max_verts_per_poly > DT_VERTS_PER_POLYGON {
        return false, fmt.tprintf("Max vertices per polygon exceeds limit (%d)", DT_VERTS_PER_POLYGON)
    }
    
    return true, ""
}

// Calculate memory requirements for a given configuration
estimate_memory_usage :: proc(cfg: ^Enhanced_Config, vert_count, tri_count: i32) -> (bytes: int, breakdown: map[string]int) {
    breakdown = make(map[string]int)
    
    // Calculate grid dimensions
    grid_area := i32((cfg.base.bmax.x - cfg.base.bmin.x) / cfg.base.cs + 0.5) * 
                 i32((cfg.base.bmax.z - cfg.base.bmin.z) / cfg.base.cs + 0.5)
    
    // Heightfield memory
    heightfield_mem := int(grid_area * size_of(^Rc_Span)) // Span pointers
    heightfield_mem += int(tri_count * 2 * size_of(Rc_Span)) // Approximate span count
    breakdown["heightfield"] = heightfield_mem
    
    // Compact heightfield memory
    compact_mem := int(grid_area * size_of(Rc_Compact_Cell))
    compact_mem += int(tri_count * size_of(Rc_Compact_Span))
    compact_mem += int(tri_count * size_of(u8)) // Areas
    compact_mem += int(tri_count * size_of(u16)) // Distance field
    breakdown["compact_heightfield"] = compact_mem
    
    // Contour memory (estimated)
    contour_mem := int(tri_count / 4 * size_of(Rc_Contour)) // Rough estimate
    contour_mem += int(tri_count * 4 * size_of(i32)) // Vertex data
    breakdown["contours"] = contour_mem
    
    // Polygon mesh memory
    poly_mem := int(tri_count * size_of(u16) * 3) // Vertices
    poly_mem += int(tri_count / 2 * cfg.base.max_verts_per_poly * 2 * size_of(u16)) // Polygons
    breakdown["polygon_mesh"] = poly_mem
    
    // Detail mesh memory
    detail_mem := int(tri_count * 3 * size_of(f32)) // Detail vertices
    detail_mem += int(tri_count * 4 * size_of(u8)) // Detail triangles
    breakdown["detail_mesh"] = detail_mem
    
    // Calculate total
    bytes = 0
    for _, mem in breakdown {
        bytes += mem
    }
    
    // Add 20% overhead for miscellaneous allocations
    overhead := bytes / 5
    breakdown["overhead"] = overhead
    bytes += overhead
    
    return bytes, breakdown
}

// ========================================
// ERROR HANDLING AND STATUS REPORTING
// ========================================

// Build result with comprehensive error information
Build_Result :: struct {
    success:         bool,
    status:          Status,
    error_message:   string,
    
    // Pipeline progress
    completed_steps: bit_set[Pipeline_Step],
    failed_step:     Pipeline_Step,
    
    // Performance metrics
    total_time_ms:   f64,
    step_times_ms:   map[Pipeline_Step]f64,
    
    // Memory usage
    peak_memory_mb:  f64,
    final_memory_mb: f64,
    
    // Output validation
    validation_passed: bool,
    validation_warnings: [dynamic]string,
    
    // Generated data
    polygon_mesh:    ^Rc_Poly_Mesh,
    detail_mesh:     ^Rc_Poly_Mesh_Detail,
}

// Create error result
create_error_result :: proc(step: Pipeline_Step, message: string) -> Build_Result {
    return Build_Result{
        success = false,
        error_message = message,
        failed_step = step,
        status = {.Invalid_Param},
        validation_warnings = make([dynamic]string),
    }
}

// Create success result
create_success_result :: proc(pmesh: ^Rc_Poly_Mesh, dmesh: ^Rc_Poly_Mesh_Detail) -> Build_Result {
    return Build_Result{
        success = true,
        status = {.Success},
        polygon_mesh = pmesh,
        detail_mesh = dmesh,
        validation_warnings = make([dynamic]string),
    }
}

// Free build result resources
free_build_result :: proc(result: ^Build_Result) {
    if result.polygon_mesh != nil {
        rc_free_poly_mesh(result.polygon_mesh)
        result.polygon_mesh = nil
    }
    
    if result.detail_mesh != nil {
        rc_free_poly_mesh_detail(result.detail_mesh)
        result.detail_mesh = nil
    }
    
    delete(result.validation_warnings)
    
    if result.step_times_ms != nil {
        delete(result.step_times_ms)
    }
}

// ========================================
// GEOMETRY INPUT UTILITIES
// ========================================

// Simplified geometry input structure
Geometry_Input :: struct {
    vertices:    []f32,    // Vertex data [x, y, z, x, y, z, ...]
    indices:     []i32,    // Triangle indices [i0, i1, i2, i0, i1, i2, ...]
    areas:       []u8,     // Area types per triangle
}

// Create geometry input from separate arrays
create_geometry_input :: proc(verts: []f32, tris: []i32, areas: []u8) -> (Geometry_Input, bool) {
    // Check for empty geometry
    if len(verts) == 0 || len(tris) == 0 || len(areas) == 0 {
        log.warnf("Empty geometry provided - vertices: %d, triangles: %d, areas: %d", len(verts), len(tris), len(areas))
        return {}, false
    }
    
    if len(verts) % 3 != 0 {
        log.errorf("Vertex array length must be multiple of 3, got %d", len(verts))
        return {}, false
    }
    
    if len(tris) % 3 != 0 {
        log.errorf("Triangle array length must be multiple of 3, got %d", len(tris))
        return {}, false
    }
    
    tri_count := len(tris) / 3
    if len(areas) != tri_count {
        log.warnf("Area array length (%d) must match triangle count (%d)", len(areas), tri_count)
        return {}, false
    }
    
    vert_count := len(verts) / 3
    for i in 0..<len(tris) {
        if tris[i] < 0 || tris[i] >= i32(vert_count) {
            log.errorf("Triangle index %d is out of bounds (vertex count: %d)", tris[i], vert_count)
            return {}, false
        }
    }
    
    return Geometry_Input{
        vertices = verts,
        indices = tris,
        areas = areas,
    }, true
}

// Auto-calculate bounds from geometry
auto_calculate_bounds :: proc(geometry: ^Geometry_Input, cfg: ^Enhanced_Config) {
    if len(geometry.vertices) < 3 {
        log.warn("No vertices to calculate bounds from")
        return
    }
    
    // Initialize with first vertex
    cfg.base.bmin = {geometry.vertices[0], geometry.vertices[1], geometry.vertices[2]}
    cfg.base.bmax = cfg.base.bmin
    
    // Find min/max for all vertices
    for i := 3; i < len(geometry.vertices); i += 3 {
        v := [3]f32{geometry.vertices[i], geometry.vertices[i+1], geometry.vertices[i+2]}
        cfg.base.bmin.x = min(cfg.base.bmin.x, v.x)
        cfg.base.bmin.y = min(cfg.base.bmin.y, v.y)
        cfg.base.bmin.z = min(cfg.base.bmin.z, v.z)
        cfg.base.bmax.x = max(cfg.base.bmax.x, v.x)
        cfg.base.bmax.y = max(cfg.base.bmax.y, v.y)
        cfg.base.bmax.z = max(cfg.base.bmax.z, v.z)
    }
    
    // Calculate grid size
    cfg.base.width = i32((cfg.base.bmax.x - cfg.base.bmin.x) / cfg.base.cs + 0.5)
    cfg.base.height = i32((cfg.base.bmax.z - cfg.base.bmin.z) / cfg.base.cs + 0.5)
    
    log.infof("Auto-calculated bounds: min(%.2f, %.2f, %.2f) max(%.2f, %.2f, %.2f) grid(%dx%d)",
              cfg.base.bmin.x, cfg.base.bmin.y, cfg.base.bmin.z,
              cfg.base.bmax.x, cfg.base.bmax.y, cfg.base.bmax.z,
              cfg.base.width, cfg.base.height)
}

// Validate geometry input
validate_geometry :: proc(geometry: ^Geometry_Input) -> (bool, string) {
    if len(geometry.vertices) == 0 {
        return false, "No vertices provided"
    }
    
    if len(geometry.indices) == 0 {
        return false, "No triangles provided"
    }
    
    if len(geometry.vertices) % 3 != 0 {
        return false, "Vertex count must be multiple of 3"
    }
    
    if len(geometry.indices) % 3 != 0 {
        return false, "Index count must be multiple of 3"
    }
    
    tri_count := len(geometry.indices) / 3
    if len(geometry.areas) != tri_count {
        return false, "Area count must match triangle count"
    }
    
    vert_count := len(geometry.vertices) / 3
    
    // Check for degenerate triangles
    degenerate_count := 0
    for i := 0; i < len(geometry.indices); i += 3 {
        i0, i1, i2 := geometry.indices[i], geometry.indices[i+1], geometry.indices[i+2]
        
        if i0 == i1 || i1 == i2 || i0 == i2 {
            degenerate_count += 1
            continue
        }
        
        if i0 < 0 || i0 >= i32(vert_count) ||
           i1 < 0 || i1 >= i32(vert_count) ||
           i2 < 0 || i2 >= i32(vert_count) {
            return false, fmt.tprintf("Triangle %d has invalid vertex indices", i/3)
        }
    }
    
    if degenerate_count > 0 {
        log.warnf("Found %d degenerate triangles", degenerate_count)
    }
    
    // Check for reasonable coordinate ranges
    for i := 0; i < len(geometry.vertices); i += 3 {
        x, y, z := geometry.vertices[i], geometry.vertices[i+1], geometry.vertices[i+2]
        if abs(x) > 100000 || abs(y) > 100000 || abs(z) > 100000 {
            log.warnf("Vertex %d has very large coordinates (%.2f, %.2f, %.2f)", i/3, x, y, z)
        }
    }
    
    return true, ""
}

// ========================================
// MEMORY MANAGEMENT UTILITIES
// ========================================

// Build context for automatic resource management
Build_Context :: struct {
    // Configuration
    config:          Enhanced_Config,
    
    // Intermediate resources (automatically freed)
    heightfield:     ^Rc_Heightfield,
    compact_hf:      ^Rc_Compact_Heightfield,
    contour_set:     ^Rc_Contour_Set,
    
    // Final results (returned to user)
    polygon_mesh:    ^Rc_Poly_Mesh,
    detail_mesh:     ^Rc_Poly_Mesh_Detail,
    
    // Progress tracking
    current_step:    Pipeline_Step,
    step_start_time: f64,
    total_start_time: f64,
    result:          Build_Result,
}

// Create build context with automatic cleanup
create_build_context :: proc(config: Enhanced_Config) -> ^Build_Context {
    ctx := new(Build_Context)
    ctx.config = config
    ctx.result.step_times_ms = make(map[Pipeline_Step]f64)
    ctx.result.validation_warnings = make([dynamic]string)
    return ctx
}

// Free build context and all intermediate resources
free_build_context :: proc(ctx: ^Build_Context) {
    if ctx == nil do return
    
    // Free intermediate resources
    if ctx.heightfield != nil {
        rc_free_heightfield(ctx.heightfield)
        ctx.heightfield = nil
    }
    
    if ctx.compact_hf != nil {
        rc_free_compact_heightfield(ctx.compact_hf)
        ctx.compact_hf = nil
    }
    
    if ctx.contour_set != nil {
        rc_free_contour_set(ctx.contour_set)
        ctx.contour_set = nil
    }
    
    // Don't free result maps - they're returned to user and freed by free_build_result
    
    free(ctx)
}

// Start timing a pipeline step
start_step :: proc(ctx: ^Build_Context, step: Pipeline_Step) {
    ctx.current_step = step
    ctx.step_start_time = get_time_ms()
    ctx.result.completed_steps += {step}
    
    if ctx.config.progress_callback != nil {
        step_progress := f32(card(ctx.result.completed_steps)) / f32(len(Pipeline_Step))
        step_name := fmt.tprintf("%v", step)
        ctx.config.progress_callback(step, step_progress, step_name)
    }
    
    if ctx.config.enable_debug_output {
        log.infof("Starting pipeline step: %v", step)
    }
}

// Finish timing a pipeline step
finish_step :: proc(ctx: ^Build_Context) {
    elapsed := get_time_ms() - ctx.step_start_time
    ctx.result.step_times_ms[ctx.current_step] = elapsed
    
    if ctx.config.enable_debug_output {
        log.infof("Completed pipeline step %v in %.2f ms", ctx.current_step, elapsed)
    }
}

// Simple time measurement (placeholder - replace with actual timing)
get_time_ms :: proc() -> f64 {
    // In a real implementation, this would use a proper timer
    // For now, return a placeholder
    return 0.0
}

// ========================================
// HIGH-LEVEL BUILD_NAVMESH() FUNCTION
// ========================================

// Main function - builds complete navigation mesh from geometry
build_navmesh :: proc(geometry: ^Geometry_Input, config: Enhanced_Config) -> Build_Result {
    // Validate inputs
    if valid, err := validate_geometry(geometry); !valid {
        return create_error_result(.Initialize, fmt.tprintf("Geometry validation failed: %s", err))
    }
    
    enhanced_config := config
    if valid, err := validate_enhanced_config(&enhanced_config); !valid {
        return create_error_result(.Initialize, fmt.tprintf("Configuration validation failed: %s", err))
    }
    
    // Auto-calculate bounds if not set
    if enhanced_config.base.bmin == enhanced_config.base.bmax {
        auto_calculate_bounds(geometry, &enhanced_config)
    }
    
    // Create build context for automatic resource management
    ctx := create_build_context(enhanced_config)
    defer {
        if enhanced_config.enable_debug_output {
            log.infof("DEBUG: Cleaning up build context")
        }
        free_build_context(ctx)
    }
    
    ctx.total_start_time = get_time_ms()
    
    // Execute the complete pipeline
    if !execute_pipeline(ctx, geometry) {
        return ctx.result
    }
    
    // Final validation if enabled
    if enhanced_config.enable_validation {
        validate_final_result(ctx)
    }
    
    // Calculate total time
    ctx.result.total_time_ms = get_time_ms() - ctx.total_start_time
    
    // Transfer ownership of final results to user
    result := ctx.result
    result.polygon_mesh = ctx.polygon_mesh
    result.detail_mesh = ctx.detail_mesh
    
    // Prevent double-free
    ctx.polygon_mesh = nil
    ctx.detail_mesh = nil
    
    if enhanced_config.enable_debug_output {
        log.infof("Navigation mesh build completed in %.2f ms", result.total_time_ms)
        log.infof("Generated %d polygons, %d detail vertices", 
                  result.polygon_mesh != nil ? result.polygon_mesh.npolys : 0,
                  result.detail_mesh != nil ? result.detail_mesh.nverts : 0)
    }
    
    return result
}

// Execute the complete pipeline
execute_pipeline :: proc(ctx: ^Build_Context, geometry: ^Geometry_Input) -> bool {
    cfg := &ctx.config.base
    
    // Step 1: Create heightfield
    log.infof("PIPELINE DEBUG: Starting heightfield creation")
    start_step(ctx, .Rasterize)
    {
        ctx.heightfield = rc_alloc_heightfield()
        if ctx.heightfield == nil {
            ctx.result = create_error_result(.Rasterize, "Failed to allocate heightfield")
            return false
        }
        
        if !rc_create_heightfield(ctx.heightfield, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch) {
            ctx.result = create_error_result(.Rasterize, "Failed to create heightfield")
            return false
        }
        
        // Rasterize geometry
        vert_count := i32(len(geometry.vertices) / 3)
        tri_count := i32(len(geometry.indices) / 3)
        
        if !rc_rasterize_triangles(geometry.vertices, vert_count, geometry.indices, geometry.areas, 
                                   tri_count, ctx.heightfield, cfg.walkable_climb) {
            ctx.result = create_error_result(.Rasterize, "Failed to rasterize triangles")
            return false
        }
    }
    finish_step(ctx)
    
    // Step 2: Filter spans
    log.infof("PIPELINE DEBUG: Starting filtering spans")
    start_step(ctx, .Filter)
    {
        rc_filter_low_hanging_walkable_obstacles(int(cfg.walkable_climb), ctx.heightfield)
        rc_filter_ledge_spans(int(cfg.walkable_height), int(cfg.walkable_climb), ctx.heightfield)
        rc_filter_walkable_low_height_spans(int(cfg.walkable_height), ctx.heightfield)
    }
    finish_step(ctx)
    
    // Step 3: Build compact heightfield
    log.infof("PIPELINE DEBUG: Starting compact heightfield")
    start_step(ctx, .BuildCompactHeightfield)
    {
        ctx.compact_hf = new(Rc_Compact_Heightfield)
        if !rc_build_compact_heightfield(cfg.walkable_height, cfg.walkable_climb, ctx.heightfield, ctx.compact_hf) {
            ctx.result = create_error_result(.BuildCompactHeightfield, "Failed to build compact heightfield")
            return false
        }
        
        if ctx.compact_hf.span_count == 0 {
            ctx.result = create_error_result(.BuildCompactHeightfield, "No walkable spans found")
            return false
        }
    }
    finish_step(ctx)
    
    // Step 4: Erode walkable area
    log.infof("PIPELINE DEBUG: Starting erode walkable area")
    start_step(ctx, .ErodeWalkableArea)
    {
        if !rc_erode_walkable_area(cfg.walkable_radius, ctx.compact_hf) {
            ctx.result = create_error_result(.ErodeWalkableArea, "Failed to erode walkable area")
            return false
        }
    }
    finish_step(ctx)
    
    // Step 5: Build distance field
    log.infof("PIPELINE DEBUG: Starting distance field")
    start_step(ctx, .BuildDistanceField)
    {
        if !rc_build_distance_field(ctx.compact_hf) {
            ctx.result = create_error_result(.BuildDistanceField, "Failed to build distance field")
            return false
        }
    }
    finish_step(ctx)
    
    // Step 6: Build regions
    log.infof("PIPELINE DEBUG: Starting build regions")
    start_step(ctx, .BuildRegions)
    {
        if !rc_build_regions(ctx.compact_hf, cfg.border_size, cfg.min_region_area, cfg.merge_region_area) {
            ctx.result = create_error_result(.BuildRegions, "Failed to build regions")
            return false
        }
        
        if ctx.compact_hf.max_regions == 0 {
            ctx.result = create_error_result(.BuildRegions, "No regions created")
            return false
        }
    }
    finish_step(ctx)
    
    // Step 7: Build contours
    log.infof("PIPELINE DEBUG: Starting build contours")
    start_step(ctx, .BuildContours)
    {
        ctx.contour_set = rc_alloc_contour_set()
        if ctx.contour_set == nil {
            ctx.result = create_error_result(.BuildContours, "Failed to allocate contour set")
            return false
        }
        
        // Don't free contour set here - it's needed for polygon mesh building
        
        if !rc_build_contours(ctx.compact_hf, cfg.max_simplification_error, cfg.max_edge_len, ctx.contour_set) {
            rc_free_contour_set(ctx.contour_set)
            ctx.contour_set = nil
            ctx.result = create_error_result(.BuildContours, "Failed to build contours")
            return false
        }
        
        if ctx.contour_set.nconts == 0 {
            rc_free_contour_set(ctx.contour_set)
            ctx.contour_set = nil
            ctx.result = create_error_result(.BuildContours, "No contours created")
            return false
        }
    }
    finish_step(ctx)
    
    // Step 8: Build polygon mesh
    log.infof("PIPELINE DEBUG: Starting build polygon mesh")
    start_step(ctx, .BuildPolygonMesh)
    {
        ctx.polygon_mesh = rc_alloc_poly_mesh()
        if ctx.polygon_mesh == nil {
            // Free contour set on failure
            if ctx.contour_set != nil {
                rc_free_contour_set(ctx.contour_set)
                ctx.contour_set = nil
            }
            ctx.result = create_error_result(.BuildPolygonMesh, "Failed to allocate polygon mesh")
            return false
        }
        
        // Use parallel mesh building if enabled
        build_success := false
        // TEMPORARY: Disable parallel mesh building due to hanging issues
        if false && ctx.config.enable_parallel_mesh {
            build_success = rc_build_poly_mesh_parallel(ctx.contour_set, cfg.max_verts_per_poly, ctx.polygon_mesh, ctx.config.parallel_mesh_config)
        } else {
            build_success = rc_build_poly_mesh(ctx.contour_set, cfg.max_verts_per_poly, ctx.polygon_mesh)
        }
        
        if !build_success {
            // Free contour set on failure
            if ctx.contour_set != nil {
                rc_free_contour_set(ctx.contour_set)
                ctx.contour_set = nil
            }
            ctx.result = create_error_result(.BuildPolygonMesh, "Failed to build polygon mesh")
            return false
        }
        
        if ctx.polygon_mesh.npolys == 0 {
            // Free contour set on failure
            if ctx.contour_set != nil {
                rc_free_contour_set(ctx.contour_set)
                ctx.contour_set = nil
            }
            ctx.result = create_error_result(.BuildPolygonMesh, "No polygons created")
            return false
        }
        
        // Free contour set after successful polygon mesh building
        if ctx.contour_set != nil {
            rc_free_contour_set(ctx.contour_set)
            ctx.contour_set = nil
        }
    }
    finish_step(ctx)
    
    // Step 9: Build detail mesh
    start_step(ctx, .BuildDetailMesh)
    {
        ctx.detail_mesh = rc_alloc_poly_mesh_detail()
        if ctx.detail_mesh == nil {
            ctx.result = create_error_result(.BuildDetailMesh, "Failed to allocate detail mesh")
            return false
        }
        
        if !rc_build_poly_mesh_detail(ctx.polygon_mesh, ctx.compact_hf, 
                                      ctx.config.detail_sample_distance, 
                                      ctx.config.detail_sample_max_error, 
                                      ctx.detail_mesh) {
            ctx.result = create_error_result(.BuildDetailMesh, "Failed to build detail mesh")
            return false
        }
    }
    finish_step(ctx)
    
    ctx.result.success = true
    ctx.result.status = {.Success}
    return true
}

// Validate final mesh result
validate_final_result :: proc(ctx: ^Build_Context) {
    warnings := &ctx.result.validation_warnings
    
    if ctx.polygon_mesh != nil {
        pmesh := ctx.polygon_mesh
        
        // Check for reasonable polygon count
        if pmesh.npolys < 1 {
            append(warnings, "No polygons generated")
        } else if pmesh.npolys > 10000 {
            append(warnings, fmt.tprintf("Very high polygon count: %d", pmesh.npolys))
        }
        
        // Check for reasonable vertex count
        if pmesh.nverts < 3 {
            append(warnings, "Too few vertices generated")
        } else if pmesh.nverts > 50000 {
            append(warnings, fmt.tprintf("Very high vertex count: %d", pmesh.nverts))
        }
        
        // Validate polygon connectivity
        degenerate_polys := 0
        for i in 0..<pmesh.npolys {
            poly_base := int(i) * int(pmesh.nvp) * 2
            vert_count := 0
            
            for j in 0..<pmesh.nvp {
                if pmesh.polys[poly_base + int(j)] != RC_MESH_NULL_IDX {
                    vert_count += 1
                }
            }
            
            if vert_count < 3 {
                degenerate_polys += 1
            }
        }
        
        if degenerate_polys > 0 {
            append(warnings, fmt.tprintf("Found %d degenerate polygons", degenerate_polys))
        }
    }
    
    if ctx.detail_mesh != nil {
        dmesh := ctx.detail_mesh
        
        if dmesh.nverts == 0 {
            append(warnings, "No detail vertices generated")
        }
        
        if dmesh.ntris == 0 {
            append(warnings, "No detail triangles generated")
        }
    }
    
    ctx.result.validation_passed = len(warnings^) == 0
}

// ========================================
// STEP-BY-STEP BUILDER PATTERN
// ========================================

// Builder for step-by-step mesh generation
Navmesh_Builder :: struct {
    // Configuration
    config:          Enhanced_Config,
    geometry:        ^Geometry_Input,
    
    // Pipeline state
    current_step:    Pipeline_Step,
    completed_steps: bit_set[Pipeline_Step],
    
    // Intermediate results
    heightfield:     ^Rc_Heightfield,
    compact_hf:      ^Rc_Compact_Heightfield,
    contour_set:     ^Rc_Contour_Set,
    polygon_mesh:    ^Rc_Poly_Mesh,
    detail_mesh:     ^Rc_Poly_Mesh_Detail,
    
    // Status
    last_error:      string,
    build_successful: bool,
}

// Create a new builder
create_builder :: proc(geometry: ^Geometry_Input, config: Enhanced_Config) -> ^Navmesh_Builder {
    builder := new(Navmesh_Builder)
    builder.config = config
    builder.geometry = geometry
    builder.current_step = .Initialize
    
    // Validate inputs
    if valid, err := validate_geometry(geometry); !valid {
        builder.last_error = fmt.tprintf("Geometry validation failed: %s", err)
        return builder
    }
    
    if valid, err := validate_enhanced_config(&builder.config); !valid {
        builder.last_error = fmt.tprintf("Configuration validation failed: %s", err)
        return builder
    }
    
    // Auto-calculate bounds if needed
    if builder.config.base.bmin == builder.config.base.bmax {
        auto_calculate_bounds(geometry, &builder.config)
    }
    
    builder.completed_steps += {.Initialize}
    return builder
}

// Free builder resources
free_builder :: proc(builder: ^Navmesh_Builder) {
    if builder == nil do return
    
    if builder.heightfield != nil {
        rc_free_heightfield(builder.heightfield)
        builder.heightfield = nil
    }
    if builder.compact_hf != nil {
        rc_free_compact_heightfield(builder.compact_hf)
        builder.compact_hf = nil
    }
    if builder.contour_set != nil {
        rc_free_contour_set(builder.contour_set)
        builder.contour_set = nil
    }
    if builder.polygon_mesh != nil {
        rc_free_poly_mesh(builder.polygon_mesh)
        builder.polygon_mesh = nil
    }
    if builder.detail_mesh != nil {
        rc_free_poly_mesh_detail(builder.detail_mesh)
        builder.detail_mesh = nil
    }
    
    free(builder)
}

// Build heightfield step
builder_rasterize :: proc(builder: ^Navmesh_Builder) -> bool {
    if builder.last_error != "" do return false
    if .Rasterize in builder.completed_steps do return true
    
    cfg := &builder.config.base
    
    builder.heightfield = rc_alloc_heightfield()
    if builder.heightfield == nil {
        builder.last_error = "Failed to allocate heightfield"
        return false
    }
    
    if !rc_create_heightfield(builder.heightfield, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch) {
        builder.last_error = "Failed to create heightfield"
        return false
    }
    
    vert_count := i32(len(builder.geometry.vertices) / 3)
    tri_count := i32(len(builder.geometry.indices) / 3)
    
    if !rc_rasterize_triangles(builder.geometry.vertices, vert_count, 
                               builder.geometry.indices, builder.geometry.areas,
                               tri_count, builder.heightfield, cfg.walkable_climb) {
        builder.last_error = "Failed to rasterize triangles"
        return false
    }
    
    builder.completed_steps += {.Rasterize}
    builder.current_step = .Filter
    return true
}

// Filter spans step
builder_filter :: proc(builder: ^Navmesh_Builder) -> bool {
    if builder.last_error != "" do return false
    if .Filter in builder.completed_steps do return true
    if .Rasterize not_in builder.completed_steps {
        builder.last_error = "Must rasterize before filtering"
        return false
    }
    
    cfg := &builder.config.base
    
    rc_filter_low_hanging_walkable_obstacles(int(cfg.walkable_climb), builder.heightfield)
    rc_filter_ledge_spans(int(cfg.walkable_height), int(cfg.walkable_climb), builder.heightfield)
    rc_filter_walkable_low_height_spans(int(cfg.walkable_height), builder.heightfield)
    
    builder.completed_steps += {.Filter}
    builder.current_step = .BuildCompactHeightfield
    return true
}

// Build compact heightfield step
builder_build_compact_heightfield :: proc(builder: ^Navmesh_Builder) -> bool {
    if builder.last_error != "" do return false
    if .BuildCompactHeightfield in builder.completed_steps do return true
    if .Filter not_in builder.completed_steps {
        builder.last_error = "Must filter before building compact heightfield"
        return false
    }
    
    cfg := &builder.config.base
    
    builder.compact_hf = new(Rc_Compact_Heightfield)
    if !rc_build_compact_heightfield(cfg.walkable_height, cfg.walkable_climb, 
                                     builder.heightfield, builder.compact_hf) {
        builder.last_error = "Failed to build compact heightfield"
        return false
    }
    
    if builder.compact_hf.span_count == 0 {
        builder.last_error = "No walkable spans found"
        return false
    }
    
    builder.completed_steps += {.BuildCompactHeightfield}
    builder.current_step = .ErodeWalkableArea
    return true
}

// Erode walkable area step
builder_erode_walkable_area :: proc(builder: ^Navmesh_Builder) -> bool {
    if builder.last_error != "" do return false
    if .ErodeWalkableArea in builder.completed_steps do return true
    if .BuildCompactHeightfield not_in builder.completed_steps {
        builder.last_error = "Must build compact heightfield before eroding"
        return false
    }
    
    cfg := &builder.config.base
    
    if !rc_erode_walkable_area(cfg.walkable_radius, builder.compact_hf) {
        builder.last_error = "Failed to erode walkable area"
        return false
    }
    
    builder.completed_steps += {.ErodeWalkableArea}
    builder.current_step = .BuildDistanceField
    return true
}

// Build distance field step
builder_build_distance_field :: proc(builder: ^Navmesh_Builder) -> bool {
    if builder.last_error != "" do return false
    if .BuildDistanceField in builder.completed_steps do return true
    if .ErodeWalkableArea not_in builder.completed_steps {
        builder.last_error = "Must erode walkable area before building distance field"
        return false
    }
    
    if !rc_build_distance_field(builder.compact_hf) {
        builder.last_error = "Failed to build distance field"
        return false
    }
    
    builder.completed_steps += {.BuildDistanceField}
    builder.current_step = .BuildRegions
    return true
}

// Build regions step
builder_build_regions :: proc(builder: ^Navmesh_Builder) -> bool {
    if builder.last_error != "" do return false
    if .BuildRegions in builder.completed_steps do return true
    if .BuildDistanceField not_in builder.completed_steps {
        builder.last_error = "Must build distance field before building regions"
        return false
    }
    
    cfg := &builder.config.base
    
    if !rc_build_regions(builder.compact_hf, cfg.border_size, cfg.min_region_area, cfg.merge_region_area) {
        builder.last_error = "Failed to build regions"
        return false
    }
    
    if builder.compact_hf.max_regions == 0 {
        builder.last_error = "No regions created"
        return false
    }
    
    builder.completed_steps += {.BuildRegions}
    builder.current_step = .BuildContours
    return true
}

// Build contours step
builder_build_contours :: proc(builder: ^Navmesh_Builder) -> bool {
    if builder.last_error != "" do return false
    if .BuildContours in builder.completed_steps do return true
    if .BuildRegions not_in builder.completed_steps {
        builder.last_error = "Must build regions before building contours"
        return false
    }
    
    cfg := &builder.config.base
    
    builder.contour_set = rc_alloc_contour_set()
    if builder.contour_set == nil {
        builder.last_error = "Failed to allocate contour set"
        return false
    }
    
    if !rc_build_contours(builder.compact_hf, cfg.max_simplification_error, cfg.max_edge_len, builder.contour_set) {
        rc_free_contour_set(builder.contour_set)
        builder.contour_set = nil
        builder.last_error = "Failed to build contours"
        return false
    }
    
    if builder.contour_set.nconts == 0 {
        rc_free_contour_set(builder.contour_set)
        builder.contour_set = nil
        builder.last_error = "No contours created"
        return false
    }
    
    builder.completed_steps += {.BuildContours}
    builder.current_step = .BuildPolygonMesh
    return true
}

// Build polygon mesh step
builder_build_polygon_mesh :: proc(builder: ^Navmesh_Builder) -> bool {
    if builder.last_error != "" do return false
    if .BuildPolygonMesh in builder.completed_steps do return true
    if .BuildContours not_in builder.completed_steps {
        builder.last_error = "Must build contours before building polygon mesh"
        return false
    }
    
    cfg := &builder.config.base
    
    builder.polygon_mesh = rc_alloc_poly_mesh()
    if builder.polygon_mesh == nil {
        builder.last_error = "Failed to allocate polygon mesh"
        return false
    }
    
    // Use parallel mesh building if enabled
    build_success := false
    // TEMPORARY: Disable parallel mesh building due to hanging issues
    if false && builder.config.enable_parallel_mesh {
        build_success = rc_build_poly_mesh_parallel(builder.contour_set, cfg.max_verts_per_poly, builder.polygon_mesh, builder.config.parallel_mesh_config)
    } else {
        build_success = rc_build_poly_mesh(builder.contour_set, cfg.max_verts_per_poly, builder.polygon_mesh)
    }
    
    if !build_success {
        builder.last_error = "Failed to build polygon mesh"
        return false
    }
    
    if builder.polygon_mesh.npolys == 0 {
        builder.last_error = "No polygons created"
        return false
    }
    
    // Free contour set since it's no longer needed after polygon mesh is built
    if builder.contour_set != nil {
        log.infof("DEBUG BUILDER: About to free contour set")
        rc_free_contour_set(builder.contour_set)
        builder.contour_set = nil
        log.infof("DEBUG BUILDER: Contour set freed and set to nil")
    } else {
        log.infof("DEBUG BUILDER: Contour set is already nil, not freeing")
    }
    
    builder.completed_steps += {.BuildPolygonMesh}
    builder.current_step = .BuildDetailMesh
    return true
}

// Build detail mesh step
builder_build_detail_mesh :: proc(builder: ^Navmesh_Builder) -> bool {
    if builder.last_error != "" do return false
    if .BuildDetailMesh in builder.completed_steps do return true
    if .BuildPolygonMesh not_in builder.completed_steps {
        builder.last_error = "Must build polygon mesh before building detail mesh"
        return false
    }
    
    builder.detail_mesh = rc_alloc_poly_mesh_detail()
    if builder.detail_mesh == nil {
        builder.last_error = "Failed to allocate detail mesh"
        return false
    }
    
    if !rc_build_poly_mesh_detail(builder.polygon_mesh, builder.compact_hf,
                                  builder.config.detail_sample_distance,
                                  builder.config.detail_sample_max_error,
                                  builder.detail_mesh) {
        builder.last_error = "Failed to build detail mesh"
        return false
    }
    
    builder.completed_steps += {.BuildDetailMesh}
    builder.current_step = .Finalize
    builder.build_successful = true
    return true
}

// Build all remaining steps
builder_build_all :: proc(builder: ^Navmesh_Builder) -> bool {
    steps := []proc(^Navmesh_Builder) -> bool{
        builder_rasterize,
        builder_filter,
        builder_build_compact_heightfield,
        builder_erode_walkable_area,
        builder_build_distance_field,
        builder_build_regions,
        builder_build_contours,
        builder_build_polygon_mesh,
        builder_build_detail_mesh,
    }
    
    for step in steps {
        if !step(builder) {
            return false
        }
    }
    
    return true
}

// Get final result from builder
builder_get_result :: proc(builder: ^Navmesh_Builder) -> (^Rc_Poly_Mesh, ^Rc_Poly_Mesh_Detail, bool) {
    if !builder.build_successful {
        return nil, nil, false
    }
    
    // Transfer ownership to caller
    pmesh := builder.polygon_mesh
    dmesh := builder.detail_mesh
    builder.polygon_mesh = nil
    builder.detail_mesh = nil
    
    return pmesh, dmesh, true
}

// ========================================
// VALIDATION AND DEBUGGING UTILITIES
// ========================================

// Validation report for diagnosing issues
Validation_Report :: struct {
    is_valid:            bool,
    errors:              [dynamic]string,
    warnings:            [dynamic]string,
    performance_notes:   [dynamic]string,
    
    // Statistics
    vertex_count:        i32,
    polygon_count:       i32,
    triangle_count:      i32,
    
    // Quality metrics
    min_polygon_area:    f32,
    max_polygon_area:    f32,
    avg_polygon_area:    f32,
    degenerate_count:    i32,
    
    // Memory usage
    total_memory_bytes:  int,
}

// Validate navigation mesh quality
validate_navmesh :: proc(pmesh: ^Rc_Poly_Mesh, dmesh: ^Rc_Poly_Mesh_Detail) -> Validation_Report {
    report := Validation_Report{
        is_valid = true,
        errors = make([dynamic]string),
        warnings = make([dynamic]string),
        performance_notes = make([dynamic]string),
    }
    
    if pmesh == nil {
        append(&report.errors, "Polygon mesh is null")
        report.is_valid = false
        return report
    }
    
    report.vertex_count = pmesh.nverts
    report.polygon_count = pmesh.npolys
    
    // Basic validation
    if pmesh.nverts == 0 {
        append(&report.errors, "No vertices in polygon mesh")
        report.is_valid = false
    }
    
    if pmesh.npolys == 0 {
        append(&report.errors, "No polygons in polygon mesh")
        report.is_valid = false
    }
    
    if pmesh.nvp < 3 {
        append(&report.errors, fmt.tprintf("Invalid vertices per polygon: %d", pmesh.nvp))
        report.is_valid = false
    }
    
    // Validate polygon structure
    valid_polygons := 0
    total_area: f32 = 0
    report.min_polygon_area = 1e9
    report.max_polygon_area = 0
    
    for i in 0..<pmesh.npolys {
        poly_base := int(i) * int(pmesh.nvp) * 2
        
        // Count valid vertices in polygon
        vert_count := 0
        verts: [8]i32  // Max vertices per polygon
        
        for j in 0..<pmesh.nvp {
            idx := pmesh.polys[poly_base + int(j)]
            if idx != RC_MESH_NULL_IDX {
                if idx >= 0 && int(idx) < len(pmesh.verts)/3 {
                    verts[vert_count] = i32(idx)
                    vert_count += 1
                } else {
                    append(&report.errors, fmt.tprintf("Polygon %d has invalid vertex index %d", i, idx))
                    report.is_valid = false
                }
            }
        }
        
        if vert_count < 3 {
            report.degenerate_count += 1
            continue
        }
        
        // Calculate polygon area (2D projection)
        area := calculate_polygon_area_2d(pmesh.verts, verts[:vert_count])
        if area > 0 {
            valid_polygons += 1
            total_area += area
            report.min_polygon_area = min(report.min_polygon_area, area)
            report.max_polygon_area = max(report.max_polygon_area, area)
        } else {
            append(&report.warnings, fmt.tprintf("Polygon %d has zero or negative area", i))
        }
    }
    
    if valid_polygons > 0 {
        report.avg_polygon_area = total_area / f32(valid_polygons)
    }
    
    if report.degenerate_count > 0 {
        append(&report.warnings, fmt.tprintf("Found %d degenerate polygons", report.degenerate_count))
    }
    
    // Validate detail mesh if provided
    if dmesh != nil {
        report.triangle_count = dmesh.ntris
        
        if dmesh.nverts == 0 {
            append(&report.warnings, "Detail mesh has no vertices")
        }
        
        if dmesh.ntris == 0 {
            append(&report.warnings, "Detail mesh has no triangles")
        }
        
        // Validate triangle indices
        for i in 0..<dmesh.ntris {
            tri_base := int(i) * 4
            for j in 0..<3 {
                idx := dmesh.tris[tri_base + j]
                if idx >= u8(dmesh.nverts) {
                    append(&report.errors, fmt.tprintf("Detail triangle %d has invalid vertex index %d", i, idx))
                    report.is_valid = false
                }
            }
        }
    }
    
    // Performance notes
    if pmesh.npolys > 5000 {
        append(&report.performance_notes, "High polygon count may impact pathfinding performance")
    }
    
    if pmesh.nverts > 20000 {
        append(&report.performance_notes, "High vertex count may impact memory usage")
    }
    
    // Calculate memory usage
    report.total_memory_bytes = int(pmesh.nverts) * 3 * size_of(u16)  // Vertices
    report.total_memory_bytes += int(pmesh.npolys) * int(pmesh.nvp) * 2 * size_of(u16)  // Polygons
    report.total_memory_bytes += int(pmesh.npolys) * size_of(u16)  // Regions
    report.total_memory_bytes += int(pmesh.npolys) * size_of(u16)  // Flags
    report.total_memory_bytes += int(pmesh.npolys) * size_of(u8)   // Areas
    
    if dmesh != nil {
        report.total_memory_bytes += int(dmesh.nverts) * 3 * size_of(f32)  // Detail vertices
        report.total_memory_bytes += int(dmesh.ntris) * 4 * size_of(u8)    // Detail triangles
        report.total_memory_bytes += int(dmesh.nmeshes) * 4 * size_of(u32) // Mesh info
    }
    
    return report
}

// Print validation report
print_validation_report :: proc(report: ^Validation_Report) {
    log.infof("=== Navigation Mesh Validation Report ===")
    log.infof("Valid: %v", report.is_valid)
    log.infof("Vertices: %d, Polygons: %d, Triangles: %d", 
              report.vertex_count, report.polygon_count, report.triangle_count)
    log.infof("Memory usage: %.2f KB", f32(report.total_memory_bytes) / 1024.0)
    
    if report.polygon_count > 0 {
        log.infof("Polygon area - Min: %.2f, Max: %.2f, Avg: %.2f", 
                  report.min_polygon_area, report.max_polygon_area, report.avg_polygon_area)
    }
    
    if report.degenerate_count > 0 {
        log.infof("Degenerate polygons: %d", report.degenerate_count)
    }
    
    for error in report.errors {
        log.errorf("ERROR: %s", error)
    }
    
    for warning in report.warnings {
        log.warnf("WARNING: %s", warning)
    }
    
    for note in report.performance_notes {
        log.infof("PERFORMANCE: %s", note)
    }
}

// Free validation report
free_validation_report :: proc(report: ^Validation_Report) {
    delete(report.errors)
    delete(report.warnings)
    delete(report.performance_notes)
}

// Calculate 2D area of polygon (XZ plane)
calculate_polygon_area_2d :: proc(verts: []u16, indices: []i32) -> f32 {
    if len(indices) < 3 do return 0
    
    area: f32 = 0
    j := len(indices) - 1
    
    for i in 0..<len(indices) {
        vi := int(indices[i]) * 3
        vj := int(indices[j]) * 3
        
        if vi + 2 < len(verts) && vj + 2 < len(verts) {
            area += f32(verts[vi+0]) * f32(verts[vj+2]) - f32(verts[vj+0]) * f32(verts[vi+2])
        }
        j = i
    }
    
    // Return absolute value to handle both clockwise and counter-clockwise polygons
    return abs(area) * 0.5
}

// ========================================
// CONVENIENCE FUNCTIONS
// ========================================

// Quick build function with minimal configuration
quick_build_navmesh :: proc(vertices: []f32, indices: []i32, cell_size: f32 = 0.3) -> (^Rc_Poly_Mesh, ^Rc_Poly_Mesh_Detail, bool) {
    // Create areas array (all walkable)
    tri_count := len(indices) / 3
    areas := make([]u8, tri_count)
    defer delete(areas)
    
    for i in 0..<tri_count {
        areas[i] = RC_WALKABLE_AREA
    }
    
    // Create geometry input
    geometry, ok := create_geometry_input(vertices, indices, areas)
    if !ok {
        log.error("Failed to create geometry input")
        return nil, nil, false
    }
    
    // Create balanced configuration
    config := create_config_from_preset(.Balanced)
    config.base.cs = cell_size
    config.base.ch = cell_size * 0.5
    
    // Build navigation mesh
    result := build_navmesh(&geometry, config)
    if !result.success {
        log.errorf("Failed to build navigation mesh: %s", result.error_message)
        free_build_result(&result) // Clean up failed result
        return nil, nil, false
    }
    
    return result.polygon_mesh, result.detail_mesh, true
}

// Build with custom areas
build_navmesh_with_areas :: proc(vertices: []f32, indices: []i32, areas: []u8, preset: Config_Preset = .Balanced) -> Build_Result {
    geometry, ok := create_geometry_input(vertices, indices, areas)
    if !ok {
        return create_error_result(.Initialize, "Failed to create geometry input")
    }
    
    config := create_config_from_preset(preset)
    return build_navmesh(&geometry, config)
}

// Estimate build time based on geometry complexity
estimate_build_time :: proc(vert_count, tri_count: i32, config: ^Enhanced_Config) -> f64 {
    // Simple heuristic based on geometry complexity and configuration
    complexity_factor := f64(tri_count) * f64(config.base.width * config.base.height) / 1000000.0
    
    base_time_ms: f64
    switch config.preset {
    case .Fast:
        base_time_ms = complexity_factor * 10.0
    case .Balanced:
        base_time_ms = complexity_factor * 25.0
    case .High_Quality:
        base_time_ms = complexity_factor * 60.0
    case .Custom:
        base_time_ms = complexity_factor * 30.0
    }
    
    // Add overhead for small meshes
    if tri_count < 100 {
        base_time_ms += 50.0
    }
    
    return base_time_ms
}

// ========================================
// EXPORT UTILITIES
// ========================================

// Export mesh to simple format for debugging
export_mesh_to_obj :: proc(pmesh: ^Rc_Poly_Mesh, filename: string) -> bool {
    // This is a placeholder - in a real implementation you'd write an OBJ file
    log.infof("Would export mesh with %d vertices and %d polygons to %s", 
              pmesh.nverts, pmesh.npolys, filename)
    
    // TODO: Implement actual OBJ export
    return true
}

// Get mesh statistics
get_mesh_stats :: proc(pmesh: ^Rc_Poly_Mesh, dmesh: ^Rc_Poly_Mesh_Detail) -> (stats: map[string]int) {
    stats = make(map[string]int)
    
    if pmesh != nil {
        stats["polygon_vertices"] = int(pmesh.nverts)
        stats["polygons"] = int(pmesh.npolys)
        stats["max_verts_per_poly"] = int(pmesh.nvp)
    }
    
    if dmesh != nil {
        stats["detail_vertices"] = int(dmesh.nverts)
        stats["detail_triangles"] = int(dmesh.ntris)
        stats["detail_meshes"] = int(dmesh.nmeshes)
    }
    
    return stats
}