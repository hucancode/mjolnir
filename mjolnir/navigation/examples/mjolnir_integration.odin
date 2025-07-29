package navigation_examples

import "core:log"
import "core:slice"
import "../.." as mjolnir
import nav_recast "../recast"
import nav_recast "../recast"
import nav_rendering "../rendering"
import vk "vendor:vulkan"

// ========================================
// MJOLNIR ENGINE INTEGRATION EXAMPLE
// ========================================

// This example shows how to integrate the decoupled navigation mesh renderer
// with the Mjolnir engine's specific GPU and graphics systems.

// Wrapper for Mjolnir's GPU context to implement the abstract interface
Mjolnir_GPU_Context_Adapter :: struct {
    gpu_context: ^mjolnir.gpu.GPUContext,
    warehouse:   ^mjolnir.ResourceWarehouse,
}

// Wrapper for Mjolnir's command buffer operations
Mjolnir_Command_Buffer_Adapter :: struct {
    command_buffer: vk.CommandBuffer,
    warehouse:      ^mjolnir.ResourceWarehouse,
}

// Wrapper for Mjolnir's camera system
Mjolnir_Camera_Adapter :: struct {
    camera: ^mjolnir.geometry.Camera,
}

// Example integration structure
Navigation_Mjolnir_Integration :: struct {
    // Abstract renderer
    renderer:           nav_rendering.Nav_Mesh_Renderer,
    
    // Mjolnir-specific adapters
    gpu_adapter:        Mjolnir_GPU_Context_Adapter,
    cmd_adapter:        Mjolnir_Command_Buffer_Adapter,
    camera_adapter:     Mjolnir_Camera_Adapter,
    
    // Interface instances
    gpu_interface:      nav_rendering.GPU_Context_Interface,
    cmd_interface:      nav_rendering.Command_Buffer_Interface,
    camera_interface:   nav_rendering.Camera_Interface,
}

// ========================================
// INTEGRATION IMPLEMENTATION
// ========================================

// Initialize navigation rendering integration with Mjolnir
navigation_mjolnir_init :: proc(integration: ^Navigation_Mjolnir_Integration,
                               gpu_context: ^mjolnir.gpu.GPUContext,
                               warehouse: ^mjolnir.ResourceWarehouse,
                               camera: ^mjolnir.geometry.Camera) -> nav_recast.Nav_Result(bool) {
    
    // Setup adapters
    integration.gpu_adapter = Mjolnir_GPU_Context_Adapter{
        gpu_context = gpu_context,
        warehouse = warehouse,
    }
    
    integration.camera_adapter = Mjolnir_Camera_Adapter{
        camera = camera,
    }
    
    // Setup interface function pointers
    integration.gpu_interface = nav_rendering.GPU_Context_Interface{
        create_buffer = mjolnir_create_buffer,
        destroy_buffer = mjolnir_destroy_buffer,
        write_buffer = mjolnir_write_buffer,
        create_shader = mjolnir_create_shader,
        destroy_shader = mjolnir_destroy_shader,
        create_pipeline = mjolnir_create_pipeline,
        destroy_pipeline = mjolnir_destroy_pipeline,
        impl_data = &integration.gpu_adapter,
    }
    
    integration.cmd_interface = nav_rendering.Command_Buffer_Interface{
        bind_pipeline = mjolnir_bind_pipeline,
        bind_vertex_buffer = mjolnir_bind_vertex_buffer,
        bind_index_buffer = mjolnir_bind_index_buffer,
        set_constants = mjolnir_set_constants,
        draw_indexed = mjolnir_draw_indexed,
        impl_data = &integration.cmd_adapter,
    }
    
    integration.camera_interface = nav_rendering.Camera_Interface{
        get_view_matrix = mjolnir_get_view_matrix,
        get_projection_matrix = mjolnir_get_projection_matrix,
        get_viewport_size = mjolnir_get_viewport_size,
        impl_data = &integration.camera_adapter,
    }
    
    // Load shader code (these would be the compiled SPIR-V shaders)
    vertex_shader_code := #load("../../shader/navmesh/vert.spv")
    fragment_shader_code := #load("../../shader/navmesh/frag.spv")
    debug_vertex_shader_code := #load("../../shader/navmesh_debug/vert.spv")
    debug_fragment_shader_code := #load("../../shader/navmesh_debug/frag.spv")
    
    // Initialize the abstract renderer
    init_result := nav_rendering.nav_mesh_renderer_init(&integration.renderer,
                                                       &integration.gpu_interface,
                                                       &integration.cmd_interface,
                                                       &integration.camera_interface,
                                                       vertex_shader_code,
                                                       fragment_shader_code,
                                                       debug_vertex_shader_code,
                                                       debug_fragment_shader_code)
    
    if !nav_recast.nav_is_ok(init_result) {
        return init_result
    }
    
    log.info("Navigation mesh Mjolnir integration initialized successfully")
    return nav_recast.nav_success()
}

// Clean up the integration
navigation_mjolnir_deinit :: proc(integration: ^Navigation_Mjolnir_Integration) {
    nav_rendering.nav_mesh_renderer_deinit(&integration.renderer)
    integration^ = {}
}

// Update command buffer for rendering
navigation_mjolnir_set_command_buffer :: proc(integration: ^Navigation_Mjolnir_Integration, 
                                             command_buffer: vk.CommandBuffer) {
    integration.cmd_adapter.command_buffer = command_buffer
}

// Render navigation mesh
navigation_mjolnir_render :: proc(integration: ^Navigation_Mjolnir_Integration, 
                                world_matrix: matrix[4,4]f32) -> nav_recast.Nav_Result(bool) {
    return nav_rendering.nav_mesh_renderer_render(&integration.renderer, world_matrix)
}

// Build navigation mesh from Recast data
navigation_mjolnir_build_mesh :: proc(integration: ^Navigation_Mjolnir_Integration,
                                     poly_mesh: ^nav_recast.Rc_Poly_Mesh,
                                     detail_mesh: ^nav_recast.Rc_Poly_Mesh_Detail) -> nav_recast.Nav_Result(bool) {
    return nav_rendering.nav_mesh_renderer_build_from_recast(&integration.renderer, poly_mesh, detail_mesh)
}

// ========================================
// MJOLNIR ADAPTER IMPLEMENTATIONS
// ========================================

// GPU Context Interface Implementations
mjolnir_create_buffer :: proc(ctx: rawptr, size: int, usage: nav_rendering.Buffer_Usage_Flags) -> (nav_rendering.Buffer_Handle, nav_recast.Nav_Result(bool)) {
    adapter := cast(^Mjolnir_GPU_Context_Adapter)ctx
    
    // Convert abstract usage flags to Mjolnir usage flags
    mjolnir_usage: mjolnir.gpu.BufferUsageFlags
    if .Vertex_Buffer in usage do mjolnir_usage |= {mjolnir.gpu.BufferUsage.VERTEX_BUFFER}
    if .Index_Buffer in usage do mjolnir_usage |= {mjolnir.gpu.BufferUsage.INDEX_BUFFER}
    if .Uniform_Buffer in usage do mjolnir_usage |= {mjolnir.gpu.BufferUsage.UNIFORM_BUFFER}
    if .Storage_Buffer in usage do mjolnir_usage |= {mjolnir.gpu.BufferUsage.STORAGE_BUFFER}
    if .Transfer_Src in usage do mjolnir_usage |= {mjolnir.gpu.BufferUsage.TRANSFER_SRC}
    if .Transfer_Dst in usage do mjolnir_usage |= {mjolnir.gpu.BufferUsage.TRANSFER_DST}
    
    // Create host-visible buffer for easy updates
    buffer := mjolnir.gpu.create_host_visible_buffer(adapter.gpu_context, u8, size, mjolnir_usage)
    if buffer.buffer == 0 {
        return nil, nav_recast.nav_error(bool, .Algorithm_Failed, "Failed to create Mjolnir buffer")
    }
    
    // Return opaque handle (pointer to the buffer)
    buffer_ptr := new(mjolnir.gpu.DataBuffer(u8))
    buffer_ptr^ = buffer
    
    return nav_rendering.Buffer_Handle(buffer_ptr), nav_recast.nav_success()
}

mjolnir_destroy_buffer :: proc(ctx: rawptr, buffer: nav_rendering.Buffer_Handle) {
    if buffer == nil do return
    
    adapter := cast(^Mjolnir_GPU_Context_Adapter)ctx
    buffer_ptr := cast(^mjolnir.gpu.DataBuffer(u8))buffer
    
    mjolnir.gpu.data_buffer_deinit(adapter.gpu_context, buffer_ptr)
    free(buffer_ptr)
}

mjolnir_write_buffer :: proc(ctx: rawptr, buffer: nav_rendering.Buffer_Handle, data: []u8, offset: int) -> nav_recast.Nav_Result(bool) {
    if buffer == nil {
        return nav_recast.nav_error(bool, .Invalid_Parameter, "Buffer handle is nil")
    }
    
    buffer_ptr := cast(^mjolnir.gpu.DataBuffer(u8))buffer
    
    // Write data to the buffer
    result := mjolnir.gpu.data_buffer_write(buffer_ptr, data, offset)
    if result != .SUCCESS {
        return nav_recast.nav_error(bool, .Algorithm_Failed, "Failed to write to Mjolnir buffer")
    }
    
    return nav_recast.nav_success()
}

mjolnir_create_shader :: proc(ctx: rawptr, code: []u8, stage: nav_rendering.Shader_Stage) -> (nav_rendering.Shader_Handle, nav_recast.Nav_Result(bool)) {
    adapter := cast(^Mjolnir_GPU_Context_Adapter)ctx
    
    shader := mjolnir.gpu.create_shader_module(adapter.gpu_context, code)
    if shader.1 != .SUCCESS {
        return nil, nav_recast.nav_error(bool, .Algorithm_Failed, "Failed to create Mjolnir shader module")
    }
    
    // Store the shader module
    shader_ptr := new(vk.ShaderModule)
    shader_ptr^ = shader.0
    
    return nav_rendering.Shader_Handle(shader_ptr), nav_recast.nav_success()
}

mjolnir_destroy_shader :: proc(ctx: rawptr, shader: nav_rendering.Shader_Handle) {
    if shader == nil do return
    
    adapter := cast(^Mjolnir_GPU_Context_Adapter)ctx
    shader_ptr := cast(^vk.ShaderModule)shader
    
    vk.DestroyShaderModule(adapter.gpu_context.device, shader_ptr^, nil)
    free(shader_ptr)
}

mjolnir_create_pipeline :: proc(ctx: rawptr, desc: ^nav_rendering.Pipeline_Descriptor) -> (nav_rendering.Pipeline_Handle, nav_recast.Nav_Result(bool)) {
    // For simplicity, this would create a minimal Vulkan pipeline
    // In a real implementation, this would be more comprehensive
    adapter := cast(^Mjolnir_GPU_Context_Adapter)ctx
    
    // This is a simplified example - real implementation would be more complex
    log.warn("mjolnir_create_pipeline: Simplified implementation - needs full Vulkan pipeline creation")
    
    // Return a dummy handle for now
    pipeline_ptr := new(vk.Pipeline)
    return nav_rendering.Pipeline_Handle(pipeline_ptr), nav_recast.nav_success()
}

mjolnir_destroy_pipeline :: proc(ctx: rawptr, pipeline: nav_rendering.Pipeline_Handle) {
    if pipeline == nil do return
    
    adapter := cast(^Mjolnir_GPU_Context_Adapter)ctx
    pipeline_ptr := cast(^vk.Pipeline)pipeline
    
    if pipeline_ptr^ != 0 {
        vk.DestroyPipeline(adapter.gpu_context.device, pipeline_ptr^, nil)
    }
    free(pipeline_ptr)
}

// Command Buffer Interface Implementations
mjolnir_bind_pipeline :: proc(cmd: rawptr, pipeline: nav_rendering.Pipeline_Handle) {
    adapter := cast(^Mjolnir_Command_Buffer_Adapter)cmd
    pipeline_ptr := cast(^vk.Pipeline)pipeline
    
    if pipeline_ptr^ != 0 {
        vk.CmdBindPipeline(adapter.command_buffer, .GRAPHICS, pipeline_ptr^)
    }
}

mjolnir_bind_vertex_buffer :: proc(cmd: rawptr, buffer: nav_rendering.Buffer_Handle, offset: int) {
    adapter := cast(^Mjolnir_Command_Buffer_Adapter)cmd
    buffer_ptr := cast(^mjolnir.gpu.DataBuffer(u8))buffer
    
    vertex_buffers := []vk.Buffer{buffer_ptr.buffer}
    offsets := []vk.DeviceSize{vk.DeviceSize(offset)}
    vk.CmdBindVertexBuffers(adapter.command_buffer, 0, 1, raw_data(vertex_buffers), raw_data(offsets))
}

mjolnir_bind_index_buffer :: proc(cmd: rawptr, buffer: nav_rendering.Buffer_Handle, offset: int, index_type: nav_rendering.Index_Type) {
    adapter := cast(^Mjolnir_Command_Buffer_Adapter)cmd
    buffer_ptr := cast(^mjolnir.gpu.DataBuffer(u8))buffer
    
    vk_index_type := vk.IndexType.UINT32 if index_type == .UInt32 else vk.IndexType.UINT16
    vk.CmdBindIndexBuffer(adapter.command_buffer, buffer_ptr.buffer, vk.DeviceSize(offset), vk_index_type)
}

mjolnir_set_constants :: proc(cmd: rawptr, data: []u8, offset: int) {
    adapter := cast(^Mjolnir_Command_Buffer_Adapter)cmd
    
    // This would need the actual pipeline layout from the pipeline creation
    // For now, this is a placeholder
    log.warn("mjolnir_set_constants: Placeholder implementation - needs actual pipeline layout")
}

mjolnir_draw_indexed :: proc(cmd: rawptr, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) {
    adapter := cast(^Mjolnir_Command_Buffer_Adapter)cmd
    vk.CmdDrawIndexed(adapter.command_buffer, index_count, instance_count, first_index, vertex_offset, first_instance)
}

// Camera Interface Implementations
mjolnir_get_view_matrix :: proc(camera: rawptr) -> matrix[4,4]f32 {
    adapter := cast(^Mjolnir_Camera_Adapter)camera
    return mjolnir.geometry.camera_view_matrix(adapter.camera^)
}

mjolnir_get_projection_matrix :: proc(camera: rawptr) -> matrix[4,4]f32 {
    adapter := cast(^Mjolnir_Camera_Adapter)camera
    return mjolnir.geometry.camera_projection_matrix(adapter.camera^)
}

mjolnir_get_viewport_size :: proc(camera: rawptr) -> [2]f32 {
    adapter := cast(^Mjolnir_Camera_Adapter)camera
    // This would need to come from the actual viewport/window size
    return {1920.0, 1080.0}  // Placeholder
}

// ========================================
// USAGE EXAMPLE
// ========================================

// Example usage function showing how to use the decoupled renderer
example_navigation_rendering_usage :: proc(gpu_context: ^mjolnir.gpu.GPUContext,
                                          warehouse: ^mjolnir.ResourceWarehouse,
                                          camera: ^mjolnir.geometry.Camera,
                                          command_buffer: vk.CommandBuffer) -> nav_recast.Nav_Result(bool) {
    
    // Create integration
    integration: Navigation_Mjolnir_Integration
    defer navigation_mjolnir_deinit(&integration)
    
    // Initialize with Mjolnir components
    init_result := navigation_mjolnir_init(&integration, gpu_context, warehouse, camera)
    if !nav_recast.nav_is_ok(init_result) {
        log.errorf("Failed to initialize navigation rendering: %s", nav_recast.nav_error_string(init_result.error))
        return init_result
    }
    
    // Set command buffer for this frame
    navigation_mjolnir_set_command_buffer(&integration, command_buffer)
    
    // Example: Build a simple navigation mesh
    geometry := nav_recast.Geometry_Input{
        vertices = []f32{-5, 0, -5, 5, 0, -5, 5, 0, 5, -5, 0, 5},
        indices = []i32{0, 1, 2, 0, 2, 3},
        areas = []u8{1, 1},
    }
    
    config := nav_recast.create_config_from_preset(.Fast)
    build_result := nav_recast.build_navmesh(&geometry, config)
    defer if build_result.success do nav_recast.free_build_result(&build_result)
    
    if build_result.success {
        // Build renderer from navigation mesh
        build_renderer_result := navigation_mjolnir_build_mesh(&integration, build_result.polygon_mesh, build_result.detail_mesh)
        if !nav_recast.nav_is_ok(build_renderer_result) {
            log.errorf("Failed to build renderer mesh: %s", nav_recast.nav_error_string(build_renderer_result.error))
            return build_renderer_result
        }
        
        // Render with identity world matrix
        world_matrix := matrix[4,4]f32{
            1, 0, 0, 0,
            0, 1, 0, 0, 
            0, 0, 1, 0,
            0, 0, 0, 1,
        }
        
        render_result := navigation_mjolnir_render(&integration, world_matrix)
        if !nav_recast.nav_is_ok(render_result) {
            log.errorf("Failed to render navigation mesh: %s", nav_recast.nav_error_string(render_result.error))
            return render_result
        }
        
        log.info("Successfully rendered navigation mesh")
    } else {
        log.warnf("Failed to build navigation mesh: %s", build_result.error_message)
    }
    
    return nav_recast.nav_success()
}