package mjolnir

import "base:runtime"
import linalg "core:math/linalg"
import "geometry"
import "resource"
import vk "vendor:vulkan"

SHADER_SHADOW_VERT :: #load("shader/shadow/vert.spv")

ShadowMaterial :: struct {
  pipeline_layout: vk.PipelineLayout,
  pipeline:        vk.Pipeline,
  ctx_ref:         ^VulkanContext, // For deinitialization
}

// init_shadow_material initializes the material structure.
shadow_material_init :: proc(mat: ^ShadowMaterial, ctx: ^VulkanContext) {
  mat.ctx_ref = ctx
}

// deinit_shadow_material releases Vulkan resources owned by the shadow material.
shadow_material_deinit :: proc(mat: ^ShadowMaterial) {
  if mat.ctx_ref == nil {
    return // Not initialized
  }
  vkd := mat.ctx_ref.vkd

  if mat.pipeline != 0 {
    vk.DestroyPipeline(vkd, mat.pipeline, nil)
  }
  if mat.pipeline_layout != 0 {
    vk.DestroyPipelineLayout(vkd, mat.pipeline_layout, nil)
  }
  // ShadowMaterial doesn't own a descriptor set layout in this setup
  mat.ctx_ref = nil
}

// build_shadow_pipeline creates the graphics pipeline for shadow map rendering.
// Requires renderer-specific info like the shadow pass descriptor set layout and depth format.
shadow_material_build :: proc(
  self: ^ShadowMaterial,
  shadow_vertex_code: []u8,
  shadow_pass_ds_layout: vk.DescriptorSetLayout,
  shadow_map_depth_format: vk.Format,
) -> vk.Result {
  if self.ctx_ref == nil {
    return .ERROR_INITIALIZATION_FAILED
  }
  ctx := self.ctx_ref
  vkd := ctx.vkd

  vert_shader_module := create_shader_module(ctx, shadow_vertex_code) or_return
  defer vk.DestroyShaderModule(vkd, vert_shader_module, nil)

  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_shader_module,
      pName = "main",
    },
  }

  dynamic_states_values := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}

  dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = u32(len(dynamic_states_values)),
    pDynamicStates    = raw_data(dynamic_states_values[:]),
  }

  vertex_binding_description := [?]vk.VertexInputBindingDescription {
    {binding = 0, stride = size_of(linalg.Vector4f32), inputRate = .VERTEX},
  }
  vertex_attribute_descriptions := [?]vk.VertexInputAttributeDescription {
    {   // Position
      binding  = 0,
      location = 0,
      format   = .R32G32B32A32_SFLOAT,
      offset   = 0,
    },
  }
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(vertex_binding_description),
    pVertexBindingDescriptions      = raw_data(vertex_binding_description[:]),
    vertexAttributeDescriptionCount = len(vertex_attribute_descriptions),
    pVertexAttributeDescriptions    = raw_data(
      vertex_attribute_descriptions[:],
    ),
  }

  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology               = .TRIANGLE_LIST,
    primitiveRestartEnable = false,
  }

  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }

  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    depthClampEnable        = false,
    rasterizerDiscardEnable = false,
    polygonMode             = .FILL,
    cullMode                = {.BACK},
    frontFace               = .COUNTER_CLOCKWISE,
    depthBiasEnable         = true,
    depthBiasConstantFactor = 1.25,
    depthBiasClamp          = 0.0,
    depthBiasSlopeFactor    = 1.75,
    lineWidth               = 1.0,
  }

  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
    sampleShadingEnable  = false,
  }

  blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    logicOpEnable   = false,
    attachmentCount = 0,
  }

  set_layouts_arr := [?]vk.DescriptorSetLayout{shadow_pass_ds_layout}

  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX},
    size       = size_of(linalg.Matrix4f32),
  }

  pipeline_layout_info := vk.PipelineLayoutCreateInfo {
    sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount         = len(set_layouts_arr),
    pSetLayouts            = raw_data(set_layouts_arr[:]),
    pushConstantRangeCount = 1,
    pPushConstantRanges    = &push_constant_range,
  }
  vk.CreatePipelineLayout(
    vkd,
    &pipeline_layout_info,
    nil,
    &self.pipeline_layout,
  ) or_return

  depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
    sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable       = true,
    depthWriteEnable      = true,
    depthCompareOp        = .LESS, // Or .LESS_OR_EQUAL
    depthBoundsTestEnable = false,
    stencilTestEnable     = false,
  }

  rendering_info_khr := vk.PipelineRenderingCreateInfoKHR {
    sType                 = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    depthAttachmentFormat = .D32_SFLOAT,
  }

  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &rendering_info_khr, // For dynamic rendering
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pColorBlendState    = &blending,
    pDynamicState       = &dynamic_state_info,
    pDepthStencilState  = &depth_stencil_state,
    layout              = self.pipeline_layout,
  }

  pipelines_to_create := [?]vk.GraphicsPipelineCreateInfo{pipeline_info}
  vk.CreateGraphicsPipelines(
    vkd,
    0,
    len(pipelines_to_create),
    raw_data(pipelines_to_create[:]),
    nil,
    &self.pipeline,
  ) or_return
  return .SUCCESS
}

// Procedural API for creating a PBR material
create_shadow_material :: proc(renderer: ^Renderer) -> ShadowMaterial {
  mat: ShadowMaterial
  shadow_material_init(&mat, renderer.ctx)
  shadow_material_build(
    &mat,
    SHADER_SHADOW_VERT,
    renderer.shadow_pass_descriptor_set_layout,
    .D32_SFLOAT,
  )
  return mat
}
