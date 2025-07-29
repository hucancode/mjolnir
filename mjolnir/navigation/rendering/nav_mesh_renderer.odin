package navigation_rendering

import "core:log"
import "core:slice"
import "core:mem"
import nav_recast "../recast"
import nav_recast "../recast"

// ========================================
// NAVIGATION MESH RENDERER
// ========================================

// Abstract navigation mesh renderer that works with any graphics API
Nav_Mesh_Renderer :: struct {
    // Rendering interfaces
    gpu_interface:     ^GPU_Context_Interface,
    cmd_interface:     ^Command_Buffer_Interface,
    camera_interface:  ^Camera_Interface,
    
    // Rendering resources
    vertex_buffer:     Buffer_Handle,
    index_buffer:      Buffer_Handle,
    vertex_shader:     Shader_Handle,
    fragment_shader:   Shader_Handle,
    debug_vertex_shader: Shader_Handle,
    debug_fragment_shader: Shader_Handle,
    pipeline:          Pipeline_Handle,
    debug_pipeline:    Pipeline_Handle,
    
    // Rendering state
    vertex_count:      u32,
    index_count:       u32,
    config:            Nav_Mesh_Render_Config,
    
    // Internal state
    initialized:       bool,
}

// ========================================
// RENDERER LIFECYCLE
// ========================================

// Initialize the navigation mesh renderer
nav_mesh_renderer_init :: proc(renderer: ^Nav_Mesh_Renderer, 
                              gpu_interface: ^GPU_Context_Interface,
                              cmd_interface: ^Command_Buffer_Interface,
                              camera_interface: ^Camera_Interface,
                              vertex_shader_code: []u8,
                              fragment_shader_code: []u8,
                              debug_vertex_shader_code: []u8,
                              debug_fragment_shader_code: []u8) -> nav_recast.Nav_Result(bool) {
    
    // Validate interfaces
    gpu_validation := nav_validate_gpu_interface(gpu_interface)
    if !nav_recast.nav_is_ok(gpu_validation) {
        return gpu_validation
    }
    
    cmd_validation := nav_validate_command_buffer_interface(cmd_interface)
    if !nav_recast.nav_is_ok(cmd_validation) {
        return cmd_validation
    }
    
    camera_validation := nav_validate_camera_interface(camera_interface)
    if !nav_recast.nav_is_ok(camera_validation) {
        return camera_validation
    }
    
    renderer.gpu_interface = gpu_interface
    renderer.cmd_interface = cmd_interface
    renderer.camera_interface = camera_interface
    renderer.config = DEFAULT_RENDER_CONFIG
    
    // Create shaders
    vertex_shader, vertex_shader_result := renderer.gpu_interface.create_shader(renderer.gpu_interface.impl_data, vertex_shader_code, .Vertex)
    if !nav_recast.nav_is_ok(vertex_shader_result) {
        return nav_recast.nav_error_chain(bool, .Algorithm_Failed, "Failed to create vertex shader", vertex_shader_result.error)
    }
    renderer.vertex_shader = vertex_shader
    
    fragment_shader, fragment_shader_result := renderer.gpu_interface.create_shader(renderer.gpu_interface.impl_data, fragment_shader_code, .Fragment)
    if !nav_recast.nav_is_ok(fragment_shader_result) {
        nav_mesh_renderer_cleanup_partial(renderer)
        return nav_recast.nav_error_chain(bool, .Algorithm_Failed, "Failed to create fragment shader", fragment_shader_result.error)
    }
    renderer.fragment_shader = fragment_shader
    
    debug_vertex_shader, debug_vertex_shader_result := renderer.gpu_interface.create_shader(renderer.gpu_interface.impl_data, debug_vertex_shader_code, .Vertex)
    if !nav_recast.nav_is_ok(debug_vertex_shader_result) {
        nav_mesh_renderer_cleanup_partial(renderer)
        return nav_recast.nav_error_chain(bool, .Algorithm_Failed, "Failed to create debug vertex shader", debug_vertex_shader_result.error)
    }
    renderer.debug_vertex_shader = debug_vertex_shader
    
    debug_fragment_shader, debug_fragment_shader_result := renderer.gpu_interface.create_shader(renderer.gpu_interface.impl_data, debug_fragment_shader_code, .Fragment)
    if !nav_recast.nav_is_ok(debug_fragment_shader_result) {
        nav_mesh_renderer_cleanup_partial(renderer)
        return nav_recast.nav_error_chain(bool, .Algorithm_Failed, "Failed to create debug fragment shader", debug_fragment_shader_result.error)
    }
    renderer.debug_fragment_shader = debug_fragment_shader
    
    // Create pipelines
    create_result := nav_mesh_renderer_create_pipelines(renderer)
    if !nav_recast.nav_is_ok(create_result) {
        nav_mesh_renderer_cleanup_partial(renderer)
        return create_result
    }
    
    // Create empty buffers (initial size, will be resized as needed)
    vertex_buffer, vertex_buffer_result := renderer.gpu_interface.create_buffer(renderer.gpu_interface.impl_data, 1024 * size_of(Nav_Mesh_Vertex), .Vertex_Buffer)
    if !nav_recast.nav_is_ok(vertex_buffer_result) {
        nav_mesh_renderer_cleanup_partial(renderer)
        return nav_recast.nav_error_chain(bool, .Algorithm_Failed, "Failed to create vertex buffer", vertex_buffer_result.error)
    }
    renderer.vertex_buffer = vertex_buffer
    
    index_buffer, index_buffer_result := renderer.gpu_interface.create_buffer(renderer.gpu_interface.impl_data, 2048 * size_of(u32), .Index_Buffer)
    if !nav_recast.nav_is_ok(index_buffer_result) {
        nav_mesh_renderer_cleanup_partial(renderer)
        return nav_recast.nav_error_chain(bool, .Algorithm_Failed, "Failed to create index buffer", index_buffer_result.error)
    }
    renderer.index_buffer = index_buffer
    
    renderer.initialized = true
    log.info("Navigation mesh renderer initialized successfully")
    return nav_recast.nav_success()
}

// Clean up the navigation mesh renderer
nav_mesh_renderer_deinit :: proc(renderer: ^Nav_Mesh_Renderer) {
    if !renderer.initialized do return
    
    if renderer.gpu_interface != nil {
        if renderer.vertex_buffer != nil {
            renderer.gpu_interface.destroy_buffer(renderer.gpu_interface.impl_data, renderer.vertex_buffer)
        }
        if renderer.index_buffer != nil {
            renderer.gpu_interface.destroy_buffer(renderer.gpu_interface.impl_data, renderer.index_buffer)
        }
        if renderer.pipeline != nil {
            renderer.gpu_interface.destroy_pipeline(renderer.gpu_interface.impl_data, renderer.pipeline)
        }
        if renderer.debug_pipeline != nil {
            renderer.gpu_interface.destroy_pipeline(renderer.gpu_interface.impl_data, renderer.debug_pipeline)
        }
        if renderer.vertex_shader != nil {
            renderer.gpu_interface.destroy_shader(renderer.gpu_interface.impl_data, renderer.vertex_shader)
        }
        if renderer.fragment_shader != nil {
            renderer.gpu_interface.destroy_shader(renderer.gpu_interface.impl_data, renderer.fragment_shader)
        }
        if renderer.debug_vertex_shader != nil {
            renderer.gpu_interface.destroy_shader(renderer.gpu_interface.impl_data, renderer.debug_vertex_shader)
        }
        if renderer.debug_fragment_shader != nil {
            renderer.gpu_interface.destroy_shader(renderer.gpu_interface.impl_data, renderer.debug_fragment_shader)
        }
    }
    
    renderer^ = {}
    log.info("Navigation mesh renderer cleaned up")
}

// ========================================
// MESH DATA MANAGEMENT
// ========================================

// Build vertex data from navigation mesh
nav_mesh_renderer_build_from_recast :: proc(renderer: ^Nav_Mesh_Renderer, 
                                           poly_mesh: ^nav_recast.Rc_Poly_Mesh, 
                                           detail_mesh: ^nav_recast.Rc_Poly_Mesh_Detail) -> nav_recast.Nav_Result(bool) {
    if !renderer.initialized {
        return nav_recast.nav_error(bool, .Algorithm_Failed, "Renderer not initialized")
    }
    
    if poly_mesh == nil {
        return nav_recast.nav_error(bool, .Invalid_Parameter, "Polygon mesh cannot be nil")
    }
    
    vertices := make([dynamic]Nav_Mesh_Vertex, 0, poly_mesh.nverts)
    indices := make([dynamic]u32, 0, poly_mesh.npolys * 6)  // Estimate
    defer delete(vertices)
    defer delete(indices)
    
    // Convert polygon mesh vertices
    for i in 0..<poly_mesh.nverts {
        vertex_idx := int(i) * 3
        if vertex_idx + 2 >= len(poly_mesh.verts) do continue
        
        pos := [3]f32{
            f32(poly_mesh.verts[vertex_idx]) * poly_mesh.cs + poly_mesh.bmin[0],
            f32(poly_mesh.verts[vertex_idx + 1]) * poly_mesh.ch + poly_mesh.bmin[1], 
            f32(poly_mesh.verts[vertex_idx + 2]) * poly_mesh.cs + poly_mesh.bmin[2],
        }
        
        // Default normal pointing up
        normal := [3]f32{0, 1, 0}
        
        // Default color (will be overridden based on color mode)
        color := [4]f32{0.0, 0.8, 0.2, renderer.config.alpha}
        
        append(&vertices, Nav_Mesh_Vertex{
            position = pos,
            color = color,
            normal = normal,
        })
    }
    
    // Convert polygon indices  
    for i in 0..<poly_mesh.npolys {
        poly_base := int(i) * int(poly_mesh.nvp)
        area_id := poly_mesh.areas[i] if len(poly_mesh.areas) > int(i) else 1
        
        // Get area color
        area_color := nav_mesh_get_area_color(area_id, renderer.config.color_mode, renderer.config.base_color, renderer.config.alpha)
        
        // Count valid vertices in this polygon
        poly_verts: [dynamic]u32
        defer delete(poly_verts)
        
        for j in 0..<poly_mesh.nvp {
            vert_idx := poly_mesh.polys[poly_base + int(j)]
            if vert_idx == nav_recast.RC_MESH_NULL_IDX do break
            append(&poly_verts, u32(vert_idx))
            
            // Update vertex color
            if int(vert_idx) < len(vertices) {
                vertices[vert_idx].color = area_color
            }
        }
        
        // Triangulate polygon (simple fan triangulation)
        if len(poly_verts) >= 3 {
            for j in 1..<len(poly_verts) - 1 {
                append(&indices, poly_verts[0])
                append(&indices, poly_verts[j])
                append(&indices, poly_verts[j + 1])
            }
        }
    }
    
    // Update vertex and index counts
    renderer.vertex_count = u32(len(vertices))
    renderer.index_count = u32(len(indices))
    
    if renderer.vertex_count == 0 || renderer.index_count == 0 {
        log.warn("Navigation mesh has no renderable geometry")
        return nav_recast.nav_success()
    }
    
    // Upload to GPU buffers  
    vertex_data := slice.reinterpret([]u8, vertices[:])
    vertex_result := renderer.gpu_interface.write_buffer(renderer.gpu_interface.impl_data, renderer.vertex_buffer, vertex_data, 0)
    if !nav_recast.nav_is_ok(vertex_result) {
        return nav_recast.nav_error_chain(bool, .Algorithm_Failed, "Failed to upload navigation mesh vertex data", vertex_result.error)
    }
    
    index_data := slice.reinterpret([]u8, indices[:])
    index_result := renderer.gpu_interface.write_buffer(renderer.gpu_interface.impl_data, renderer.index_buffer, index_data, 0)
    if !nav_recast.nav_is_ok(index_result) {
        return nav_recast.nav_error_chain(bool, .Algorithm_Failed, "Failed to upload navigation mesh index data", index_result.error)
    }
    
    log.infof("Built navigation mesh renderer: %d vertices, %d indices (%d triangles)", 
              renderer.vertex_count, renderer.index_count, renderer.index_count / 3)
    return nav_recast.nav_success()
}

// ========================================
// RENDERING
// ========================================

// Render navigation mesh
nav_mesh_renderer_render :: proc(renderer: ^Nav_Mesh_Renderer, world_matrix: matrix[4,4]f32) -> nav_recast.Nav_Result(bool) {
    if !renderer.initialized {
        return nav_recast.nav_error(bool, .Algorithm_Failed, "Renderer not initialized")
    }
    
    if !renderer.config.enabled || renderer.vertex_count == 0 || renderer.index_count == 0 {
        return nav_recast.nav_success()
    }
    
    // Get camera matrices
    view_matrix := renderer.camera_interface.get_view_matrix(renderer.camera_interface.impl_data)
    proj_matrix := renderer.camera_interface.get_projection_matrix(renderer.camera_interface.impl_data)
    
    // Choose pipeline based on debug mode
    pipeline := renderer.debug_pipeline if renderer.config.debug_mode else renderer.pipeline
    
    // Bind pipeline
    renderer.cmd_interface.bind_pipeline(renderer.cmd_interface.impl_data, pipeline)
    
    // Bind vertex and index buffers
    renderer.cmd_interface.bind_vertex_buffer(renderer.cmd_interface.impl_data, renderer.vertex_buffer, 0)
    renderer.cmd_interface.bind_index_buffer(renderer.cmd_interface.impl_data, renderer.index_buffer, 0, .UInt32)
    
    // Set push constants
    push_constants := Nav_Mesh_Push_Constants{
        world_matrix = world_matrix,
        view_matrix = view_matrix,
        proj_matrix = proj_matrix,
        height_offset = renderer.config.height_offset,
        alpha = renderer.config.alpha,
        color_mode = u32(renderer.config.color_mode),
        debug_mode = u32(renderer.config.debug_render_mode),
    }
    
    constants_data := slice.reinterpret([]u8, []Nav_Mesh_Push_Constants{push_constants})
    renderer.cmd_interface.set_constants(renderer.cmd_interface.impl_data, constants_data, 0)
    
    // Draw
    renderer.cmd_interface.draw_indexed(renderer.cmd_interface.impl_data, renderer.index_count, 1, 0, 0, 0)
    
    return nav_recast.nav_success()
}

// ========================================
// CONFIGURATION
// ========================================

// Update renderer configuration
nav_mesh_renderer_set_config :: proc(renderer: ^Nav_Mesh_Renderer, config: Nav_Mesh_Render_Config) {
    renderer.config = config
}

// Get current renderer configuration
nav_mesh_renderer_get_config :: proc(renderer: ^Nav_Mesh_Renderer) -> Nav_Mesh_Render_Config {
    return renderer.config
}

// ========================================
// INTERNAL HELPERS
// ========================================

// Create rendering pipelines
nav_mesh_renderer_create_pipelines :: proc(renderer: ^Nav_Mesh_Renderer) -> nav_recast.Nav_Result(bool) {
    // Main pipeline descriptor
    vertex_attributes := []Vertex_Attribute{
        {location = 0, binding = 0, format = .Float3, offset = u32(offset_of(Nav_Mesh_Vertex, position))},
        {location = 1, binding = 0, format = .Float4, offset = u32(offset_of(Nav_Mesh_Vertex, color))},
        {location = 2, binding = 0, format = .Float3, offset = u32(offset_of(Nav_Mesh_Vertex, normal))},
    }
    
    main_pipeline_desc := Pipeline_Descriptor{
        vertex_shader = renderer.vertex_shader,
        fragment_shader = renderer.fragment_shader,
        vertex_attributes = vertex_attributes,
        vertex_stride = size_of(Nav_Mesh_Vertex),
        primitive_topology = .Triangle_List,
        depth_test = true,
        depth_write = false,  // Don't write depth for transparent overlay
        blending = Blending_State{
            enabled = true,
            src_color_blend_factor = .Src_Alpha,
            dst_color_blend_factor = .One_Minus_Src_Alpha,
            color_blend_op = .Add,
            src_alpha_blend_factor = .One,
            dst_alpha_blend_factor = .One_Minus_Src_Alpha,
            alpha_blend_op = .Add,
        },
    }
    
    main_pipeline, main_pipeline_result := renderer.gpu_interface.create_pipeline(renderer.gpu_interface.impl_data, &main_pipeline_desc)
    if !nav_recast.nav_is_ok(main_pipeline_result) {
        return nav_recast.nav_error_chain(bool, .Algorithm_Failed, "Failed to create main navigation mesh pipeline", main_pipeline_result.error)
    }
    renderer.pipeline = main_pipeline
    
    // Debug pipeline descriptor (wireframe, no blending)
    debug_pipeline_desc := Pipeline_Descriptor{
        vertex_shader = renderer.debug_vertex_shader,
        fragment_shader = renderer.debug_fragment_shader,
        vertex_attributes = vertex_attributes[:2],  // Only position and normal for debug
        vertex_stride = size_of(Nav_Mesh_Vertex),
        primitive_topology = .Line_List,
        depth_test = true,
        depth_write = false,
        blending = Blending_State{
            enabled = false,
        },
    }
    
    debug_pipeline, debug_pipeline_result := renderer.gpu_interface.create_pipeline(renderer.gpu_interface.impl_data, &debug_pipeline_desc)
    if !nav_recast.nav_is_ok(debug_pipeline_result) {
        return nav_recast.nav_error_chain(bool, .Algorithm_Failed, "Failed to create debug navigation mesh pipeline", debug_pipeline_result.error)
    }
    renderer.debug_pipeline = debug_pipeline
    
    return nav_recast.nav_success()
}

// Partial cleanup for initialization failures
nav_mesh_renderer_cleanup_partial :: proc(renderer: ^Nav_Mesh_Renderer) {
    if renderer.gpu_interface == nil do return
    
    if renderer.vertex_shader != nil {
        renderer.gpu_interface.destroy_shader(renderer.gpu_interface.impl_data, renderer.vertex_shader)
    }
    if renderer.fragment_shader != nil {
        renderer.gpu_interface.destroy_shader(renderer.gpu_interface.impl_data, renderer.fragment_shader)
    }
    if renderer.debug_vertex_shader != nil {
        renderer.gpu_interface.destroy_shader(renderer.gpu_interface.impl_data, renderer.debug_vertex_shader)
    }
    if renderer.debug_fragment_shader != nil {
        renderer.gpu_interface.destroy_shader(renderer.gpu_interface.impl_data, renderer.debug_fragment_shader)
    }
    if renderer.pipeline != nil {
        renderer.gpu_interface.destroy_pipeline(renderer.gpu_interface.impl_data, renderer.pipeline)
    }
    if renderer.debug_pipeline != nil {
        renderer.gpu_interface.destroy_pipeline(renderer.gpu_interface.impl_data, renderer.debug_pipeline)
    }
}