package navigation_recast

import "core:log"
import "core:fmt"
import "core:slice"
import "core:math"
import "core:math/linalg"

// Inject element at specific index in dynamic array
inject_at :: proc(arr: ^[dynamic]$T, index: int, value: T) {
    resize(arr, len(arr) + 1)  // Expand slice
    copy(arr[index+1:], arr[index:len(arr)-1])  // Shift elements right
    arr[index] = value  // Insert new value
}

// Get direction offsets for 4-connected grid
get_dir_offset_x :: proc "contextless" (dir: int) -> i32 {
    offset := [4]i32{-1, 0, 1, 0}
    return offset[dir & 0x03]
}

get_dir_offset_y :: proc "contextless" (dir: int) -> i32 {
    offset := [4]i32{0, 1, 0, -1}
    return offset[dir & 0x03]
}

// ========================================
// STANDARDIZED ERROR HANDLING SYSTEM
// ========================================

// Navigation error categories for structured error handling
Nav_Error_Category :: enum u8 {
    None = 0,

    // Input validation errors
    Invalid_Parameter,
    Invalid_Geometry,
    Invalid_Configuration,

    // Resource errors
    Out_Of_Memory,
    Buffer_Too_Small,
    Resource_Exhausted,

    // Algorithm errors
    Algorithm_Failed,
    Convergence_Failed,
    Numerical_Instability,

    // I/O errors
    File_Not_Found,
    File_Corrupted,
    Serialization_Failed,

    // System errors
    Thread_Error,
    Timeout,
    Internal_Error,
}

// Navigation error with detailed context
Nav_Error :: struct {
    category:    Nav_Error_Category,
    code:        u32,                // Specific error code within category
    message:     string,             // Human-readable error message
    ctx:         string,             // Additional context (function name, file, etc.)
    inner_error: ^Nav_Error,         // Nested error for error chains
}

// Result type for operations that can fail
Nav_Result :: struct($T: typeid) {
    value:   T,
    error:   Nav_Error,
    success: bool,
}

// Specialized result types for common cases
Nav_Bool_Result :: Nav_Result(bool)
Nav_Status_Result :: Nav_Result(Status)
Nav_String_Result :: Nav_Result(string)

// ========================================
// ERROR CREATION HELPERS
// ========================================

// Create a successful result
nav_ok :: proc($T: typeid, value: T) -> Nav_Result(T) {
    return Nav_Result(T){
        value = value,
        error = {},
        success = true,
    }
}

// Create a simple success result for bool
nav_success :: proc() -> Nav_Bool_Result {
    return nav_ok(bool, true)
}

// Create an error result
nav_error :: proc($T: typeid, category: Nav_Error_Category, message: string,
                 ctx: string = "", code: u32 = 0) -> Nav_Result(T) {
    return Nav_Result(T){
        value = {},
        error = Nav_Error{
            category = category,
            code = code,
            message = message,
            ctx = ctx,
        },
        success = false,
    }
}

// Create error with context automatically captured
nav_error_here :: proc($T: typeid, category: Nav_Error_Category, message: string,
                      code: u32 = 0, loc := #caller_location) -> Nav_Result(T) {
    ctx := fmt.tprintf("%s:%d", loc.procedure, loc.line)
    return nav_error(T, category, message, ctx, code)
}

// Chain errors for error propagation
nav_error_chain :: proc($T: typeid, category: Nav_Error_Category, message: string,
                       inner: Nav_Error, ctx: string = "", code: u32 = 0) -> Nav_Result(T) {
    inner_copy := new(Nav_Error)
    inner_copy^ = inner

    return Nav_Result(T){
        value = {},
        error = Nav_Error{
            category = category,
            code = code,
            message = message,
            ctx = ctx,
            inner_error = inner_copy,
        },
        success = false,
    }
}

// ========================================
// VALIDATION HELPERS
// ========================================

// Check if result is successful
nav_is_ok :: proc(result: Nav_Result($T)) -> bool {
    return result.success
}

// Check if result is an error
nav_is_error :: proc(result: Nav_Result($T)) -> bool {
    return !result.success
}

// Get value from result (use with nav_is_ok check)
nav_unwrap :: proc(result: Nav_Result($T)) -> T {
    assert(result.success, "Attempted to unwrap error result")
    return result.value
}

// Get value with default fallback
nav_unwrap_or :: proc(result: Nav_Result($T), default_value: T) -> T {
    if result.success {
        return result.value
    }
    return default_value
}

// Propagate error in procedure chain
nav_try :: proc(result: Nav_Result($T), loc := #caller_location) -> T {
    if !result.success {
        // Log error at the location where nav_try was called
        log.errorf("[%s:%d] Navigation error: %s", loc.procedure, loc.line, nav_error_string(result.error))
        // In a more sophisticated system, this could use a custom panic or error propagation
        assert(false, "Error propagation")
    }
    return result.value
}

// ========================================
// ERROR CONVERSION AND COMPATIBILITY
// ========================================

// Convert legacy boolean result to Nav_Result
nav_from_bool :: proc(success: bool, error_message: string = "Operation failed") -> Nav_Bool_Result {
    if success {
        return nav_success()
    }
    return nav_error(bool, .Algorithm_Failed, error_message)
}

// Convert (bool, string) pattern to Nav_Result
nav_from_validation :: proc(success: bool, error_message: string) -> Nav_Bool_Result {
    if success {
        return nav_success()
    }
    return nav_error(bool, .Invalid_Parameter, error_message)
}

// Convert Status to Nav_Result
nav_from_status :: proc(status: Status) -> Nav_Status_Result {
    if status_succeeded(status) {
        return nav_ok(Status, status)
    }

    // Map status flags to error categories
    category := Nav_Error_Category.Algorithm_Failed
    message := "Unknown error"

    if .Invalid_Param in status {
        category = .Invalid_Parameter
        message = "Invalid parameter"
    } else if .Out_Of_Memory in status {
        category = .Out_Of_Memory
        message = "Out of memory"
    } else if .Buffer_Too_Small in status {
        category = .Buffer_Too_Small
        message = "Buffer too small"
    } else if .Out_Of_Nodes in status {
        category = .Resource_Exhausted
        message = "Out of pathfinding nodes"
    } else if .Wrong_Magic in status {
        category = .File_Corrupted
        message = "Invalid file format (wrong magic number)"
    } else if .Wrong_Version in status {
        category = .File_Corrupted
        message = "Unsupported file version"
    }

    return nav_error(Status, category, message)
}

// Convert Nav_Result back to Status (for legacy compatibility)
nav_to_status :: proc(result: Nav_Status_Result) -> Status {
    if result.success {
        return result.value
    }

    // Map error categories back to status flags
    #partial switch result.error.category {
    case .Invalid_Parameter:
        return {.Invalid_Param}
    case .Out_Of_Memory:
        return {.Out_Of_Memory}
    case .Buffer_Too_Small:
        return {.Buffer_Too_Small}
    case .Resource_Exhausted:
        return {.Out_Of_Nodes}
    case .File_Corrupted:
        return {.Wrong_Magic}
    case:
        return {} // Generic failure
    }
}

// ========================================
// ERROR FORMATTING AND LOGGING
// ========================================

// Convert error to human-readable string
nav_error_string :: proc(error: Nav_Error) -> string {
    if error.category == .None {
        return "No error"
    }

    base_message := fmt.tprintf("[%v] %s", error.category, error.message)

    if error.ctx != "" {
        base_message = fmt.tprintf("%s (at %s)", base_message, error.ctx)
    }

    if error.code != 0 {
        base_message = fmt.tprintf("%s [code: %d]", base_message, error.code)
    }

    // Add inner error if present
    if error.inner_error != nil {
        inner_str := nav_error_string(error.inner_error^)
        base_message = fmt.tprintf("%s\n  Caused by: %s", base_message, inner_str)
    }

    return base_message
}

// Log error with appropriate level
nav_log_error :: proc(error: Nav_Error, level: log.Level = .Error) {
    if error.category == .None do return

    error_str := nav_error_string(error)

    switch level {
    case .Debug:
        log.debug(error_str)
    case .Info:
        log.info(error_str)
    case .Warning:
        log.warn(error_str)
    case .Error:
        log.error(error_str)
    case .Fatal:
        log.fatal(error_str)
    }
}

// Log result error if present
nav_log_result :: proc(result: Nav_Result($T), level: log.Level = .Error) {
    if !result.success {
        nav_log_error(result.error, level)
    }
}

// ========================================
// PARAMETER VALIDATION HELPERS
// ========================================

// Validate pointer is not nil
nav_require_non_nil :: proc(ptr: rawptr, name: string, loc := #caller_location) -> Nav_Bool_Result {
    if ptr == nil {
        return nav_error_here(bool, .Invalid_Parameter, fmt.tprintf("Parameter '%s' cannot be nil", name))
    }
    return nav_success()
}

// Validate slice is not empty
nav_require_non_empty :: proc(slice: []$T, name: string, loc := #caller_location) -> Nav_Bool_Result {
    if len(slice) == 0 {
        return nav_error_here(bool, .Invalid_Parameter, fmt.tprintf("Parameter '%s' cannot be empty", name))
    }
    return nav_success()
}

// Validate range
nav_require_range :: proc(value: $T, min_val: T, max_val: T, name: string,
                         loc := #caller_location) -> Nav_Bool_Result {
    if value < min_val || value > max_val {
        return nav_error_here(bool, .Invalid_Parameter,
                             fmt.tprintf("Parameter '%s' (%v) must be in range [%v, %v]",
                                       name, value, min_val, max_val))
    }
    return nav_success()
}

// Validate positive value
nav_require_positive :: proc(value: $T, name: string, loc := #caller_location) -> Nav_Bool_Result {
    if value <= 0 {
        return nav_error_here(bool, .Invalid_Parameter,
                             fmt.tprintf("Parameter '%s' (%v) must be positive", name, value))
    }
    return nav_success()
}

// ========================================
// MIGRATION HELPERS
// ========================================

// Helper to gradually migrate from boolean returns
@(deprecated="Use nav_from_bool instead")
nav_bool_result :: proc(success: bool, error_msg: string = "") -> Nav_Bool_Result {
    return nav_from_bool(success, error_msg)
}

// Helper to gradually migrate from (bool, string) returns
@(deprecated="Use nav_from_validation instead")
nav_validation_result :: proc(success: bool, error_msg: string) -> Nav_Bool_Result {
    return nav_from_validation(success, error_msg)
}

// ========================================
// ERROR COLLECTION FOR BATCH OPERATIONS
// ========================================

// Error collector for operations that can accumulate multiple errors
Nav_Error_Collector :: struct {
    errors:    [dynamic]Nav_Error,
    max_errors: int,                    // Stop collecting after this many errors (0 = unlimited)
}

// Initialize error collector
nav_error_collector_init :: proc(collector: ^Nav_Error_Collector, max_errors: int = 0) {
    collector.errors = make([dynamic]Nav_Error)
    collector.max_errors = max_errors
}

// Add error to collector
nav_error_collector_add :: proc(collector: ^Nav_Error_Collector, error: Nav_Error) {
    if collector.max_errors > 0 && len(collector.errors) >= collector.max_errors {
        return
    }
    append(&collector.errors, error)
}

// Check if collector has errors
nav_error_collector_has_errors :: proc(collector: ^Nav_Error_Collector) -> bool {
    return len(collector.errors) > 0
}

// Convert collector to single error result
nav_error_collector_result :: proc(collector: ^Nav_Error_Collector) -> Nav_Bool_Result {
    if len(collector.errors) == 0 {
        return nav_success()
    }

    if len(collector.errors) == 1 {
        return Nav_Bool_Result{
            success = false,
            error = collector.errors[0],
        }
    }

    // Multiple errors - create a summary
    message := fmt.tprintf("Multiple errors occurred (%d total)", len(collector.errors))
    result := nav_error(bool, .Algorithm_Failed, message)

    // Chain the first error as inner error
    if len(collector.errors) > 0 {
        inner_copy := new(Nav_Error)
        inner_copy^ = collector.errors[0]
        result.error.inner_error = inner_copy
    }

    return result
}

// Clean up error collector
nav_error_collector_destroy :: proc(collector: ^Nav_Error_Collector) {
    // Clean up any dynamically allocated inner errors
    for &error in collector.errors {
        for current := error.inner_error; current != nil; {
            next := current.inner_error
            free(current)
            current = next
        }
    }
    delete(collector.errors)
}
