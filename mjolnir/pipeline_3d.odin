package mjolnir

import "core:fmt"
import linalg "core:math/linalg"
import "geometry"
import "resource"
import vk "vendor:vulkan"

// Feature bitmask
UBER_SKINNED :: 1 << 0
UBER_TEXTURED :: 1 << 1
UBER_LIT :: 1 << 2
UBER_RECEIVE_SHADOW :: 1 << 3
SHADER_OPTION_COUNT :: 4
SHADER_VARIANT_COUNT :: 1 << SHADER_OPTION_COUNT

// Specialization constant struct (must match shader)
ShaderConfig :: struct {
  is_skinned:         b32,
  has_texture:        b32,
  is_lit:             b32,
  can_receive_shadow: b32,
}

// UberMaterial descriptor set layout: [albedo, metallic, roughness, bones (optional)]
UberMaterial :: struct {
  descriptor_set: vk.DescriptorSet,
  features:       u32,
  ctx_ref:        ^VulkanContext,
}
uber_main_pass_descriptor_set_layout: vk.DescriptorSetLayout
// Maps for layouts and pipelines
uber_material_descriptor_set_layouts: [SHADER_VARIANT_COUNT]vk.DescriptorSetLayout
uber_pipeline_layouts: [SHADER_VARIANT_COUNT]vk.PipelineLayout
uber_pipelines: [SHADER_VARIANT_COUNT]vk.Pipeline

// Shader binaries (should point to your uber shader)
SHADER_UBER_VERT :: #load("shader/uber/vert.spv")
SHADER_UBER_FRAG :: #load("shader/uber/frag.spv")

// Helper to get or create descriptor set layout for a feature set
get_material_descriptor_set_layout :: proc(
  ctx: ^VulkanContext,
  features: u32,
) -> vk.DescriptorSetLayout {
  return uber_material_descriptor_set_layouts[features]
}

// Helper to get or create pipeline layout for a feature set
get_pipeline_layout :: proc(
  ctx: ^VulkanContext,
  features: u32,
) -> vk.PipelineLayout {
  return uber_pipeline_layouts[features]
}

// Descriptor set layout creation (superset: textures + bones)
material_init_descriptor_set_layout :: proc(
  mat: ^UberMaterial,
  ctx: ^VulkanContext,
) -> vk.Result {
  layout := get_material_descriptor_set_layout(ctx, mat.features)
  alloc_info := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = ctx.descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &layout,
  }
  vk.AllocateDescriptorSets(
    ctx.vkd,
    &alloc_info,
    &mat.descriptor_set,
  ) or_return
  return .SUCCESS
}

// Update textures (albedo, metallic, roughness)
material_uber_update_textures :: proc(
  mat: ^UberMaterial,
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
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = mat.descriptor_set,
      dstBinding = 0,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[0],
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = mat.descriptor_set,
      dstBinding = 1,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[1],
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = mat.descriptor_set,
      dstBinding = 2,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[2],
    },
  }

  vk.UpdateDescriptorSets(vkd, len(writes), raw_data(writes[:]), 0, nil)
}

// Update bone buffer (for skinned meshes)
material_uber_update_bone_buffer :: proc(
  mat: ^UberMaterial,
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

create_all_uber_pipelines :: proc(
  ctx: ^VulkanContext,
  target_color_format: vk.Format,
  target_depth_format: vk.Format,
) -> vk.Result {
  bindings_main := [?]vk.DescriptorSetLayoutBinding {
    {   // Scene Uniforms (view, proj, time)
      binding         = 0,
      descriptorType  = .UNIFORM_BUFFER,
      descriptorCount = 1,
      stageFlags      = {.VERTEX, .FRAGMENT},
    },
    {   // Light Uniforms
      binding         = 1,
      descriptorType  = .UNIFORM_BUFFER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    },
    {   // Shadow Samplers
      binding         = 2,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = MAX_LIGHTS,
      stageFlags      = {.FRAGMENT},
    },
  }
  layout_info_main := vk.DescriptorSetLayoutCreateInfo {
    sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount = len(bindings_main),
    pBindings    = raw_data(bindings_main[:]),
  }
  vk.CreateDescriptorSetLayout(
    ctx.vkd,
    &layout_info_main,
    nil,
    &uber_main_pass_descriptor_set_layout,
  ) or_return

  pipeline_infos: [SHADER_VARIANT_COUNT]vk.GraphicsPipelineCreateInfo
  spec_infos: [SHADER_VARIANT_COUNT]vk.SpecializationInfo
  configs: [SHADER_VARIANT_COUNT]ShaderConfig
  entries: [SHADER_VARIANT_COUNT][SHADER_OPTION_COUNT]vk.SpecializationMapEntry
  shader_stages_arr: [SHADER_VARIANT_COUNT][2]vk.PipelineShaderStageCreateInfo

  vert_module := create_shader_module(ctx, SHADER_UBER_VERT) or_return
  defer vk.DestroyShaderModule(ctx.vkd, vert_module, nil)
  frag_module := create_shader_module(ctx, SHADER_UBER_FRAG) or_return
  defer vk.DestroyShaderModule(ctx.vkd, frag_module, nil)

  dynamic_states_values := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = u32(len(dynamic_states_values)),
    pDynamicStates    = raw_data(dynamic_states_values[:]),
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
    depthAttachmentFormat   = .D32_SFLOAT,
  }
  for features in 0 ..< SHADER_VARIANT_COUNT {
    configs[features] = ShaderConfig {
      is_skinned         = (features & UBER_SKINNED) != 0,
      has_texture        = (features & UBER_TEXTURED) != 0,
      is_lit             = (features & UBER_LIT) != 0,
      can_receive_shadow = (features & UBER_RECEIVE_SHADOW) != 0,
    }
    entries[features] = [SHADER_OPTION_COUNT]vk.SpecializationMapEntry {
      { constantID = 0, offset = u32(offset_of(ShaderConfig, is_skinned)), size = size_of(b32) },
      { constantID = 1, offset = u32(offset_of(ShaderConfig, has_texture)), size = size_of(b32) },
      { constantID = 2, offset = u32(offset_of(ShaderConfig, is_lit)), size = size_of(b32) },
      { constantID = 3, offset = u32(offset_of(ShaderConfig, can_receive_shadow)), size = size_of(b32) },
    }
    spec_infos[features] = vk.SpecializationInfo {
      mapEntryCount = len(entries[features]),
      pMapEntries   = raw_data(entries[features][:]),
      dataSize      = size_of(ShaderConfig),
      pData         = &configs[features],
    }
    shader_stages_arr[features] = [?]vk.PipelineShaderStageCreateInfo {
      {
        sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage  = {.VERTEX},
        module = vert_module,
        pName  = "main",
        pSpecializationInfo = &spec_infos[features],
      }, {
        sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage  = {.FRAGMENT},
        module = frag_module,
        pName  = "main",
        pSpecializationInfo = &spec_infos[features],
      },
    }
    vertex_input_info := vk.PipelineVertexInputStateCreateInfo{
      sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
      vertexBindingDescriptionCount = len(geometry.VERTEX_BINDING_DESCRIPTION),
      pVertexBindingDescriptions = raw_data(geometry.VERTEX_BINDING_DESCRIPTION[:]),
      vertexAttributeDescriptionCount = len(geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS),
      pVertexAttributeDescriptions = raw_data(geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:])
    }
    fmt.printfln(
      "Creating pipeline for features: %04b with config %v with vertex input %v",
      features,
      configs[features],
      vertex_input_info,
    )
    bindings := []vk.DescriptorSetLayoutBinding{
      {
        binding = 0,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = 1,
        stageFlags = {.FRAGMENT}
      }, {
        binding = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = 1,
        stageFlags = {.FRAGMENT}
      }, {
        binding = 2,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = 1,
        stageFlags = {.FRAGMENT}
      }, {
        binding = 3,
        descriptorType =
        .STORAGE_BUFFER,
        descriptorCount = 1,
        stageFlags = {.VERTEX}
      },
    }
    layout_info := vk.DescriptorSetLayoutCreateInfo {
      sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = u32(len(bindings)),
      pBindings    = raw_data(bindings),
    }
    vk.CreateDescriptorSetLayout(
      ctx.vkd,
      &layout_info,
      nil,
      &uber_material_descriptor_set_layouts[features],
    ) or_continue
    set_layouts := [?]vk.DescriptorSetLayout {
      uber_main_pass_descriptor_set_layout,
      uber_material_descriptor_set_layouts[features],
    }
    push_constant_range := vk.PushConstantRange {
      stageFlags = {.VERTEX},
      size       = size_of(linalg.Matrix4f32),
    }
    pipeline_layout_info := vk.PipelineLayoutCreateInfo {
      sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount         = len(set_layouts),
      pSetLayouts            = raw_data(set_layouts[:]),
      pushConstantRangeCount = 1,
      pPushConstantRanges    = &push_constant_range,
    }
    vk.CreatePipelineLayout(
      ctx.vkd,
      &pipeline_layout_info,
      nil,
      &uber_pipeline_layouts[features],
    ) or_continue
    pipeline_layout := get_pipeline_layout(ctx, u32(features))
    pipeline_infos[features] = vk.GraphicsPipelineCreateInfo {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      pNext               = &rendering_info_khr,
      stageCount          = len(shader_stages_arr[features]),
      pStages             = raw_data(shader_stages_arr[features][:]),
      pVertexInputState   = &vertex_input_info,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pColorBlendState    = &blending,
      pDynamicState       = &dynamic_state_info,
      pDepthStencilState  = &depth_stencil_state,
      layout              = pipeline_layout,
    }
  }
  vk.CreateGraphicsPipelines(
    ctx.vkd,
    0,
    len(pipeline_infos),
    raw_data(pipeline_infos[:]),
    nil,
    raw_data(uber_pipelines[:]),
  ) or_return
  return .SUCCESS
}


create_uber_material_untextured :: proc(
  engine: ^Engine,
  features: u32,
) -> (
  ret: Handle,
  mat: ^UberMaterial,
  res: vk.Result,
) {
  ret, mat = resource.alloc(&engine.materials)
  mat.ctx_ref = &engine.vk_ctx
  mat.features = features
  material_init_descriptor_set_layout(mat, &engine.vk_ctx) or_return
  return
}

create_uber_material_textured :: proc(
  engine: ^Engine,
  features: u32,
  albedo_handle: Handle,
  metallic_handle: Handle,
  roughness_handle: Handle,
) -> (
  ret: Handle,
  mat: ^UberMaterial,
  res: vk.Result,
) {
  ret, mat = resource.alloc(&engine.materials)
  mat.ctx_ref = &engine.vk_ctx
  mat.features = features | UBER_TEXTURED
  material_init_descriptor_set_layout(mat, &engine.vk_ctx) or_return
  albedo := resource.get(&engine.textures, albedo_handle)
  metallic := resource.get(&engine.textures, metallic_handle)
  roughness := resource.get(&engine.textures, roughness_handle)
  material_uber_update_textures(mat, albedo, metallic, roughness)
  return
}
