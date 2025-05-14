package mjolnir

import "base:runtime"
import linalg "core:math/linalg"
import "geometry"
import "resource"
import vk "vendor:vulkan"

SHADER_SKINNED_PBR_VERT :: #load("shader/skinned_pbr/vert.spv")
SHADER_SKINNED_PBR_FRAG :: #load("shader/skinned_pbr/frag.spv")

SkinnedMaterial :: struct {
  pipeline_layout:       vk.PipelineLayout,
  pipeline:              vk.Pipeline,
  descriptor_set_layout: vk.DescriptorSetLayout, // For textures + bone buffer
  descriptor_set:        vk.DescriptorSet,
  ctx_ref:               ^VulkanContext,
}

skinned_material_init :: proc(mat: ^SkinnedMaterial, ctx: ^VulkanContext) {
  mat.ctx_ref = ctx
}

// deinit_skinned_material releases Vulkan resources.
skinned_material_deinit :: proc(mat: ^SkinnedMaterial) {
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
  // Descriptor set is assumed to be freed by the pool
  mat.ctx_ref = nil
}

// init_skinned_material_descriptor_set creates the layout and allocates the set.
skinned_material_init_descriptor_set :: proc(
  mat: ^SkinnedMaterial,
) -> vk.Result {
  if mat.ctx_ref == nil {
    return .ERROR_INITIALIZATION_FAILED
  }
  ctx := mat.ctx_ref
  vkd := ctx.vkd
  res: vk.Result

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
    }, {   // Bones
      binding         = 3,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags      = {.VERTEX},
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

  alloc_info := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = ctx.descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &mat.descriptor_set_layout,
  }
  vk.AllocateDescriptorSets(vkd, &alloc_info, &mat.descriptor_set) or_return
  return .SUCCESS
}

// update_skinned_material_textures updates texture descriptors.
skinned_material_update_textures :: proc(
  mat: ^SkinnedMaterial,
  albedo: ^Texture,
  metallic: ^Texture,
  roughness: ^Texture,
) {
  if mat.ctx_ref == nil || mat.descriptor_set == 0 {
    return
  }
  vkd := mat.ctx_ref.vkd

  image_infos := [?]vk.DescriptorImageInfo {
    {
      sampler = albedo.sampler,
      imageView = albedo.buffer.view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
    {
      sampler = metallic.sampler,
      imageView = metallic.buffer.view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
    {
      sampler = roughness.sampler,
      imageView = roughness.buffer.view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
  }

  writes := [?]vk.WriteDescriptorSet {
    {
      dstSet = mat.descriptor_set,
      dstBinding = 0,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[0],
    },
    {
      dstSet = mat.descriptor_set,
      dstBinding = 1,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[1],
    },
    {
      dstSet = mat.descriptor_set,
      dstBinding = 2,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[2],
    },
  }

  vk.UpdateDescriptorSets(vkd, len(writes), raw_data(writes[:]), 0, nil)
}

// update_skinned_material_bone_buffer updates the bone buffer descriptor.
skinned_material_update_bone_buffer :: proc(
  mat: ^SkinnedMaterial,
  buffer: vk.Buffer,
  size: vk.DeviceSize,
) {
  if mat.ctx_ref == nil || mat.descriptor_set == 0 {
    return
  }
  vkd := mat.ctx_ref.vkd

  buffer_info := vk.DescriptorBufferInfo {
    buffer = buffer,
    offset = 0,
    range  = size,
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = mat.descriptor_set,
    dstBinding      = 3, // Bone buffer binding
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(vkd, 1, &write, 0, nil)
}

skinned_material_build :: proc(
  mat: ^SkinnedMaterial,
  vertex_code: []u8,
  fragment_code: []u8,
  main_pass_ds_layout: vk.DescriptorSetLayout,
  target_color_format: vk.Format,
  target_depth_format: vk.Format,
) -> (
  ret: vk.Result,
) {
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
    vertexBindingDescriptionCount   = len(
      geometry.SKINNED_VERTEX_BINDING_DESCRIPTION,
    ),
    pVertexBindingDescriptions      = raw_data(
      geometry.SKINNED_VERTEX_BINDING_DESCRIPTION[:],
    ),
    vertexAttributeDescriptionCount = len(
      geometry.SKINNED_VERTEX_ATTRIBUTE_DESCRIPTIONS,
    ),
    pVertexAttributeDescriptions    = raw_data(
      geometry.SKINNED_VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
    ),
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
    cullMode    = {.BACK},
    frontFace   = .COUNTER_CLOCKWISE,
    lineWidth   = 1.0,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    colorWriteMask = {.R, .G, .B, .A},
  }
  blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }

  set_layouts_arr := [?]vk.DescriptorSetLayout {
    main_pass_ds_layout,
    mat.descriptor_set_layout,
  }
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX},
    offset     = 0,
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
    &mat.pipeline_layout,
  ) or_return

  depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = true,
    depthCompareOp   = .LESS,
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
  pipelines_to_create := [?]vk.GraphicsPipelineCreateInfo{pipeline_info}
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

// Procedural API for creating a Skinned PBR material
create_skinned_material :: proc(
  engine: ^Engine,
  albedo: resource.Handle,
  metallic: resource.Handle,
  roughness: resource.Handle,
) -> (handle: resource.Handle, mat: ^SkinnedMaterial, ret: vk.Result) {
  handle, mat = resource.alloc(&engine.skinned_materials)
  skinned_material_init(mat, &engine.vk_ctx)
  skinned_material_init_descriptor_set(mat) or_return
  albedo_tex := resource.get(&engine.textures, albedo)
  metallic_tex := resource.get(&engine.textures, metallic)
  roughness_tex := resource.get(&engine.textures, roughness)
  if albedo_tex != nil && metallic_tex != nil && roughness_tex != nil {
    skinned_material_update_textures(
      mat,
      albedo_tex,
      metallic_tex,
      roughness_tex,
    )
  }
  skinned_material_build(
    mat,
    SHADER_SKINNED_PBR_VERT,
    SHADER_SKINNED_PBR_FRAG,
    engine.renderer.main_pass_descriptor_set_layout,
    engine.renderer.format.format,
    engine.renderer.depth_buffer.format,
  )
  ret = .SUCCESS
  return
}
