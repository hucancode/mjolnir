package navigation_recast

import "core:log"
import "core:fmt"
import "core:time"

// ========================================
// RECAST-SPECIFIC ERROR HANDLING
// ========================================

// Enhanced build result with standardized error handling
Enhanced_Build_Result :: struct {
    // Legacy compatibility
    success:         bool,
    error_message:   string,
    status:          Status,
    failed_step:     Pipeline_Step,

    // Enhanced error information
    error:           Nav_Error,
    warnings:        [dynamic]Nav_Error,

    // Generated data (same as before)
    polygon_mesh:    ^Rc_Poly_Mesh,
    detail_mesh:     ^Rc_Poly_Mesh_Detail,

    // Enhanced validation and metrics
    validation_warnings: [dynamic]string,
    build_metrics:   Build_Metrics,
}

// Build metrics for performance analysis
Build_Metrics :: struct {
    total_time_ms:      f64,
    step_times_ms:      map[Pipeline_Step]f64,
    memory_peak_mb:     f64,
    triangles_processed: i32,
    vertices_generated:  i32,
    polygons_generated:  i32,
}

// Recast-specific error categories
Recast_Error_Category :: enum u8 {
    Rasterization_Failed = 100,    // Start at 100 to avoid conflicts with core categories
    Filtering_Failed,
    Region_Building_Failed,
    Contour_Building_Failed,
    Mesh_Generation_Failed,
    Detail_Mesh_Failed,
    Triangulation_Failed,
    Geometry_Invalid,
    Configuration_Invalid,
}

// ========================================
// ERROR CREATION HELPERS
// ========================================

// Create Recast-specific error
recast_error :: proc($T: typeid, category: Recast_Error_Category, message: string,
                    ctx: string = "", code: u32 = 0) -> Nav_Result(T) {
    return Nav_Result(T){
        value = {},
        error = Nav_Error{
            category = Nav_Error_Category.Algorithm_Failed,
            code = u32(category),
            message = fmt.tprintf("[Recast:%v] %s", category, message),
            ctx = ctx,
        },
        success = false,
    }
}

// Create error with pipeline step context
recast_step_error :: proc($T: typeid, step: Pipeline_Step, category: Recast_Error_Category,
                         message: string, loc := #caller_location) -> Nav_Result(T) {
    ctx := fmt.tprintf("%s (step: %v)", loc.procedure, step)
    return recast_error(T, category, message, ctx)
}

// ========================================
// BUILD RESULT HELPERS
// ========================================

// Create enhanced success result
create_enhanced_success_result :: proc(pmesh: ^Rc_Poly_Mesh, dmesh: ^Rc_Poly_Mesh_Detail,
                                      metrics: Build_Metrics = {}) -> Enhanced_Build_Result {
    return Enhanced_Build_Result{
        success = true,
        error_message = "",
        status = {.Success},
        failed_step = .Initialize,
        error = {},
        warnings = make([dynamic]Nav_Error),
        polygon_mesh = pmesh,
        detail_mesh = dmesh,
        validation_warnings = make([dynamic]string),
        build_metrics = metrics,
    }
}

// Create enhanced error result
create_enhanced_error_result :: proc(step: Pipeline_Step, category: Recast_Error_Category,
                                   message: string, status: Status = {}) -> Enhanced_Build_Result {
    error := Nav_Error{
        category = Nav_Error_Category.Algorithm_Failed,
        code = u32(category),
        message = fmt.tprintf("[Recast:%v] %s", category, message),
        ctx = fmt.tprintf("Pipeline step: %v", step),
    }

    return Enhanced_Build_Result{
        success = false,
        error_message = message,
        status = status,
        failed_step = step,
        error = error,
        warnings = make([dynamic]Nav_Error),
        polygon_mesh = nil,
        detail_mesh = nil,
        validation_warnings = make([dynamic]string),
        build_metrics = {},
    }
}

// Convert legacy Build_Result to Enhanced_Build_Result
convert_legacy_result :: proc(legacy: Build_Result) -> Enhanced_Build_Result {
    if legacy.success {
        return create_enhanced_success_result(legacy.polygon_mesh, legacy.detail_mesh)
    } else {
        return create_enhanced_error_result(legacy.failed_step, .Mesh_Generation_Failed,
                                          legacy.error_message, legacy.status)
    }
}

// Convert Enhanced_Build_Result to legacy Build_Result (for compatibility)
convert_to_legacy :: proc(enhanced: Enhanced_Build_Result) -> Build_Result {
    return Build_Result{
        success = enhanced.success,
        error_message = enhanced.error_message,
        status = enhanced.status,
        failed_step = enhanced.failed_step,
        polygon_mesh = enhanced.polygon_mesh,
        detail_mesh = enhanced.detail_mesh,
        validation_warnings = enhanced.validation_warnings,
    }
}

// Free enhanced build result
free_enhanced_build_result :: proc(result: ^Enhanced_Build_Result) {
    if result.polygon_mesh != nil {
        rc_free_poly_mesh(result.polygon_mesh)
        result.polygon_mesh = nil
    }
    if result.detail_mesh != nil {
        rc_free_poly_mesh_detail(result.detail_mesh)
        result.detail_mesh = nil
    }
    delete(result.warnings)
    delete(result.validation_warnings)
    delete(result.build_metrics.step_times_ms)
}

// ========================================
// VALIDATION HELPERS
// ========================================

// Validate Enhanced_Config with detailed error reporting
validate_enhanced_config_detailed :: proc(cfg: ^Enhanced_Config) -> Nav_Result(bool) {
    // Use error collector to gather all validation errors
    collector := Nav_Error_Collector{}
    nav_error_collector_init(&collector, 10) // Max 10 errors
    defer nav_error_collector_destroy(&collector)

    // Validate base configuration
    base_result := validate_config_detailed(&cfg.base)
    if nav_is_error(base_result) {
        nav_error_collector_add(&collector, base_result.error)
    }

    // Validate detail mesh parameters
    if cfg.detail_sample_distance <= 0 {
        error := Nav_Error{
            category = Nav_Error_Category.Invalid_Parameter,
            message = "Detail sample distance must be positive",
            ctx = "Enhanced_Config.detail_sample_distance",
        }
        nav_error_collector_add(&collector, error)
    }

    if cfg.detail_sample_max_error <= 0 {
        error := Nav_Error{
            category = Nav_Error_Category.Invalid_Parameter,
            message = "Detail sample max error must be positive",
            ctx = "Enhanced_Config.detail_sample_max_error",
        }
        nav_error_collector_add(&collector, error)
    }

    // Validate parameter ranges
    if cfg.base.cs > 2.0 {
        error := Nav_Error{
            category = Nav_Error_Category.Invalid_Configuration,
            message = fmt.tprintf("Cell size (%.2f) too large (max 2.0), will result in poor quality", cfg.base.cs),
            ctx = "Enhanced_Config.base.cs",
        }
        nav_error_collector_add(&collector, error)
    }

    if cfg.base.cs < 0.05 {
        error := Nav_Error{
            category = Nav_Error_Category.Invalid_Configuration,
            message = fmt.tprintf("Cell size (%.2f) too small (min 0.05), will be very slow", cfg.base.cs),
            ctx = "Enhanced_Config.base.cs",
        }
        nav_error_collector_add(&collector, error)
    }

    // Validate parallel mesh configuration
    if cfg.enable_parallel_mesh {
        if cfg.parallel_mesh_config.chunk_size <= 0 {
            error := Nav_Error{
                category = Nav_Error_Category.Invalid_Parameter,
                message = "Parallel mesh chunk size must be positive",
                ctx = "Enhanced_Config.parallel_mesh_config.chunk_size",
            }
            nav_error_collector_add(&collector, error)
        }

        if cfg.parallel_mesh_config.enable_vertex_weld && cfg.parallel_mesh_config.weld_tolerance < 0 {
            error := Nav_Error{
                category = Nav_Error_Category.Invalid_Parameter,
                message = "Vertex weld tolerance cannot be negative",
                ctx = "Enhanced_Config.parallel_mesh_config.weld_tolerance",
            }
            nav_error_collector_add(&collector, error)
        }
    }

    return nav_error_collector_result(&collector)
}

// Validate base Config with detailed error reporting
validate_config_detailed :: proc(cfg: ^Config) -> Nav_Result(bool) {
    collector := Nav_Error_Collector{}
    nav_error_collector_init(&collector, 10)
    defer nav_error_collector_destroy(&collector)

    // Check required positive values
    positive_checks := []struct{
        value: f32,
        name:  string,
    }{
        {cfg.cs, "cs"},
        {cfg.ch, "ch"},
        {cfg.walkable_slope_angle, "walkable_slope_angle"},
        {cfg.max_simplification_error, "max_simplification_error"},
    }

    for check in positive_checks {
        if check.value <= 0 {
            error := Nav_Error{
                category = Nav_Error_Category.Invalid_Parameter,
                message = fmt.tprintf("Parameter '%s' (%.3f) must be positive", check.name, check.value),
                ctx = "Config validation",
            }
            nav_error_collector_add(&collector, error)
        }
    }

    // Check integer ranges
    int_checks := []struct{
        value: i32,
        min:   i32,
        max:   i32,
        name:  string,
    }{
        {cfg.walkable_height, 1, 255, "walkable_height"},
        {cfg.walkable_climb, 0, 255, "walkable_climb"},
        {cfg.walkable_radius, 0, 255, "walkable_radius"},
        {cfg.max_verts_per_poly, 3, 12, "max_verts_per_poly"},
    }

    for check in int_checks {
        if check.value < check.min || check.value > check.max {
            error := Nav_Error{
                category = Nav_Error_Category.Invalid_Parameter,
                message = fmt.tprintf("Parameter '%s' (%d) must be in range [%d, %d]",
                                    check.name, check.value, check.min, check.max),
                ctx = "Config validation",
            }
            nav_error_collector_add(&collector, error)
        }
    }

    // Check bounds consistency
    for i in 0..<3 {
        if cfg.bmin[i] >= cfg.bmax[i] {
            error := Nav_Error{
                category = Nav_Error_Category.Invalid_Parameter,
                message = fmt.tprintf("bmin[%d] (%.3f) must be less than bmax[%d] (%.3f)",
                                    i, cfg.bmin[i], i, cfg.bmax[i]),
                ctx = "Config bounds validation",
            }
            nav_error_collector_add(&collector, error)
        }
    }

    return nav_error_collector_result(&collector)
}

// ========================================
// GEOMETRY VALIDATION
// ========================================

// Validate geometry input with detailed error reporting
validate_geometry_detailed :: proc(geometry: ^Geometry_Input) -> Nav_Result(bool) {
    collector := Nav_Error_Collector{}
    nav_error_collector_init(&collector, 5)
    defer nav_error_collector_destroy(&collector)

    // Basic null checks
    if geometry == nil {
        error := Nav_Error{
            category = Nav_Error_Category.Invalid_Parameter,
            message = "Geometry input cannot be nil",
            ctx = "validate_geometry_detailed",
        }
        nav_error_collector_add(&collector, error)
        return nav_error_collector_result(&collector)
    }

    // Check vertex data
    if len(geometry.vertices) == 0 {
        error := Nav_Error{
            category = Nav_Error_Category.Invalid_Geometry,
            message = "Geometry must have at least one vertex",
            ctx = "Geometry_Input.vertices",
        }
        nav_error_collector_add(&collector, error)
    }

    if len(geometry.vertices) % 3 != 0 {
        error := Nav_Error{
            category = Nav_Error_Category.Invalid_Geometry,
            message = fmt.tprintf("Vertex array length (%d) must be multiple of 3", len(geometry.vertices)),
            ctx = "Geometry_Input.vertices",
        }
        nav_error_collector_add(&collector, error)
    }

    // Check triangle data
    if len(geometry.indices) == 0 {
        error := Nav_Error{
            category = Nav_Error_Category.Invalid_Geometry,
            message = "Geometry must have at least one triangle",
            ctx = "Geometry_Input.indices",
        }
        nav_error_collector_add(&collector, error)
    }

    if len(geometry.indices) % 3 != 0 {
        error := Nav_Error{
            category = Nav_Error_Category.Invalid_Geometry,
            message = fmt.tprintf("Triangle array length (%d) must be multiple of 3", len(geometry.indices)),
            ctx = "Geometry_Input.indices",
        }
        nav_error_collector_add(&collector, error)
    }

    // Check triangle indices are valid
    vertex_count := i32(len(geometry.vertices) / 3)
    for i := 0; i < len(geometry.indices); i += 1 {
        idx := geometry.indices[i]
        if idx < 0 || idx >= vertex_count {
            error := Nav_Error{
                category = Nav_Error_Category.Invalid_Geometry,
                message = fmt.tprintf("Triangle index %d is out of range [0, %d)", idx, vertex_count),
                ctx = fmt.tprintf("Geometry_Input.indices[%d]", i),
            }
            nav_error_collector_add(&collector, error)
            break // Don't spam with too many index errors
        }
    }

    return nav_error_collector_result(&collector)
}

// ========================================
// MIGRATION UTILITIES
// ========================================

// Adapter for legacy boolean validation functions
legacy_bool_to_result :: proc(success: bool, error_msg: string, ctx: string = "") -> Nav_Result(bool) {
    if success {
        return nav_ok(bool, true)
    }
    return nav_error(bool, Nav_Error_Category.Algorithm_Failed, error_msg, ctx)
}

// Log errors with Recast-specific formatting
log_recast_error :: proc(error: Nav_Error, level: log.Level = .Error) {
    if error.category == Nav_Error_Category.None do return

    error_str := nav_error_string(error)

    // Add Recast prefix for better log filtering
    prefixed_str := fmt.tprintf("[RECAST] %s", error_str)

    switch level {
    case .Debug:
        log.debug(prefixed_str)
    case .Info:
        log.info(prefixed_str)
    case .Warning:
        log.warn(prefixed_str)
    case .Error:
        log.error(prefixed_str)
    case .Fatal:
        log.fatal(prefixed_str)
    }
}

// Log build result errors
log_build_result :: proc(result: Enhanced_Build_Result, level: log.Level = .Error) {
    if !result.success {
        log_recast_error(result.error, level)
    }

    // Also log warnings
    for warning in result.warnings {
        log_recast_error(warning, .Warning)
    }
}
