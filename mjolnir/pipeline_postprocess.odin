package mjolnir

import "core:log"
import vk "vendor:vulkan"

PostProcessEffectType :: enum {
  GRAYSCALE,
  TONEMAP,
  BLUR,
  BLOOM,
  OUTLINE,
}

GrayscaleEffect :: struct {
  strength: f32,
}

ToneMapEffect :: struct {
  exposure: f32,
  gamma:    f32,
}

BlurEffect :: struct {
  radius: f32,
}

BloomEffect :: struct {
  threshold:   f32,
  intensity:   f32,
  blur_radius: f32,
}

OutlineEffect :: struct {
  line_width: f32,
  color:      f32,
}

PostprocessEffect :: struct {
  effect_type:    PostProcessEffectType,
  effect:         union {
    GrayscaleEffect,
    ToneMapEffect,
    BlurEffect,
    BloomEffect,
    OutlineEffect,
  },
  pipeline:       vk.Pipeline,
  layout:         vk.PipelineLayout,
  descriptor_set: vk.DescriptorSet,
}

PostprocessStack :: [dynamic]PostprocessEffect

PostprocessPipeline :: struct {
  layout:                vk.PipelineLayout,
  pipeline:              vk.Pipeline,
  descriptor_set_layout: vk.DescriptorSetLayout,
}

SHADER_POSTPROCESS_VERT :: #load("shader/postprocess/vert.spv")
SHADER_BLOOM_FRAG :: #load("shader/bloom/frag.spv")
SHADER_BLUR_FRAG :: #load("shader/blur/frag.spv")
SHADER_GRAYSCALE_FRAG :: #load("shader/grayscale/frag.spv")
SHADER_TONEMAP_FRAG :: #load("shader/tonemap/frag.spv")
SHADER_OUTLINE_FRAG :: #load("shader/outline/frag.spv")

g_postprocess_pipelines: [len(PostProcessEffectType)]PostprocessPipeline

postprocess_pipeline_init_all :: proc(color_format: vk.Format) -> vk.Result {
  base_handle: vk.Pipeline = 0
  for effect_type, i in PostProcessEffectType {
    pipeline := &g_postprocess_pipelines[i]
    vert_module := create_shader_module(SHADER_POSTPROCESS_VERT) or_return
    defer vk.DestroyShaderModule(g_device, vert_module, nil)
    frag_module: vk.ShaderModule
    switch effect_type {
    case .BLOOM:
      frag_module = create_shader_module(SHADER_BLOOM_FRAG) or_return
    case .BLUR:
      frag_module = create_shader_module(SHADER_BLUR_FRAG) or_return
    case .GRAYSCALE:
      frag_module = create_shader_module(SHADER_GRAYSCALE_FRAG) or_return
    case .TONEMAP:
      frag_module = create_shader_module(SHADER_TONEMAP_FRAG) or_return
    case .OUTLINE:
      frag_module = create_shader_module(SHADER_OUTLINE_FRAG) or_return
    }
    defer vk.DestroyShaderModule(g_device, frag_module, nil)

    // Descriptor set layout: sampled input image (binding 0)
    bindings := [?]vk.DescriptorSetLayoutBinding {
      {
        binding = 0,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = 1,
        stageFlags = {.FRAGMENT},
      },
      // Add more bindings for effect-specific uniforms if needed
    }
    layout_info := vk.DescriptorSetLayoutCreateInfo {
      sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings    = raw_data(bindings[:]),
    }
    vk.CreateDescriptorSetLayout(
      g_device,
      &layout_info,
      nil,
      &pipeline.descriptor_set_layout,
    ) or_return

    // Pipeline layout
    set_layouts := [?]vk.DescriptorSetLayout{pipeline.descriptor_set_layout}
    pipeline_layout_info := vk.PipelineLayoutCreateInfo {
      sType          = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(set_layouts),
      pSetLayouts    = raw_data(set_layouts[:]),
    }
    vk.CreatePipelineLayout(
      g_device,
      &pipeline_layout_info,
      nil,
      &pipeline.layout,
    ) or_return

    // Vertex input: fullscreen quad (no vertex buffer, use vertex shader to generate)
    vertex_input := vk.PipelineVertexInputStateCreateInfo {
      sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    }
    input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
      sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
      topology = .TRIANGLE_LIST,
    }
    viewport_state := vk.PipelineViewportStateCreateInfo {
      sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
      viewportCount = 1,
      scissorCount  = 1,
    }
    rasterizer := vk.PipelineRasterizationStateCreateInfo {
      sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
      polygonMode = .FILL,
      lineWidth   = 1.0,
    }
    multisampling := vk.PipelineMultisampleStateCreateInfo {
      sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
      rasterizationSamples = {._1},
    }
    color_blend_attachment := vk.PipelineColorBlendAttachmentState {
      colorWriteMask = {.R, .G, .B, .A},
      blendEnable    = false,
    }
    color_blending := vk.PipelineColorBlendStateCreateInfo {
      sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
      attachmentCount = 1,
      pAttachments    = &color_blend_attachment,
    }
    depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
      sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
      depthTestEnable  = false,
      depthWriteEnable = false,
    }
    color_formats := [?]vk.Format{color_format}
    rendering_info_khr := vk.PipelineRenderingCreateInfoKHR {
      sType                   = .PIPELINE_RENDERING_CREATE_INFO_KHR,
      colorAttachmentCount    = len(color_formats),
      pColorAttachmentFormats = raw_data(color_formats[:]),
    }

    flags: vk.PipelineCreateFlags =
      {.ALLOW_DERIVATIVES} if i == 0 else {.DERIVATIVE}

    shader_stages := [?]vk.PipelineShaderStageCreateInfo {
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.VERTEX},
        module = vert_module,
        pName = "main",
      },
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.FRAGMENT},
        module = frag_module,
        pName = "main",
      },
    }

    pipeline_info := vk.GraphicsPipelineCreateInfo {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      pNext               = &rendering_info_khr,
      stageCount          = len(shader_stages),
      pStages             = raw_data(shader_stages[:]),
      pVertexInputState   = &vertex_input,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pColorBlendState    = &color_blending,
      pDepthStencilState  = &depth_stencil_state,
      layout              = pipeline.layout,
      flags               = flags,
      // based on pipline 0
      basePipelineHandle  = g_postprocess_pipelines[0].pipeline,
      basePipelineIndex   = 0,
    }
    vk.CreateGraphicsPipelines(
      g_device,
      0,
      1,
      &pipeline_info,
      nil,
      &pipeline.pipeline,
    ) or_return
  }
  return .SUCCESS
}

postprocess_pipeline_deinit_all :: proc() {
  for &pipeline in g_postprocess_pipelines {
    postprocess_pipeline_deinit(&pipeline)
  }
}

postprocess_pipeline_deinit :: proc(pipeline: ^PostprocessPipeline) {
  vk.DestroyPipeline(g_device, pipeline.pipeline, nil)
  pipeline.pipeline = 0
  vk.DestroyPipelineLayout(g_device, pipeline.layout, nil)
  pipeline.layout = 0
  vk.DestroyDescriptorSetLayout(g_device, pipeline.descriptor_set_layout, nil)
  pipeline.descriptor_set_layout = 0
}
