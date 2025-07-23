package gui

import "../gpu"
import vk "vendor:vulkan"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:slice"

GUI_MAX_VERTICES :: 65536
GUI_MAX_INDICES :: 98304

SHADER_GUI_ATLAS_VERT :: #load("../shader/gui/gui_atlas/vert.spv")
SHADER_GUI_ATLAS_FRAG :: #load("../shader/gui/gui_atlas/frag.spv")
SHADER_GUI_TEXT_VERT :: #load("../shader/gui/gui_sdf_text/vert.spv")
SHADER_GUI_TEXT_FRAG :: #load("../shader/gui/gui_sdf_text/frag.spv")

GUIVertex :: struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
}

GUIRenderer :: struct {
    pipeline_atlas: vk.Pipeline,
    pipeline_text: vk.Pipeline,
    vertex_buffer: gpu.DataBuffer(GUIVertex),
    index_buffer: gpu.DataBuffer(u32),
    uniform_buffer: gpu.DataBuffer(matrix[4,4]f32),
    max_vertices: u32,
    max_indices: u32,
}

gui_renderer_init :: proc(renderer: ^GUIRenderer, gpu_context: ^gpu.GPUContext) -> vk.Result {
    renderer.max_vertices = GUI_MAX_VERTICES
    renderer.max_indices = GUI_MAX_INDICES
    
    // Create vertex buffer
    renderer.vertex_buffer = gpu.create_host_visible_buffer(
        gpu_context,
        GUIVertex,
        int(renderer.max_vertices),
        {.VERTEX_BUFFER},
    ) or_return
    
    // Create index buffer
    renderer.index_buffer = gpu.create_host_visible_buffer(
        gpu_context,
        u32,
        int(renderer.max_indices),
        {.INDEX_BUFFER},
    ) or_return
    
    // Create uniform buffer for projection matrix
    ortho := linalg.matrix_ortho3d(f32(0), f32(1920), f32(1080), f32(0), f32(-1), f32(1)) // Default size, will be updated
    renderer.uniform_buffer = gpu.create_host_visible_buffer(
        gpu_context,
        matrix[4,4]f32,
        1,
        {.UNIFORM_BUFFER},
        raw_data(&ortho),
    ) or_return
    
    // Create pipeline for atlas rendering
    if create_atlas_pipeline(renderer, gpu_context) != .SUCCESS {
        log.error("Failed to create atlas pipeline")
        cleanup_buffers(renderer, gpu_context)
        return .ERROR_INITIALIZATION_FAILED
    }
    
    // Create pipeline for text rendering
    if create_text_pipeline(renderer, gpu_context) != .SUCCESS {
        log.error("Failed to create text pipeline")
        cleanup_buffers(renderer, gpu_context)
        vk.DestroyPipeline(gpu_context.device, renderer.pipeline_atlas, nil)
        return .ERROR_INITIALIZATION_FAILED
    }
    
    return .SUCCESS
}

create_atlas_pipeline :: proc(renderer: ^GUIRenderer, gpu_context: ^gpu.GPUContext) -> vk.Result {
    // Create shader modules
    vert_shader := gpu.create_shader_module(gpu_context, SHADER_GUI_ATLAS_VERT) or_return
    defer vk.DestroyShaderModule(gpu_context.device, vert_shader, nil)
    
    frag_shader := gpu.create_shader_module(gpu_context, SHADER_GUI_ATLAS_FRAG) or_return
    defer vk.DestroyShaderModule(gpu_context.device, frag_shader, nil)
    
    // Shader stages
    shader_stages := [?]vk.PipelineShaderStageCreateInfo{
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = {.VERTEX},
            module = vert_shader,
            pName = "main",
        },
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = {.FRAGMENT},
            module = frag_shader,
            pName = "main",
        },
    }
    
    // Vertex input
    vertex_binding := vk.VertexInputBindingDescription{
        binding = 0,
        stride = size_of(GUIVertex),
        inputRate = .VERTEX,
    }
    
    vertex_attributes := [?]vk.VertexInputAttributeDescription{
        { // position
            binding = 0,
            location = 0,
            format = .R32G32_SFLOAT,
            offset = u32(offset_of(GUIVertex, pos)),
        },
        { // uv
            binding = 0,
            location = 1,
            format = .R32G32_SFLOAT,
            offset = u32(offset_of(GUIVertex, uv)),
        },
        { // color
            binding = 0,
            location = 2,
            format = .R32G32B32A32_SFLOAT,
            offset = u32(offset_of(GUIVertex, color)),
        },
    }
    
    vertex_input := vk.PipelineVertexInputStateCreateInfo{
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount = 1,
        pVertexBindingDescriptions = &vertex_binding,
        vertexAttributeDescriptionCount = len(vertex_attributes),
        pVertexAttributeDescriptions = raw_data(vertex_attributes[:]),
    }
    
    // Input assembly
    input_assembly := vk.PipelineInputAssemblyStateCreateInfo{
        sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology = .TRIANGLE_LIST,
    }
    
    // Viewport state
    viewport_state := vk.PipelineViewportStateCreateInfo{
        sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        scissorCount = 1,
    }
    
    // Rasterization
    rasterizer := vk.PipelineRasterizationStateCreateInfo{
        sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        polygonMode = .FILL,
        lineWidth = 1.0,
        cullMode = {},
        frontFace = .COUNTER_CLOCKWISE,
    }
    
    // Multisampling
    multisampling := vk.PipelineMultisampleStateCreateInfo{
        sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        sampleShadingEnable = false,
        rasterizationSamples = {._1},
    }
    
    // Blending
    color_blend_attachment := vk.PipelineColorBlendAttachmentState{
        colorWriteMask = {.R, .G, .B, .A},
        blendEnable = true,
        srcColorBlendFactor = .SRC_ALPHA,
        dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
        colorBlendOp = .ADD,
        srcAlphaBlendFactor = .ONE,
        dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
        alphaBlendOp = .ADD,
    }
    
    color_blending := vk.PipelineColorBlendStateCreateInfo{
        sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        logicOpEnable = false,
        attachmentCount = 1,
        pAttachments = &color_blend_attachment,
    }
    
    // Dynamic state
    dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
    dynamic_state := vk.PipelineDynamicStateCreateInfo{
        sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount = len(dynamic_states),
        pDynamicStates = raw_data(dynamic_states[:]),
    }
    
    // Depth stencil
    depth_stencil := vk.PipelineDepthStencilStateCreateInfo{
        sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        depthTestEnable = false,
        depthWriteEnable = false,
    }
    
    // TODO: Create descriptor set layouts and pipeline layout
    // For now, use the existing bindless system from warehouse
    
    // Create pipeline
    pipeline_info := vk.GraphicsPipelineCreateInfo{
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        stageCount = len(shader_stages),
        pStages = raw_data(shader_stages[:]),
        pVertexInputState = &vertex_input,
        pInputAssemblyState = &input_assembly,
        pViewportState = &viewport_state,
        pRasterizationState = &rasterizer,
        pMultisampleState = &multisampling,
        pColorBlendState = &color_blending,
        pDynamicState = &dynamic_state,
        pDepthStencilState = &depth_stencil,
        layout = 0, // TODO: Set proper pipeline layout
    }
    
    // TODO: Complete pipeline creation
    
    return .SUCCESS
}

create_text_pipeline :: proc(renderer: ^GUIRenderer, gpu_context: ^gpu.GPUContext) -> vk.Result {
    // Similar to atlas pipeline but with text shaders
    return .SUCCESS
}

cleanup_buffers :: proc(renderer: ^GUIRenderer, gpu_context: ^gpu.GPUContext) {
    gpu.data_buffer_deinit(gpu_context, &renderer.vertex_buffer)
    gpu.data_buffer_deinit(gpu_context, &renderer.index_buffer)
    gpu.data_buffer_deinit(gpu_context, &renderer.uniform_buffer)
}

gui_renderer_destroy :: proc(renderer: ^GUIRenderer, gpu_context: ^gpu.GPUContext) {
    cleanup_buffers(renderer, gpu_context)
    
    if renderer.pipeline_atlas != 0 {
        vk.DestroyPipeline(gpu_context.device, renderer.pipeline_atlas, nil)
    }
    if renderer.pipeline_text != 0 {
        vk.DestroyPipeline(gpu_context.device, renderer.pipeline_text, nil)
    }
}

gui_renderer_update_projection :: proc(renderer: ^GUIRenderer, width, height: u32) {
    ortho := linalg.matrix_ortho3d(f32(0), f32(width), f32(height), f32(0), f32(-1), f32(1))
    gpu.data_buffer_write_single(&renderer.uniform_buffer, &ortho)
}

gui_renderer_render :: proc(renderer: ^GUIRenderer, command_buffer: vk.CommandBuffer, 
                          commands: []UICommand, atlas_texture: ^gpu.ImageBuffer, 
                          font_texture: ^gpu.ImageBuffer) {
    if len(commands) == 0 do return
    
    // Build vertex data from commands
    vertices := make([dynamic]GUIVertex, 0, int(renderer.max_vertices), context.temp_allocator)
    indices := make([dynamic]u32, 0, int(renderer.max_indices), context.temp_allocator)
    
    for cmd in commands {
        switch c in cmd {
        case UICommand_Rect:
            // Add a quad for the rectangle
            base_vertex := u32(len(vertices))
            
            append(&vertices, GUIVertex{
                pos = {c.rect.x, c.rect.y},
                uv = {0, 0},
                color = c.color,
            })
            append(&vertices, GUIVertex{
                pos = {c.rect.x + c.rect.z, c.rect.y},
                uv = {1, 0},
                color = c.color,
            })
            append(&vertices, GUIVertex{
                pos = {c.rect.x + c.rect.z, c.rect.y + c.rect.w},
                uv = {1, 1},
                color = c.color,
            })
            append(&vertices, GUIVertex{
                pos = {c.rect.x, c.rect.y + c.rect.w},
                uv = {0, 1},
                color = c.color,
            })
            
            // Add indices for two triangles
            append(&indices, base_vertex + 0, base_vertex + 1, base_vertex + 2)
            append(&indices, base_vertex + 2, base_vertex + 3, base_vertex + 0)
            
        case UICommand_AtlasImage:
            // Add a quad with proper UV coordinates from atlas
            base_vertex := u32(len(vertices))
            
            append(&vertices, GUIVertex{
                pos = {c.rect.x, c.rect.y},
                uv = {c.atlas_region.uv.x, c.atlas_region.uv.y},
                color = c.color,
            })
            append(&vertices, GUIVertex{
                pos = {c.rect.x + c.rect.z, c.rect.y},
                uv = {c.atlas_region.uv.z, c.atlas_region.uv.y},
                color = c.color,
            })
            append(&vertices, GUIVertex{
                pos = {c.rect.x + c.rect.z, c.rect.y + c.rect.w},
                uv = {c.atlas_region.uv.z, c.atlas_region.uv.w},
                color = c.color,
            })
            append(&vertices, GUIVertex{
                pos = {c.rect.x, c.rect.y + c.rect.w},
                uv = {c.atlas_region.uv.x, c.atlas_region.uv.w},
                color = c.color,
            })
            
            append(&indices, base_vertex + 0, base_vertex + 1, base_vertex + 2)
            append(&indices, base_vertex + 2, base_vertex + 3, base_vertex + 0)
            
        case UICommand_Text:
            // Render text character by character
            x := c.position.x
            for ch in c.text {
                if ch >= FONT_FIRST_CHAR && ch <= FONT_LAST_CHAR {
                    uv := get_char_uv(u8(ch))
                    char_width := f32(FONT_CHAR_WIDTH) * (c.font_size / f32(FONT_CHAR_HEIGHT))
                    char_height := c.font_size
                    
                    base_vertex := u32(len(vertices))
                    
                    append(&vertices, GUIVertex{
                        pos = {x, c.position.y},
                        uv = {uv.x, uv.y},
                        color = c.color,
                    })
                    append(&vertices, GUIVertex{
                        pos = {x + char_width, c.position.y},
                        uv = {uv.z, uv.y},
                        color = c.color,
                    })
                    append(&vertices, GUIVertex{
                        pos = {x + char_width, c.position.y + char_height},
                        uv = {uv.z, uv.w},
                        color = c.color,
                    })
                    append(&vertices, GUIVertex{
                        pos = {x, c.position.y + char_height},
                        uv = {uv.x, uv.w},
                        color = c.color,
                    })
                    
                    append(&indices, base_vertex + 0, base_vertex + 1, base_vertex + 2)
                    append(&indices, base_vertex + 2, base_vertex + 3, base_vertex + 0)
                    
                    x += char_width
                }
            }
            
        case UICommand_Clip:
            // TODO: Handle clipping
        }
    }
    
    if len(vertices) == 0 do return
    
    // Upload vertex data
    mem.copy(renderer.vertex_buffer.mapped, raw_data(vertices[:]), len(vertices) * size_of(GUIVertex))
    mem.copy(renderer.index_buffer.mapped, raw_data(indices[:]), len(indices) * size_of(u32))
    
    // TODO: Bind pipeline and descriptor sets
    // TODO: Set viewport and scissor
    // TODO: Draw indexed
    
    // For now, just log what we would render
    log.debugf("GUI render: %d vertices, %d indices", len(vertices), len(indices))
}