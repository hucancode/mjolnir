package navigation_rendering

import "core:log"
import nav_recast "../recast"
import nav_recast "../recast"

// ========================================
// ABSTRACT RENDERING INTERFACES
// ========================================

// Abstract interface for GPU context management
// Implement this interface to integrate with any graphics API (Vulkan, OpenGL, D3D12, etc.)
GPU_Context_Interface :: struct {
    // Function pointers for GPU operations
    create_buffer:    proc(ctx: rawptr, size: int, usage: Buffer_Usage_Flags) -> (Buffer_Handle, nav_recast.Nav_Result(bool)),
    destroy_buffer:   proc(ctx: rawptr, buffer: Buffer_Handle),
    write_buffer:     proc(ctx: rawptr, buffer: Buffer_Handle, data: []u8, offset: int) -> nav_recast.Nav_Result(bool),
    
    create_shader:    proc(ctx: rawptr, code: []u8, stage: Shader_Stage) -> (Shader_Handle, nav_recast.Nav_Result(bool)),
    destroy_shader:   proc(ctx: rawptr, shader: Shader_Handle),
    
    create_pipeline:  proc(ctx: rawptr, desc: ^Pipeline_Descriptor) -> (Pipeline_Handle, nav_recast.Nav_Result(bool)),
    destroy_pipeline: proc(ctx: rawptr, pipeline: Pipeline_Handle),
    
    // Opaque pointer to implementation-specific context
    impl_data:        rawptr,
}

// Abstract interface for command buffer operations
Command_Buffer_Interface :: struct {
    bind_pipeline:      proc(cmd: rawptr, pipeline: Pipeline_Handle),
    bind_vertex_buffer: proc(cmd: rawptr, buffer: Buffer_Handle, offset: int),
    bind_index_buffer:  proc(cmd: rawptr, buffer: Buffer_Handle, offset: int, index_type: Index_Type),
    set_constants:      proc(cmd: rawptr, data: []u8, offset: int),
    draw_indexed:       proc(cmd: rawptr, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32),
    
    // Opaque pointer to implementation-specific command buffer
    impl_data:          rawptr,
}

// Camera interface for rendering transformations
Camera_Interface :: struct {
    get_view_matrix:       proc(camera: rawptr) -> matrix[4,4]f32,
    get_projection_matrix: proc(camera: rawptr) -> matrix[4,4]f32,
    get_viewport_size:     proc(camera: rawptr) -> [2]f32,
    
    // Opaque pointer to implementation-specific camera
    impl_data:             rawptr,
}

// ========================================
// RENDERING RESOURCE TYPES
// ========================================

// Opaque handles for graphics resources
Buffer_Handle :: distinct rawptr
Shader_Handle :: distinct rawptr
Pipeline_Handle :: distinct rawptr

// Buffer usage flags
Buffer_Usage_Flags :: enum u32 {
    Vertex_Buffer,
    Index_Buffer,
    Uniform_Buffer,
    Storage_Buffer,
    Transfer_Src,
    Transfer_Dst,
}

// Shader stages
Shader_Stage :: enum u32 {
    Vertex,
    Fragment,
    Compute,
}

// Index types
Index_Type :: enum u32 {
    UInt16,
    UInt32,
}

// Vertex attribute descriptor
Vertex_Attribute :: struct {
    location: u32,
    binding:  u32,
    format:   Vertex_Format,
    offset:   u32,
}

// Vertex formats
Vertex_Format :: enum u32 {
    Float3,     // vec3
    Float4,     // vec4
    UInt32,     // uint32
}

// Pipeline descriptor for creating rendering pipelines
Pipeline_Descriptor :: struct {
    vertex_shader:     Shader_Handle,
    fragment_shader:   Shader_Handle,
    vertex_attributes: []Vertex_Attribute,
    vertex_stride:     u32,
    primitive_topology: Primitive_Topology,
    depth_test:        bool,
    depth_write:       bool,
    blending:          Blending_State,
}

// Primitive topology
Primitive_Topology :: enum u32 {
    Triangle_List,
    Line_List,
    Point_List,
}

// Blending state
Blending_State :: struct {
    enabled:                bool,
    src_color_blend_factor: Blend_Factor,
    dst_color_blend_factor: Blend_Factor,
    color_blend_op:         Blend_Op,
    src_alpha_blend_factor: Blend_Factor,
    dst_alpha_blend_factor: Blend_Factor,
    alpha_blend_op:         Blend_Op,
}

Blend_Factor :: enum u32 {
    Zero,
    One,
    Src_Alpha,
    One_Minus_Src_Alpha,
    Dst_Alpha,
    One_Minus_Dst_Alpha,
}

Blend_Op :: enum u32 {
    Add,
    Subtract,
    Reverse_Subtract,
    Min,
    Max,
}

// ========================================
// NAVIGATION MESH RENDERING STATE
// ========================================

// Vertex structure for navigation mesh rendering
Nav_Mesh_Vertex :: struct {
    position: [3]f32,
    color:    [4]f32,
    normal:   [3]f32,
}

// Color modes for navigation mesh visualization
Nav_Mesh_Color_Mode :: enum u32 {
    Area_Colors = 0,  // Color by area type
    Uniform = 1,      // Single color
    Height_Based = 2, // Color by height
}

// Debug modes for navigation mesh visualization
Nav_Mesh_Debug_Mode :: enum u32 {
    Wireframe = 0,    // Show wireframe
    Normals = 1,      // Show normals as colors
    Connectivity = 2, // Show polygon connectivity
}

// Push constants for navigation mesh rendering
Nav_Mesh_Push_Constants :: struct {
    world_matrix:   matrix[4,4]f32,  // 64 bytes
    view_matrix:    matrix[4,4]f32,  // 64 bytes
    proj_matrix:    matrix[4,4]f32,  // 64 bytes
    height_offset:  f32,             // 4
    alpha:          f32,             // 4
    color_mode:     u32,             // 4
    debug_mode:     u32,             // 4
    // Total: 204 bytes
}

// ========================================
// RENDERING CONFIGURATION
// ========================================

// Configuration for navigation mesh rendering
Nav_Mesh_Render_Config :: struct {
    enabled:              bool,
    debug_mode:           bool,
    height_offset:        f32,          // Offset above ground
    alpha:                f32,          // Transparency
    color_mode:           Nav_Mesh_Color_Mode,
    debug_render_mode:    Nav_Mesh_Debug_Mode,
    base_color:           [3]f32,
    wireframe_line_width: f32,
}

// Default configuration
DEFAULT_RENDER_CONFIG := Nav_Mesh_Render_Config{
    enabled = true,
    debug_mode = false,
    height_offset = 0.01,  // 1cm above ground
    alpha = 0.6,
    color_mode = .Area_Colors,
    debug_render_mode = .Wireframe,
    base_color = {0.0, 0.8, 0.2},  // Green
    wireframe_line_width = 2.0,
}

// Default area colors for different area types
DEFAULT_AREA_COLORS := [7][4]f32{
    0 = {0.0, 0.0, 0.0, 0.0},     // NULL_AREA - transparent
    1 = {0.0, 0.8, 0.2, 0.6},     // WALKABLE_AREA - green
    2 = {0.8, 0.4, 0.0, 0.6},     // JUMP_AREA - orange  
    3 = {0.2, 0.4, 0.8, 0.6},     // WATER_AREA - blue
    4 = {0.8, 0.2, 0.2, 0.6},     // DOOR_AREA - red
    5 = {0.6, 0.6, 0.6, 0.6},     // ELEVATOR_AREA - gray
    6 = {0.8, 0.8, 0.0, 0.6},     // LADDER_AREA - yellow
}

// ========================================
// UTILITY FUNCTIONS
// ========================================

// Get color for area type
nav_mesh_get_area_color :: proc(area_id: u8, color_mode: Nav_Mesh_Color_Mode, base_color: [3]f32, alpha: f32) -> [4]f32 {
    switch color_mode {
    case .Area_Colors:
        if int(area_id) < len(DEFAULT_AREA_COLORS) {
            color := DEFAULT_AREA_COLORS[area_id]
            color.a = alpha  // Override alpha
            return color
        }
        return {0.5, 0.5, 0.5, alpha}  // Default gray
        
    case .Uniform:
        return {base_color.x, base_color.y, base_color.z, alpha}
        
    case .Height_Based:
        // Height-based coloring would require height information
        // For now, use a gradient based on area_id as a proxy
        hue := f32(area_id) / 8.0
        return {hue, 1.0 - hue, 0.5, alpha}
    }
    
    return {base_color.x, base_color.y, base_color.z, alpha}
}

// Validation for rendering interfaces
nav_validate_gpu_interface :: proc(gpu_interface: ^GPU_Context_Interface) -> nav_recast.Nav_Result(bool) {
    if gpu_interface == nil {
        return nav_recast.nav_error(bool, .Invalid_Parameter, "GPU interface cannot be nil")
    }
    
    if gpu_interface.create_buffer == nil ||
       gpu_interface.destroy_buffer == nil ||
       gpu_interface.write_buffer == nil ||
       gpu_interface.create_shader == nil ||
       gpu_interface.destroy_shader == nil ||
       gpu_interface.create_pipeline == nil ||
       gpu_interface.destroy_pipeline == nil {
        return nav_recast.nav_error(bool, .Invalid_Parameter, "GPU interface has nil function pointers")
    }
    
    return nav_recast.nav_success()
}

nav_validate_command_buffer_interface :: proc(cmd_interface: ^Command_Buffer_Interface) -> nav_recast.Nav_Result(bool) {
    if cmd_interface == nil {
        return nav_recast.nav_error(bool, .Invalid_Parameter, "Command buffer interface cannot be nil")
    }
    
    if cmd_interface.bind_pipeline == nil ||
       cmd_interface.bind_vertex_buffer == nil ||
       cmd_interface.bind_index_buffer == nil ||
       cmd_interface.set_constants == nil ||
       cmd_interface.draw_indexed == nil {
        return nav_recast.nav_error(bool, .Invalid_Parameter, "Command buffer interface has nil function pointers")
    }
    
    return nav_recast.nav_success()
}

nav_validate_camera_interface :: proc(camera_interface: ^Camera_Interface) -> nav_recast.Nav_Result(bool) {
    if camera_interface == nil {
        return nav_recast.nav_error(bool, .Invalid_Parameter, "Camera interface cannot be nil")
    }
    
    if camera_interface.get_view_matrix == nil ||
       camera_interface.get_projection_matrix == nil ||
       camera_interface.get_viewport_size == nil {
        return nav_recast.nav_error(bool, .Invalid_Parameter, "Camera interface has nil function pointers")
    }
    
    return nav_recast.nav_success()
}