package navigation_examples

import "core:log"
import nav_recast "../recast"
import nav_recast "../recast"
import nav_rendering "../rendering"

// ========================================
// GENERIC ENGINE INTEGRATION EXAMPLE
// ========================================

// This example shows how to implement the abstract interfaces for any graphics engine.
// Copy this template and adapt it to your specific graphics API and engine.

// Example: Integration with a hypothetical engine called "MyEngine"
My_Engine_GPU_Context :: struct {
    device:     rawptr,  // Your engine's GPU device handle
    allocator:  rawptr,  // Your engine's memory allocator
    // Add your engine-specific fields here
}

My_Engine_Buffer :: struct {
    handle:     rawptr,  // Your engine's buffer handle
    size:       int,
    usage:      u32,
    // Add your engine-specific buffer fields here
}

My_Engine_Shader :: struct {
    handle:     rawptr,  // Your engine's shader handle
    stage:      u32,
    // Add your engine-specific shader fields here
}

My_Engine_Pipeline :: struct {
    handle:     rawptr,  // Your engine's pipeline handle
    layout:     rawptr,  // Your engine's pipeline layout
    // Add your engine-specific pipeline fields here
}

My_Engine_Command_Buffer :: struct {
    handle:     rawptr,  // Your engine's command buffer handle
    // Add your engine-specific command buffer fields here
}

My_Engine_Camera :: struct {
    position:    [3]f32,
    view_matrix: matrix[4,4]f32,
    proj_matrix: matrix[4,4]f32,
    viewport:    [2]f32,
    // Add your engine-specific camera fields here
}

// Generic integration wrapper
Generic_Navigation_Integration :: struct {
    renderer:           nav_rendering.Nav_Mesh_Renderer,
    
    // Your engine components
    gpu_context:        ^My_Engine_GPU_Context,
    command_buffer:     ^My_Engine_Command_Buffer,
    camera:             ^My_Engine_Camera,
    
    // Abstract interfaces
    gpu_interface:      nav_rendering.GPU_Context_Interface,
    cmd_interface:      nav_rendering.Command_Buffer_Interface,
    camera_interface:   nav_rendering.Camera_Interface,
}

// ========================================
// INTEGRATION FUNCTIONS
// ========================================

// Initialize the generic integration
generic_navigation_init :: proc(integration: ^Generic_Navigation_Integration,
                               gpu_context: ^My_Engine_GPU_Context,
                               command_buffer: ^My_Engine_Command_Buffer,
                               camera: ^My_Engine_Camera,
                               vertex_shader_code: []u8,
                               fragment_shader_code: []u8,
                               debug_vertex_shader_code: []u8,
                               debug_fragment_shader_code: []u8) -> nav_recast.Nav_Result(bool) {
    
    integration.gpu_context = gpu_context
    integration.command_buffer = command_buffer
    integration.camera = camera
    
    // Setup interface function pointers to your engine implementations
    integration.gpu_interface = nav_rendering.GPU_Context_Interface{
        create_buffer = my_engine_create_buffer,
        destroy_buffer = my_engine_destroy_buffer,
        write_buffer = my_engine_write_buffer,
        create_shader = my_engine_create_shader,
        destroy_shader = my_engine_destroy_shader,
        create_pipeline = my_engine_create_pipeline,
        destroy_pipeline = my_engine_destroy_pipeline,
        impl_data = gpu_context,
    }
    
    integration.cmd_interface = nav_rendering.Command_Buffer_Interface{
        bind_pipeline = my_engine_bind_pipeline,
        bind_vertex_buffer = my_engine_bind_vertex_buffer,
        bind_index_buffer = my_engine_bind_index_buffer,
        set_constants = my_engine_set_constants,
        draw_indexed = my_engine_draw_indexed,
        impl_data = command_buffer,
    }
    
    integration.camera_interface = nav_rendering.Camera_Interface{
        get_view_matrix = my_engine_get_view_matrix,
        get_projection_matrix = my_engine_get_projection_matrix,
        get_viewport_size = my_engine_get_viewport_size,
        impl_data = camera,
    }
    
    // Initialize the abstract renderer
    return nav_rendering.nav_mesh_renderer_init(&integration.renderer,
                                               &integration.gpu_interface,
                                               &integration.cmd_interface,
                                               &integration.camera_interface,
                                               vertex_shader_code,
                                               fragment_shader_code,
                                               debug_vertex_shader_code,
                                               debug_fragment_shader_code)
}

// Clean up the integration
generic_navigation_deinit :: proc(integration: ^Generic_Navigation_Integration) {
    nav_rendering.nav_mesh_renderer_deinit(&integration.renderer)
    integration^ = {}
}

// ========================================
// YOUR ENGINE INTERFACE IMPLEMENTATIONS
// ========================================
// Implement these functions to interface with your specific graphics engine

// GPU Context Interface - Implement these for your engine
my_engine_create_buffer :: proc(ctx: rawptr, size: int, usage: nav_rendering.Buffer_Usage_Flags) -> (nav_rendering.Buffer_Handle, nav_recast.Nav_Result(bool)) {
    gpu_context := cast(^My_Engine_GPU_Context)ctx
    
    // TODO: Implement buffer creation for your engine
    // Example pseudo-code:
    // engine_usage := convert_usage_flags(usage)
    // buffer_handle := your_engine_create_buffer(gpu_context.device, size, engine_usage)
    // if buffer_handle == nil {
    //     return nil, nav_recast.nav_error(bool, .Algorithm_Failed, "Failed to create buffer")
    // }
    // 
    // buffer := new(My_Engine_Buffer)
    // buffer.handle = buffer_handle
    // buffer.size = size
    // return nav_rendering.Buffer_Handle(buffer), nav_recast.nav_success()
    
    log.warn("my_engine_create_buffer: IMPLEMENT THIS FOR YOUR ENGINE")
    return nil, nav_recast.nav_error(bool, .Algorithm_Failed, "Not implemented")
}

my_engine_destroy_buffer :: proc(ctx: rawptr, buffer: nav_rendering.Buffer_Handle) {
    if buffer == nil do return
    
    gpu_context := cast(^My_Engine_GPU_Context)ctx
    engine_buffer := cast(^My_Engine_Buffer)buffer
    
    // TODO: Implement buffer destruction for your engine
    // Example pseudo-code:
    // your_engine_destroy_buffer(gpu_context.device, engine_buffer.handle)
    // free(engine_buffer)
    
    log.warn("my_engine_destroy_buffer: IMPLEMENT THIS FOR YOUR ENGINE")
}

my_engine_write_buffer :: proc(ctx: rawptr, buffer: nav_rendering.Buffer_Handle, data: []u8, offset: int) -> nav_recast.Nav_Result(bool) {
    if buffer == nil {
        return nav_recast.nav_error(bool, .Invalid_Parameter, "Buffer is nil")
    }
    
    gpu_context := cast(^My_Engine_GPU_Context)ctx
    engine_buffer := cast(^My_Engine_Buffer)buffer
    
    // TODO: Implement buffer writing for your engine
    // Example pseudo-code:
    // result := your_engine_write_buffer(engine_buffer.handle, data, offset)
    // if !result.success {
    //     return nav_recast.nav_error(bool, .Algorithm_Failed, "Failed to write buffer")
    // }
    // return nav_recast.nav_success()
    
    log.warn("my_engine_write_buffer: IMPLEMENT THIS FOR YOUR ENGINE")
    return nav_recast.nav_error(bool, .Algorithm_Failed, "Not implemented")
}

my_engine_create_shader :: proc(ctx: rawptr, code: []u8, stage: nav_rendering.Shader_Stage) -> (nav_rendering.Shader_Handle, nav_recast.Nav_Result(bool)) {
    gpu_context := cast(^My_Engine_GPU_Context)ctx
    
    // TODO: Implement shader creation for your engine
    // Example pseudo-code:
    // engine_stage := convert_shader_stage(stage)
    // shader_handle := your_engine_create_shader(gpu_context.device, code, engine_stage)
    // if shader_handle == nil {
    //     return nil, nav_recast.nav_error(bool, .Algorithm_Failed, "Failed to create shader")
    // }
    // 
    // shader := new(My_Engine_Shader)
    // shader.handle = shader_handle
    // shader.stage = u32(stage)
    // return nav_rendering.Shader_Handle(shader), nav_recast.nav_success()
    
    log.warn("my_engine_create_shader: IMPLEMENT THIS FOR YOUR ENGINE")
    return nil, nav_recast.nav_error(bool, .Algorithm_Failed, "Not implemented")
}

my_engine_destroy_shader :: proc(ctx: rawptr, shader: nav_rendering.Shader_Handle) {
    if shader == nil do return
    
    gpu_context := cast(^My_Engine_GPU_Context)ctx
    engine_shader := cast(^My_Engine_Shader)shader
    
    // TODO: Implement shader destruction for your engine
    // Example pseudo-code:
    // your_engine_destroy_shader(gpu_context.device, engine_shader.handle)
    // free(engine_shader)
    
    log.warn("my_engine_destroy_shader: IMPLEMENT THIS FOR YOUR ENGINE")
}

my_engine_create_pipeline :: proc(ctx: rawptr, desc: ^nav_rendering.Pipeline_Descriptor) -> (nav_rendering.Pipeline_Handle, nav_recast.Nav_Result(bool)) {
    gpu_context := cast(^My_Engine_GPU_Context)ctx
    
    // TODO: Implement pipeline creation for your engine
    // This is typically the most complex part as it involves converting
    // the abstract pipeline descriptor to your engine's specific format
    // 
    // Example pseudo-code:
    // vertex_shader := cast(^My_Engine_Shader)desc.vertex_shader
    // fragment_shader := cast(^My_Engine_Shader)desc.fragment_shader
    // 
    // engine_desc := Your_Engine_Pipeline_Desc{
    //     vertex_shader = vertex_shader.handle,
    //     fragment_shader = fragment_shader.handle,
    //     vertex_attributes = convert_vertex_attributes(desc.vertex_attributes),
    //     vertex_stride = desc.vertex_stride,
    //     primitive_topology = convert_topology(desc.primitive_topology),
    //     depth_test = desc.depth_test,
    //     depth_write = desc.depth_write,
    //     blending = convert_blending(desc.blending),
    // }
    // 
    // pipeline_handle := your_engine_create_pipeline(gpu_context.device, &engine_desc)
    // if pipeline_handle == nil {
    //     return nil, nav_recast.nav_error(bool, .Algorithm_Failed, "Failed to create pipeline")
    // }
    // 
    // pipeline := new(My_Engine_Pipeline)
    // pipeline.handle = pipeline_handle
    // return nav_rendering.Pipeline_Handle(pipeline), nav_recast.nav_success()
    
    log.warn("my_engine_create_pipeline: IMPLEMENT THIS FOR YOUR ENGINE")
    return nil, nav_recast.nav_error(bool, .Algorithm_Failed, "Not implemented")
}

my_engine_destroy_pipeline :: proc(ctx: rawptr, pipeline: nav_rendering.Pipeline_Handle) {
    if pipeline == nil do return
    
    gpu_context := cast(^My_Engine_GPU_Context)ctx
    engine_pipeline := cast(^My_Engine_Pipeline)pipeline
    
    // TODO: Implement pipeline destruction for your engine
    // Example pseudo-code:
    // your_engine_destroy_pipeline(gpu_context.device, engine_pipeline.handle)
    // free(engine_pipeline)
    
    log.warn("my_engine_destroy_pipeline: IMPLEMENT THIS FOR YOUR ENGINE")
}

// Command Buffer Interface - Implement these for your engine
my_engine_bind_pipeline :: proc(cmd: rawptr, pipeline: nav_rendering.Pipeline_Handle) {
    command_buffer := cast(^My_Engine_Command_Buffer)cmd
    engine_pipeline := cast(^My_Engine_Pipeline)pipeline
    
    // TODO: Implement pipeline binding for your engine
    // Example pseudo-code:
    // your_engine_bind_pipeline(command_buffer.handle, engine_pipeline.handle)
    
    log.warn("my_engine_bind_pipeline: IMPLEMENT THIS FOR YOUR ENGINE")
}

my_engine_bind_vertex_buffer :: proc(cmd: rawptr, buffer: nav_rendering.Buffer_Handle, offset: int) {
    command_buffer := cast(^My_Engine_Command_Buffer)cmd
    engine_buffer := cast(^My_Engine_Buffer)buffer
    
    // TODO: Implement vertex buffer binding for your engine
    // Example pseudo-code:
    // your_engine_bind_vertex_buffer(command_buffer.handle, engine_buffer.handle, offset)
    
    log.warn("my_engine_bind_vertex_buffer: IMPLEMENT THIS FOR YOUR ENGINE")
}

my_engine_bind_index_buffer :: proc(cmd: rawptr, buffer: nav_rendering.Buffer_Handle, offset: int, index_type: nav_rendering.Index_Type) {
    command_buffer := cast(^My_Engine_Command_Buffer)cmd
    engine_buffer := cast(^My_Engine_Buffer)buffer
    
    // TODO: Implement index buffer binding for your engine
    // Example pseudo-code:
    // engine_index_type := convert_index_type(index_type)
    // your_engine_bind_index_buffer(command_buffer.handle, engine_buffer.handle, offset, engine_index_type)
    
    log.warn("my_engine_bind_index_buffer: IMPLEMENT THIS FOR YOUR ENGINE")
}

my_engine_set_constants :: proc(cmd: rawptr, data: []u8, offset: int) {
    command_buffer := cast(^My_Engine_Command_Buffer)cmd
    
    // TODO: Implement push constants or uniform buffer update for your engine
    // Example pseudo-code:
    // your_engine_set_push_constants(command_buffer.handle, data, offset)
    // OR
    // your_engine_update_uniform_buffer(command_buffer.handle, uniform_buffer, data, offset)
    
    log.warn("my_engine_set_constants: IMPLEMENT THIS FOR YOUR ENGINE")
}

my_engine_draw_indexed :: proc(cmd: rawptr, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) {
    command_buffer := cast(^My_Engine_Command_Buffer)cmd
    
    // TODO: Implement indexed drawing for your engine
    // Example pseudo-code:
    // your_engine_draw_indexed(command_buffer.handle, index_count, instance_count, first_index, vertex_offset, first_instance)
    
    log.warn("my_engine_draw_indexed: IMPLEMENT THIS FOR YOUR ENGINE")
}

// Camera Interface - Implement these for your engine
my_engine_get_view_matrix :: proc(camera: rawptr) -> matrix[4,4]f32 {
    engine_camera := cast(^My_Engine_Camera)camera
    
    // TODO: Return the view matrix from your camera system
    // Example:
    // return engine_camera.view_matrix
    
    log.warn("my_engine_get_view_matrix: IMPLEMENT THIS FOR YOUR ENGINE")
    return matrix[4,4]f32{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    }
}

my_engine_get_projection_matrix :: proc(camera: rawptr) -> matrix[4,4]f32 {
    engine_camera := cast(^My_Engine_Camera)camera
    
    // TODO: Return the projection matrix from your camera system
    // Example:
    // return engine_camera.proj_matrix
    
    log.warn("my_engine_get_projection_matrix: IMPLEMENT THIS FOR YOUR ENGINE")
    return matrix[4,4]f32{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    }
}

my_engine_get_viewport_size :: proc(camera: rawptr) -> [2]f32 {
    engine_camera := cast(^My_Engine_Camera)camera
    
    // TODO: Return the viewport size from your camera/window system
    // Example:
    // return engine_camera.viewport
    
    log.warn("my_engine_get_viewport_size: IMPLEMENT THIS FOR YOUR ENGINE")
    return {1920.0, 1080.0}
}

// ========================================
// HELPER FUNCTIONS FOR YOUR ENGINE
// ========================================

// Add helper functions to convert between abstract types and your engine types
convert_usage_flags :: proc(usage: nav_rendering.Buffer_Usage_Flags) -> u32 {
    // TODO: Convert abstract usage flags to your engine's buffer usage flags
    result: u32 = 0
    if .Vertex_Buffer in usage do result |= 1  // YOUR_ENGINE_VERTEX_BUFFER_BIT
    if .Index_Buffer in usage do result |= 2   // YOUR_ENGINE_INDEX_BUFFER_BIT
    // ... add more conversions as needed
    return result
}

convert_shader_stage :: proc(stage: nav_rendering.Shader_Stage) -> u32 {
    // TODO: Convert abstract shader stage to your engine's shader stage
    switch stage {
    case .Vertex:   return 1  // YOUR_ENGINE_VERTEX_STAGE
    case .Fragment: return 2  // YOUR_ENGINE_FRAGMENT_STAGE
    case .Compute:  return 3  // YOUR_ENGINE_COMPUTE_STAGE
    }
    return 0
}

// Add more conversion functions as needed for your engine...

// ========================================
// USAGE DOCUMENTATION
// ========================================

/*
To integrate with your engine:

1. Replace My_Engine_* structs with your actual engine types
2. Implement all the my_engine_* functions to call your engine's API
3. Add any additional conversion functions you need
4. Load your shaders in the appropriate format for your engine
5. Initialize the integration with your engine components

Example usage:
```odin
// Your engine setup
my_gpu_context := My_Engine_GPU_Context{...}
my_command_buffer := My_Engine_Command_Buffer{...}
my_camera := My_Engine_Camera{...}

// Load shaders (format depends on your engine)
vertex_shader_code := load_shader_for_my_engine("navmesh.vert")
fragment_shader_code := load_shader_for_my_engine("navmesh.frag")
debug_vertex_shader_code := load_shader_for_my_engine("navmesh_debug.vert")
debug_fragment_shader_code := load_shader_for_my_engine("navmesh_debug.frag")

// Initialize navigation rendering
integration: Generic_Navigation_Integration
result := generic_navigation_init(&integration, 
                                  &my_gpu_context, &my_command_buffer, &my_camera,
                                  vertex_shader_code, fragment_shader_code,
                                  debug_vertex_shader_code, debug_fragment_shader_code)

if nav_recast.nav_is_ok(result) {
    // Build and render navigation meshes...
    defer generic_navigation_deinit(&integration)
}
```

The navigation system is now completely decoupled from any specific engine!
*/