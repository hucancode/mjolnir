package mjolnir

import "core:fmt"
import linalg "core:math/linalg"
import "geometry"
import "resource"
import vk "vendor:vulkan"

Material :: struct {
  pipeline_layout:       vk.PipelineLayout,
  pipeline:              vk.Pipeline,
  descriptor_set_layout: vk.DescriptorSetLayout, // For material-specific textures (albedo, metallic, roughness)
  descriptor_set:        vk.DescriptorSet,
  ctx_ref:               ^VulkanContext, // For deinitialization
}

// init_material initializes the material structure.
// The descriptor set and pipeline are created separately.
material_init :: proc(mat: ^Material, ctx: ^VulkanContext) {
  mat.ctx_ref = ctx
}

// deinit_material releases Vulkan resources owned by the material.
material_deinit :: proc(mat: ^Material) {
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
  if mat.descriptor_set_layout != 0 {
    vk.DestroyDescriptorSetLayout(vkd, mat.descriptor_set_layout, nil)
  }
  // Descriptor sets are typically freed when the pool is destroyed,
  // but if allocated individually and not from a material-specific pool,
  // it might need vk.FreeDescriptorSets(vkd, mat.ctx_ref.descriptor_pool, 1, &mat.descriptor_set)
  // For now, assuming pool-based cleanup.

  mat.ctx_ref = nil
}

// init_material_descriptor_set creates the descriptor set layout and allocates the descriptor set for the material's textures.
material_init_descriptor_set :: proc(mat: ^Material) -> vk.Result {
  if mat.ctx_ref == nil {
    return .ERROR_INITIALIZATION_FAILED
  }
  ctx := mat.ctx_ref
  vkd := ctx.vkd
  res: vk.Result

  // Create descriptor set layout with bindings for textures
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {   // Albedo
      binding         = 0,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    }, {   // Metallic
      binding         = 1,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    }, {   // Roughness
      binding         = 2,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    }
  }

  layout_info := vk.DescriptorSetLayoutCreateInfo {
    sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount = len(bindings),
    pBindings    = raw_data(bindings[:]),
  }
  vk.CreateDescriptorSetLayout(
    vkd,
    &layout_info,
    nil,
    &mat.descriptor_set_layout,
  ) or_return

  // Allocate descriptor set
  alloc_info := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = ctx.descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &mat.descriptor_set_layout,
  }
  vk.AllocateDescriptorSets(vkd, &alloc_info, &mat.descriptor_set) or_return
  return .SUCCESS
}

material_update_textures :: proc(
  mat: ^Material,
  albedo: ^Texture,
  metallic: ^Texture,
  roughness: ^Texture,
) {
  if mat.ctx_ref == nil || mat.descriptor_set == 0 {
    return
  }
  vkd := mat.ctx_ref.vkd

  image_infos := [?]vk.DescriptorImageInfo {
    {   // Albedo
      sampler     = albedo.sampler,
      imageView   = albedo.buffer.view, // Assumes Texture.buffer is ImageBuffer with a view
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }, {   // Metallic
      sampler     = metallic.sampler,
      imageView   = metallic.buffer.view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }, {   // Roughness
      sampler     = roughness.sampler,
      imageView   = roughness.buffer.view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }
  }

  writes := [?]vk.WriteDescriptorSet {
    {   // Albedo
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = mat.descriptor_set,
      dstBinding      = 0,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo      = &image_infos[0],
    }, {   // Metallic
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = mat.descriptor_set,
      dstBinding      = 1,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo      = &image_infos[1],
    }, {   // Roughness
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = mat.descriptor_set,
      dstBinding      = 2,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo      = &image_infos[2],
    }
  }

  fmt.printfln("Updating material descriptor set: %d, with texture", mat.descriptor_set, image_infos)
  vk.UpdateDescriptorSets(vkd, len(writes), raw_data(writes[:]), 0, nil)
}

// build_material_pipeline creates the graphics pipeline for this material.
// Requires renderer-specific info like the main pass descriptor set layout and color format.
material_build :: proc(
  mat: ^Material,
  vertex_code: []u8,
  fragment_code: []u8,
  main_pass_ds_layout: vk.DescriptorSetLayout,
  target_color_format: vk.Format,
  target_depth_format: vk.Format,
) -> vk.Result {
  if mat.ctx_ref == nil || mat.descriptor_set_layout == 0 {
    return .ERROR_INITIALIZATION_FAILED
  }
  ctx := mat.ctx_ref
  vkd := ctx.vkd

  vert_shader_module := create_shader_module(ctx, vertex_code) or_return
  defer vk.DestroyShaderModule(vkd, vert_shader_module, nil)

  frag_shader_module := create_shader_module(ctx, fragment_code) or_return
  defer vk.DestroyShaderModule(vkd, frag_shader_module, nil)

  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_shader_module,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_shader_module,
      pName = "main",
    },
  }

  dynamic_states_values := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}

  dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = u32(len(dynamic_states_values)),
    pDynamicStates    = raw_data(dynamic_states_values[:]),
  }

  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(geometry.VERTEX_BINDING_DESCRIPTION),
    pVertexBindingDescriptions      = raw_data(
      geometry.VERTEX_BINDING_DESCRIPTION[:],
    ),
    vertexAttributeDescriptionCount = len(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS,
    ),
    pVertexAttributeDescriptions    = raw_data(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
    ),
  }

  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology               = .TRIANGLE_LIST,
    primitiveRestartEnable = false,
  }

  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1, // Dynamic
    scissorCount  = 1, // Dynamic
  }

  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    depthClampEnable        = false,
    rasterizerDiscardEnable = false,
    polygonMode             = .FILL,
    cullMode                = {.BACK},
    frontFace               = .COUNTER_CLOCKWISE,
    depthBiasEnable         = false,
    lineWidth               = 1.0,
  }

  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
    sampleShadingEnable  = false,
    minSampleShading     = 1.0,
  }

  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    blendEnable         = false,
    colorWriteMask      = {.R, .G, .B, .A},
    srcColorBlendFactor = .ONE,
    dstColorBlendFactor = .ZERO,
    colorBlendOp        = .ADD,
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ZERO,
    alphaBlendOp        = .ADD,
  }

  blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    logicOpEnable   = false,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }

  // Descriptor set layouts: [SceneGlobal, MaterialSpecific]
  set_layouts_arr := [?]vk.DescriptorSetLayout {
    main_pass_ds_layout, // From Renderer (e.g., camera, lights)
    mat.descriptor_set_layout, // For this material's textures
  }

  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX},
    offset     = 0,
    size       = size_of(linalg.Matrix4f32), // For model matrix
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
    &mat.pipeline_layout,
  ) or_return

  depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
    sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable       = true,
    depthWriteEnable      = true,
    depthCompareOp        = .LESS,
    depthBoundsTestEnable = false,
    stencilTestEnable     = false,
  }

  color_formats := [?]vk.Format{target_color_format}
  rendering_info_khr := vk.PipelineRenderingCreateInfoKHR {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
    depthAttachmentFormat   = target_depth_format,
  }

  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &rendering_info_khr,
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
    layout              = mat.pipeline_layout,
  }

  pipelines_to_create: [1]vk.GraphicsPipelineCreateInfo = {pipeline_info}
  vk.CreateGraphicsPipelines(
    vkd,
    0,
    len(pipelines_to_create),
    raw_data(pipelines_to_create[:]),
    nil,
    &mat.pipeline,
  ) or_return
  return .SUCCESS
}

SHADER_PBR_VERT :: #load("shader/pbr/vert.spv")
SHADER_PBR_FRAG :: #load("shader/pbr/frag.spv")

// Procedural API for creating a PBR material
create_material :: proc(
  engine: ^Engine,
  albedo: resource.Handle,
  metallic: resource.Handle,
  roughness: resource.Handle,
) -> (handle: resource.Handle, mat: ^Material, ret: vk.Result) {
  fmt.printfln("Creating PBR material")
  handle, mat = resource.alloc(&engine.materials)
  material_init(mat, &engine.vk_ctx)
  material_init_descriptor_set(mat) or_return
  albedo_tex := resource.get(&engine.textures, albedo)
  metallic_tex := resource.get(&engine.textures, metallic)
  roughness_tex := resource.get(&engine.textures, roughness)
  if albedo_tex != nil && metallic_tex != nil && roughness_tex != nil {
    material_update_textures(mat, albedo_tex, metallic_tex, roughness_tex)
  }
  material_build(
    mat,
    SHADER_PBR_VERT,
    SHADER_PBR_FRAG,
    engine.renderer.main_pass_descriptor_set_layout,
    engine.renderer.format.format,
    engine.renderer.depth_buffer.format,
  )
  ret = .SUCCESS
  return
}