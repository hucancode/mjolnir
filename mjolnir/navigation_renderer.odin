package mjolnir

import "core:log"
import "core:math/linalg"
import "core:slice"
import "geometry"
import "gpu"
import "resource"
import nav_recast "navigation/recast"
import recast "navigation/recast"
import vk "vendor:vulkan"

// Navigation mesh rendering component
NavMeshRenderer :: struct {
    // Vulkan resources
    pipeline:                vk.Pipeline,
    pipeline_layout:         vk.PipelineLayout,
    debug_pipeline:          vk.Pipeline,
    debug_pipeline_layout:   vk.PipelineLayout,
    
    // Vertex data for navigation mesh
    vertex_buffer:           gpu.DataBuffer(NavMeshVertex),
    index_buffer:            gpu.DataBuffer(u32),
    vertex_count:            u32,
    index_count:             u32,
    
    // Rendering state
    enabled:                 bool,
    debug_mode:              bool,
    height_offset:           f32,  // Offset above ground
    alpha:                   f32,  // Transparency
    color_mode:              NavMeshColorMode,
    debug_render_mode:       NavMeshDebugMode,
    base_color:              [3]f32,
}

// Vertex structure for navigation mesh rendering
NavMeshVertex :: struct {
    position: [3]f32,
    color:    [4]f32,
    normal:   [3]f32,
}

NavMeshColorMode :: enum u32 {
    Area_Colors = 0,  // Color by area type
    Uniform = 1,      // Single color
    Height_Based = 2, // Color by height
}

NavMeshDebugMode :: enum u32 {
    Wireframe = 0,    // Show wireframe
    Normals = 1,      // Show normals as colors
    Connectivity = 2, // Show polygon connectivity
}

// Push constants for navigation mesh rendering
NavMeshPushConstants :: struct {
    world:         matrix[4,4]f32,  // 64 bytes
    camera_index:  u32,             // 4
    height_offset: f32,             // 4
    alpha:         f32,             // 4
    color_mode:    u32,             // 4
    padding:       [11]f32,         // 44 (pad to 128)
}

// Push constants for debug rendering
NavMeshDebugPushConstants :: struct {
    world:         matrix[4,4]f32,  // 64 bytes
    camera_index:  u32,             // 4
    height_offset: f32,             // 4
    line_width:    f32,             // 4
    debug_mode:    u32,             // 4
    debug_color:   [3]f32,          // 12
    padding:       [8]f32,          // 32 (pad to 128)
}

// Default area colors for different area types
AREA_COLORS := [7][4]f32{
    0 = {0.0, 0.0, 0.0, 0.0},     // NULL_AREA - transparent
    1 = {0.0, 0.8, 0.2, 0.6},     // WALKABLE_AREA - green
    2 = {0.8, 0.4, 0.0, 0.6},     // JUMP_AREA - orange  
    3 = {0.2, 0.4, 0.8, 0.6},     // WATER_AREA - blue
    4 = {0.8, 0.2, 0.2, 0.6},     // DOOR_AREA - red
    5 = {0.6, 0.6, 0.6, 0.6},     // ELEVATOR_AREA - gray
    6 = {0.8, 0.8, 0.0, 0.6},     // LADDER_AREA - yellow
}

// Initialize navigation mesh renderer
navmesh_renderer_init :: proc(renderer: ^NavMeshRenderer, gpu_context: ^gpu.GPUContext, warehouse: ^ResourceWarehouse) -> vk.Result {
    // Initialize default values
    renderer.enabled = true
    renderer.debug_mode = false
    renderer.height_offset = 0.01
    renderer.alpha = 0.6
    renderer.color_mode = .Area_Colors
    renderer.debug_render_mode = .Wireframe
    renderer.base_color = {0.0, 0.8, 0.2}
    
    // Create pipelines
    result := create_navmesh_pipelines(renderer, gpu_context, warehouse)
    if result != .SUCCESS {
        log.errorf("Failed to create navigation mesh pipelines: %v", result)
        return result
    }
    
    // Initialize empty buffers
    renderer.vertex_buffer = gpu.create_host_visible_buffer(gpu_context, NavMeshVertex, 1024, {.VERTEX_BUFFER}) or_return
    renderer.index_buffer = gpu.create_host_visible_buffer(gpu_context, u32, 2048, {.INDEX_BUFFER}) or_return
    
    log.info("Navigation mesh renderer initialized successfully")
    return .SUCCESS
}

// Clean up navigation mesh renderer
navmesh_renderer_deinit :: proc(renderer: ^NavMeshRenderer, gpu_context: ^gpu.GPUContext) {
    if renderer.pipeline != 0 {
        vk.DestroyPipeline(gpu_context.device, renderer.pipeline, nil)
    }
    if renderer.pipeline_layout != 0 {
        vk.DestroyPipelineLayout(gpu_context.device, renderer.pipeline_layout, nil)
    }
    if renderer.debug_pipeline != 0 {
        vk.DestroyPipeline(gpu_context.device, renderer.debug_pipeline, nil)
    }
    if renderer.debug_pipeline_layout != 0 {
        vk.DestroyPipelineLayout(gpu_context.device, renderer.debug_pipeline_layout, nil)
    }
    
    gpu.data_buffer_deinit(gpu_context, &renderer.vertex_buffer)
    gpu.data_buffer_deinit(gpu_context, &renderer.index_buffer)
}

// Build vertex data from navigation mesh
navmesh_renderer_build_from_recast :: proc(renderer: ^NavMeshRenderer, gpu_context: ^gpu.GPUContext, 
                                          poly_mesh: ^recast.Rc_Poly_Mesh, detail_mesh: ^recast.Rc_Poly_Mesh_Detail) -> bool {
    if poly_mesh == nil {
        log.error("Cannot build navigation mesh renderer: polygon mesh is nil")
        return false
    }
    
    vertices := make([dynamic]NavMeshVertex, 0, poly_mesh.nverts)
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
        color := [4]f32{0.0, 0.8, 0.2, renderer.alpha}
        
        append(&vertices, NavMeshVertex{
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
        area_color := get_area_color(area_id, renderer.color_mode, renderer.base_color, renderer.alpha)
        
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
        return true
    }
    
    // Upload to GPU buffers  
    vertex_result := gpu.data_buffer_write(&renderer.vertex_buffer, vertices[:])
    if vertex_result != .SUCCESS {
        log.error("Failed to upload navigation mesh vertex data")
        return false
    }
    
    index_result := gpu.data_buffer_write(&renderer.index_buffer, indices[:])
    if index_result != .SUCCESS {
        log.error("Failed to upload navigation mesh index data")
        return false
    }
    
    log.infof("Built navigation mesh renderer: %d vertices, %d indices (%d triangles)", 
              renderer.vertex_count, renderer.index_count, renderer.index_count / 3)
    return true
}

// Get color for area type
get_area_color :: proc(area_id: u8, color_mode: NavMeshColorMode, base_color: [3]f32, alpha: f32) -> [4]f32 {
    switch color_mode {
    case .Area_Colors:
        if int(area_id) < len(AREA_COLORS) {
            color := AREA_COLORS[area_id]
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

// Render navigation mesh
navmesh_renderer_render :: proc(renderer: ^NavMeshRenderer, command_buffer: vk.CommandBuffer, 
                               world_matrix: matrix[4,4]f32, camera_index: u32) {
    if !renderer.enabled || renderer.vertex_count == 0 || renderer.index_count == 0 {
        return
    }
    
    pipeline := renderer.debug_pipeline if renderer.debug_mode else renderer.pipeline
    pipeline_layout := renderer.debug_pipeline_layout if renderer.debug_mode else renderer.pipeline_layout
    
    vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline)
    
    // Bind vertex and index buffers
    vertex_buffers := []vk.Buffer{renderer.vertex_buffer.buffer}
    offsets := []vk.DeviceSize{0}
    vk.CmdBindVertexBuffers(command_buffer, 0, 1, raw_data(vertex_buffers), raw_data(offsets))
    vk.CmdBindIndexBuffer(command_buffer, renderer.index_buffer.buffer, 0, .UINT32)
    
    // Set push constants
    if renderer.debug_mode {
        push_constants := NavMeshDebugPushConstants{
            world = world_matrix,
            camera_index = camera_index,
            height_offset = renderer.height_offset,
            line_width = 1.0,
            debug_mode = u32(renderer.debug_render_mode),
            debug_color = renderer.base_color,
        }
        vk.CmdPushConstants(command_buffer, pipeline_layout, {.VERTEX, .FRAGMENT}, 
                           0, size_of(NavMeshDebugPushConstants), &push_constants)
    } else {
        push_constants := NavMeshPushConstants{
            world = world_matrix,
            camera_index = camera_index,
            height_offset = renderer.height_offset,
            alpha = renderer.alpha,
            color_mode = u32(renderer.color_mode),
        }
        vk.CmdPushConstants(command_buffer, pipeline_layout, {.VERTEX, .FRAGMENT}, 
                           0, size_of(NavMeshPushConstants), &push_constants)
    }
    
    // Draw
    vk.CmdDrawIndexed(command_buffer, renderer.index_count, 1, 0, 0, 0)
}

// Create rendering pipelines
create_navmesh_pipelines :: proc(renderer: ^NavMeshRenderer, gpu_context: ^gpu.GPUContext, warehouse: ^ResourceWarehouse) -> vk.Result {
    // Load shaders
    navmesh_vert_code := #load("shader/navmesh/vert.spv")
    navmesh_vert := gpu.create_shader_module(gpu_context, navmesh_vert_code) or_return
    defer vk.DestroyShaderModule(gpu_context.device, navmesh_vert, nil)
    
    navmesh_frag_code := #load("shader/navmesh/frag.spv")
    navmesh_frag := gpu.create_shader_module(gpu_context, navmesh_frag_code) or_return
    defer vk.DestroyShaderModule(gpu_context.device, navmesh_frag, nil)
    
    navmesh_debug_vert_code := #load("shader/navmesh_debug/vert.spv")
    navmesh_debug_vert := gpu.create_shader_module(gpu_context, navmesh_debug_vert_code) or_return
    defer vk.DestroyShaderModule(gpu_context.device, navmesh_debug_vert, nil)
    
    navmesh_debug_frag_code := #load("shader/navmesh_debug/frag.spv")
    navmesh_debug_frag := gpu.create_shader_module(gpu_context, navmesh_debug_frag_code) or_return
    defer vk.DestroyShaderModule(gpu_context.device, navmesh_debug_frag, nil)
    
    // Create descriptor set layouts (using camera buffer from warehouse)
    set_layouts := []vk.DescriptorSetLayout{warehouse.camera_buffer_set_layout}
    
    // Create pipeline layouts
    push_constant_range := vk.PushConstantRange{
        stageFlags = {.VERTEX, .FRAGMENT},
        offset = 0,
        size = size_of(NavMeshPushConstants),
    }
    
    layout_info := vk.PipelineLayoutCreateInfo{
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = u32(len(set_layouts)),
        pSetLayouts = raw_data(set_layouts),
        pushConstantRangeCount = 1,
        pPushConstantRanges = &push_constant_range,
    }
    
    vk.CreatePipelineLayout(gpu_context.device, &layout_info, nil, &renderer.pipeline_layout) or_return
    
    // Debug pipeline layout (different push constants)
    debug_push_constant_range := vk.PushConstantRange{
        stageFlags = {.VERTEX, .FRAGMENT},
        offset = 0,
        size = size_of(NavMeshDebugPushConstants),
    }
    
    debug_layout_info := layout_info
    debug_layout_info.pPushConstantRanges = &debug_push_constant_range
    
    vk.CreatePipelineLayout(gpu_context.device, &debug_layout_info, nil, &renderer.debug_pipeline_layout) or_return
    
    // Vertex input description
    vertex_binding := vk.VertexInputBindingDescription{
        binding = 0,
        stride = size_of(NavMeshVertex),
        inputRate = .VERTEX,
    }
    
    vertex_attributes := []vk.VertexInputAttributeDescription{
        {location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(NavMeshVertex, position))},
        {location = 1, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(NavMeshVertex, color))},
        {location = 2, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(NavMeshVertex, normal))},
    }
    
    vertex_input := vk.PipelineVertexInputStateCreateInfo{
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount = 1,
        pVertexBindingDescriptions = &vertex_binding,
        vertexAttributeDescriptionCount = u32(len(vertex_attributes)),
        pVertexAttributeDescriptions = raw_data(vertex_attributes),
    }
    
    // Common pipeline state
    input_assembly := vk.PipelineInputAssemblyStateCreateInfo{
        sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology = .TRIANGLE_LIST,
    }
    
    viewport_state := vk.PipelineViewportStateCreateInfo{
        sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        scissorCount = 1,
    }
    
    multisampling := vk.PipelineMultisampleStateCreateInfo{
        sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        rasterizationSamples = {._1},
    }
    
    // Depth testing enabled, writing disabled (transparent overlay)
    depth_stencil := vk.PipelineDepthStencilStateCreateInfo{
        sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        depthTestEnable = true,
        depthWriteEnable = false,  // Don't write depth for transparent navmesh
        depthCompareOp = .LESS_OR_EQUAL,
    }
    
    dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
    dynamic_state := vk.PipelineDynamicStateCreateInfo{
        sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount = u32(len(dynamic_states)),
        pDynamicStates = raw_data(dynamic_states),
    }
    
    // Render target formats (using transparent renderer format)
    depth_format: vk.Format = .D32_SFLOAT
    color_format: vk.Format = .B8G8R8A8_SRGB
    
    rendering_info := vk.PipelineRenderingCreateInfo{
        sType = .PIPELINE_RENDERING_CREATE_INFO,
        colorAttachmentCount = 1,
        pColorAttachmentFormats = &color_format,
        depthAttachmentFormat = depth_format,
    }
    
    // Create main navigation mesh pipeline (with blending)
    rasterizer := vk.PipelineRasterizationStateCreateInfo{
        sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        polygonMode = .FILL,
        cullMode = {},  // No culling for transparent navmesh
        frontFace = .COUNTER_CLOCKWISE,
        lineWidth = 1.0,
    }
    
    color_blend_attachment := vk.PipelineColorBlendAttachmentState{
        blendEnable = true,
        srcColorBlendFactor = .SRC_ALPHA,
        dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
        colorBlendOp = .ADD,
        srcAlphaBlendFactor = .ONE,
        dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
        alphaBlendOp = .ADD,
        colorWriteMask = {.R, .G, .B, .A},
    }
    
    color_blending := vk.PipelineColorBlendStateCreateInfo{
        sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        attachmentCount = 1,
        pAttachments = &color_blend_attachment,
    }
    
    shader_stages := []vk.PipelineShaderStageCreateInfo{
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = {.VERTEX},
            module = navmesh_vert,
            pName = "main",
        },
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = {.FRAGMENT},
            module = navmesh_frag,
            pName = "main",
        },
    }
    
    pipeline_info := vk.GraphicsPipelineCreateInfo{
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        stageCount = u32(len(shader_stages)),
        pStages = raw_data(shader_stages),
        pVertexInputState = &vertex_input,
        pInputAssemblyState = &input_assembly,
        pViewportState = &viewport_state,
        pRasterizationState = &rasterizer,
        pMultisampleState = &multisampling,
        pDepthStencilState = &depth_stencil,
        pColorBlendState = &color_blending,
        pDynamicState = &dynamic_state,
        layout = renderer.pipeline_layout,
        pNext = &rendering_info,
    }
    
    vk.CreateGraphicsPipelines(gpu_context.device, 0, 1, &pipeline_info, nil, &renderer.pipeline) or_return
    
    // Create debug pipeline (wireframe mode)
    debug_rasterizer := rasterizer
    debug_rasterizer.polygonMode = .LINE
    debug_rasterizer.lineWidth = 2.0
    
    // No blending for debug wireframe
    debug_color_blend_attachment := vk.PipelineColorBlendAttachmentState{
        blendEnable = false,
        colorWriteMask = {.R, .G, .B, .A},
    }
    
    debug_color_blending := vk.PipelineColorBlendStateCreateInfo{
        sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        attachmentCount = 1,
        pAttachments = &debug_color_blend_attachment,
    }
    
    debug_shader_stages := []vk.PipelineShaderStageCreateInfo{
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = {.VERTEX},
            module = navmesh_debug_vert,
            pName = "main",
        },
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = {.FRAGMENT},
            module = navmesh_debug_frag,
            pName = "main",
        },
    }
    
    // Update vertex input for debug shaders (different layout)
    debug_vertex_attributes := []vk.VertexInputAttributeDescription{
        {location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(NavMeshVertex, position))},
        {location = 1, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(NavMeshVertex, normal))},
    }
    
    debug_vertex_input := vk.PipelineVertexInputStateCreateInfo{
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount = 1,
        pVertexBindingDescriptions = &vertex_binding,
        vertexAttributeDescriptionCount = u32(len(debug_vertex_attributes)),
        pVertexAttributeDescriptions = raw_data(debug_vertex_attributes),
    }
    
    debug_pipeline_info := vk.GraphicsPipelineCreateInfo{
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        stageCount = u32(len(debug_shader_stages)),
        pStages = raw_data(debug_shader_stages),
        pVertexInputState = &debug_vertex_input,
        pInputAssemblyState = &input_assembly,
        pViewportState = &viewport_state,
        pRasterizationState = &debug_rasterizer,
        pMultisampleState = &multisampling,
        pDepthStencilState = &depth_stencil,
        pColorBlendState = &debug_color_blending,
        pDynamicState = &dynamic_state,
        layout = renderer.debug_pipeline_layout,
        pNext = &rendering_info,
    }
    
    vk.CreateGraphicsPipelines(gpu_context.device, 0, 1, &debug_pipeline_info, nil, &renderer.debug_pipeline) or_return
    
    log.info("Navigation mesh pipelines created successfully")
    return .SUCCESS
}

// ========================================
// PUBLIC API
// ========================================


// Get current configuration
navmesh_renderer_get_enabled :: proc(renderer: ^NavMeshRenderer) -> bool {
    return renderer.enabled
}

navmesh_renderer_get_debug_mode :: proc(renderer: ^NavMeshRenderer) -> bool {
    return renderer.debug_mode
}

navmesh_renderer_get_alpha :: proc(renderer: ^NavMeshRenderer) -> f32 {
    return renderer.alpha
}

navmesh_renderer_get_height_offset :: proc(renderer: ^NavMeshRenderer) -> f32 {
    return renderer.height_offset
}

navmesh_renderer_get_color_mode :: proc(renderer: ^NavMeshRenderer) -> NavMeshColorMode {
    return renderer.color_mode
}

navmesh_renderer_get_base_color :: proc(renderer: ^NavMeshRenderer) -> [3]f32 {
    return renderer.base_color
}

navmesh_renderer_get_debug_render_mode :: proc(renderer: ^NavMeshRenderer) -> NavMeshDebugMode {
    return renderer.debug_render_mode
}

// Navigation mesh data management
navmesh_renderer_clear :: proc(renderer: ^NavMeshRenderer) {
    renderer.vertex_count = 0
    renderer.index_count = 0
}

navmesh_renderer_get_triangle_count :: proc(renderer: ^NavMeshRenderer) -> u32 {
    return renderer.index_count / 3
}

navmesh_renderer_get_vertex_count :: proc(renderer: ^NavMeshRenderer) -> u32 {
    return renderer.vertex_count
}

navmesh_renderer_has_data :: proc(renderer: ^NavMeshRenderer) -> bool {
    return renderer.vertex_count > 0 && renderer.index_count > 0
}