package mjolnir

import "base:runtime"
import linalg "core:math/linalg"
import "geometry"
import "resource"
import vk "vendor:vulkan"

SHADER_MICROUI_VERT :: #load("shader/microui/vert.spv")
SHADER_MICROUI_FRAG :: #load("shader/microui/frag.spv")

MicroUIMaterial :: struct {
  projection_layout: vk.DescriptorSetLayout,
  projection_descriptor_set: vk.DescriptorSet,
  texture_layout: vk.DescriptorSetLayout,
  texture_descriptor_set: vk.DescriptorSet,
  pipeline_layout: vk.PipelineLayout,
  pipeline:        vk.Pipeline,
  ctx_ref:         ^VulkanContext,
}

// 1. Create MicroUI material (pipeline, layout, shaders)
microui_material_init :: proc(mat: ^MicroUIMaterial, ctx: ^VulkanContext, color_format: vk.Format) -> vk.Result {
    mat.ctx_ref = ctx
    vkd := ctx.vkd

    vert_shader_module := create_shader_module(ctx, SHADER_MICROUI_VERT) or_return
    defer vk.DestroyShaderModule(vkd, vert_shader_module, nil)
    frag_shader_module := create_shader_module(ctx, SHADER_MICROUI_FRAG) or_return
    defer vk.DestroyShaderModule(vkd, frag_shader_module, nil)

    shader_stages := [?]vk.PipelineShaderStageCreateInfo {
        {
          sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
          stage = {.VERTEX},
          module = vert_shader_module,
          pName = "main"
        }, {
          sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
          stage = {.FRAGMENT},
          module = frag_shader_module,
          pName = "main"
        },
    }

    dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
    dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
        sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount = u32(len(dynamic_states)),
        pDynamicStates = raw_data(dynamic_states[:]),
    }

    vertex_binding := vk.VertexInputBindingDescription {
        binding = 0,
        stride = size_of(Vertex2D),
        inputRate = .VERTEX,
    }
    vertex_attributes := [?]vk.VertexInputAttributeDescription {
        { // position
          binding = 0,
          location = 0,
          format = .R32G32_SFLOAT,
          offset = u32(offset_of(Vertex2D, pos))
        }, { // uv
          binding = 0,
          location = 1,
          format = .R32G32_SFLOAT,
          offset = u32(offset_of(Vertex2D, uv))
        }, { // color
          binding = 0,
          location = 2,
          format = .R8G8B8A8_UNORM,
          offset = u32(offset_of(Vertex2D, color))
        },
    }
    vertex_input := vk.PipelineVertexInputStateCreateInfo {
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount = 1,
        pVertexBindingDescriptions = &vertex_binding,
        vertexAttributeDescriptionCount = len(vertex_attributes),
        pVertexAttributeDescriptions = raw_data(vertex_attributes[:]),
    }

    input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
        sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology = .TRIANGLE_LIST,
    }
    viewport := vk.Viewport{
        width = f32(ctx.surface_capabilities.currentExtent.width),
        height = f32(ctx.surface_capabilities.currentExtent.height),
        minDepth = 0,
        maxDepth = 1,
    }
    scissor := vk.Rect2D{
        extent = {
            width = ctx.surface_capabilities.currentExtent.width,
            height = ctx.surface_capabilities.currentExtent.height,
        },
    }
    viewport_state := vk.PipelineViewportStateCreateInfo {
        sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        pViewports = &viewport,
        scissorCount = 1,
        pScissors = &scissor,
    }
    rasterizer := vk.PipelineRasterizationStateCreateInfo {
        sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        polygonMode = .FILL,
        lineWidth = 1.0,
    }
    multisampling := vk.PipelineMultisampleStateCreateInfo {
        sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        rasterizationSamples = {._1},
    }
    color_blend_attachment := vk.PipelineColorBlendAttachmentState {
        blendEnable = true,
        srcColorBlendFactor = .SRC_ALPHA,
        dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
        colorBlendOp = .ADD,
        srcAlphaBlendFactor = .SRC_ALPHA,
        dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
        alphaBlendOp = .ADD,
        colorWriteMask = {.R, .G, .B, .A},
    }
    color_blending := vk.PipelineColorBlendStateCreateInfo {
        sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        attachmentCount = 1,
        pAttachments = &color_blend_attachment,
    }
    projection_layout_info := vk.DescriptorSetLayoutCreateInfo {
      sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = 1,
      pBindings    = &vk.DescriptorSetLayoutBinding {
          binding         = 0,
          descriptorType  = .UNIFORM_BUFFER,
          descriptorCount = 1,
          stageFlags      = {.VERTEX},
      },
    }
    vk.CreateDescriptorSetLayout(vkd, &projection_layout_info, nil, &mat.projection_layout) or_return
    projection_alloc_info := vk.DescriptorSetAllocateInfo {
      sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool     = ctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts        = &mat.projection_layout,
    }
    vk.AllocateDescriptorSets(vkd, &projection_alloc_info, &mat.projection_descriptor_set) or_return
    vk.CreateDescriptorSetLayout(vkd, &vk.DescriptorSetLayoutCreateInfo {
          sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
          bindingCount = 1,
          pBindings    = &vk.DescriptorSetLayoutBinding {
              binding         = 0,
              descriptorType  = .COMBINED_IMAGE_SAMPLER,
              descriptorCount = 1,
              stageFlags      = {.FRAGMENT},
          },
        }, nil, &mat.texture_layout) or_return
    vk.AllocateDescriptorSets(vkd, &vk.DescriptorSetAllocateInfo {
          sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
          descriptorPool     = ctx.descriptor_pool,
          descriptorSetCount = 1,
          pSetLayouts        = &mat.texture_layout,
        }, &mat.texture_descriptor_set) or_return
    set_layouts := [?]vk.DescriptorSetLayout{
        mat.projection_layout,
        mat.texture_layout,
    }
    pipeline_layout_info := vk.PipelineLayoutCreateInfo {
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = len(set_layouts),
        pSetLayouts = raw_data(set_layouts[:]),
    }
    vk.CreatePipelineLayout(vkd, &pipeline_layout_info, nil, &mat.pipeline_layout) or_return
    color_formats := [?]vk.Format { color_format }
    rendering_info_khr := vk.PipelineRenderingCreateInfoKHR {
        sType = .PIPELINE_RENDERING_CREATE_INFO_KHR,
        colorAttachmentCount = len(color_formats),
        pColorAttachmentFormats = raw_data(color_formats[:]),
    }
    pipeline_info := vk.GraphicsPipelineCreateInfo {
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        pNext = &rendering_info_khr,
        stageCount = len(shader_stages),
        pStages = raw_data(shader_stages[:]),
        pVertexInputState = &vertex_input,
        pInputAssemblyState = &input_assembly,
        pViewportState = &viewport_state,
        pRasterizationState = &rasterizer,
        pMultisampleState = &multisampling,
        pColorBlendState = &color_blending,
        pDynamicState = &dynamic_state_info,
        layout = mat.pipeline_layout,
    }
    vk.CreateGraphicsPipelines(vkd, 0, 1, &pipeline_info, nil, &mat.pipeline) or_return
    return .SUCCESS
}
