package mjolnir

import "core:fmt"
import linalg "core:math/linalg"
import "geometry"
import "resource"
import vk "vendor:vulkan"

SHADER_FEATURE_SKINNING :: 1 << 0
SHADER_FEATURE_ALBEDO_TEXTURE       :: 1 << 1
SHADER_FEATURE_METALLIC_ROUGHNESS_TEXTURE :: 1 << 2
SHADER_FEATURE_NORMAL_TEXTURE       :: 1 << 3
SHADER_FEATURE_DISPLACEMENT_TEXTURE :: 1 << 4
SHADER_FEATURE_EMISSIVE_TEXTURE     :: 1 << 5
SHADER_FEATURE_LIT                  :: 1 << 6

SHADER_OPTION_COUNT :: 7
SHADER_VARIANT_COUNT :: 1 << SHADER_OPTION_COUNT

// Specialization constant struct (must match shader)
ShaderConfig :: struct {
    is_skinned:             b32,
    has_albedo_texture:     b32,
    has_metallic_roughness_texture: b32,
    has_normal_texture:     b32,
    has_displacement_texture:b32,
    has_emissive_texture:   b32,
    is_lit:                 b32,
}

// Material descriptor set layout: [albedo, metallic, roughness, bones (optional)]
MaterialFallbacks :: struct {
  albedo:    linalg.Vector4f32,
  emissive:  linalg.Vector4f32,
  roughness: f32,
  metallic:  f32,
}

Material :: struct {
  texture_descriptor_set:  vk.DescriptorSet,
  skinning_descriptor_set: vk.DescriptorSet,
  features:                u32,
  ctx:                     ^VulkanContext,

  // Texture handles for each supported type
  albedo_handle:           Handle,
  metallic_roughness_handle:         Handle,
  normal_handle:           Handle,
  displacement_handle:     Handle,
  emissive_handle:         Handle,

  // Fallback values for each property
  albedo_value:            linalg.Vector4f32,
  metallic_value:          f32,
  roughness_value:         f32,
  emissive_value:          linalg.Vector4f32,

  // Uniform buffer for fallback values (using DataBuffer)
  fallback_buffer:         DataBuffer,
}
camera_descriptor_set_layout: vk.DescriptorSetLayout
environment_descriptor_set_layout: vk.DescriptorSetLayout

// material set layouts only account for textures and bones features
texture_descriptor_set_layout: vk.DescriptorSetLayout
skinning_descriptor_set_layout: vk.DescriptorSetLayout
pipeline_layout: vk.PipelineLayout
pipelines: [SHADER_VARIANT_COUNT]vk.Pipeline

// Shader binaries (should point to your uber shader)
SHADER_UBER_VERT :: #load("shader/uber/vert.spv")
SHADER_UBER_FRAG :: #load("shader/uber/frag.spv")

// Descriptor set layout creation (superset: textures + bones)
material_init_descriptor_set_layout :: proc(
  mat: ^Material,
  ctx: ^VulkanContext,
) -> vk.Result {
  alloc_info_texture := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = ctx.descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &texture_descriptor_set_layout,
  }
  vk.AllocateDescriptorSets(
    ctx.vkd,
    &alloc_info_texture,
    &mat.texture_descriptor_set,
  ) or_return
  // if mat.features & SHADER_FEATURE_SKINNING != 0 {
  alloc_info_skinning := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = ctx.descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &skinning_descriptor_set_layout,
  }
  vk.AllocateDescriptorSets(
    ctx.vkd,
    &alloc_info_skinning,
    &mat.skinning_descriptor_set,
  ) or_return
  // }
  return .SUCCESS
}

// Update textures (albedo, metallic, roughness)
material_update_textures :: proc(
  mat: ^Material,
  albedo: ^Texture,
  metallic_roughness: ^Texture,
  normal: ^Texture,
  displacement: ^Texture,
  emissive: ^Texture,
) -> vk.Result {
  if mat.ctx == nil || mat.texture_descriptor_set == 0 {
    return .ERROR_INITIALIZATION_FAILED
  }
  vkd := mat.ctx.vkd
  material_init_descriptor_set_layout(mat, mat.ctx) or_return

  image_infos := [?]vk.DescriptorImageInfo {
    {
      sampler = albedo.sampler if albedo != nil else 0,
      imageView = albedo.buffer.view if albedo != nil else 0,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
    {
      sampler = metallic_roughness.sampler if metallic_roughness != nil else 0,
      imageView = metallic_roughness.buffer.view if metallic_roughness != nil else 0,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
    {
      sampler = normal.sampler if normal != nil else 0,
      imageView = normal.buffer.view if normal != nil else 0,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
    {
      sampler = displacement.sampler if displacement != nil else 0,
      imageView = displacement.buffer.view if displacement != nil else 0,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
    {
      sampler = emissive.sampler if emissive != nil else 0,
      imageView = emissive.buffer.view if emissive != nil else 0,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
  }

  // --- Upload fallback values to a uniform buffer and bind at binding 6 ---
  fallbacks := MaterialFallbacks {
    albedo    = mat.albedo_value,
    emissive  = mat.emissive_value,
    roughness = mat.roughness_value,
    metallic  = mat.metallic_value,
  }
  mat.fallback_buffer = create_host_visible_buffer(
    mat.ctx,
    size_of(MaterialFallbacks),
    {.UNIFORM_BUFFER},
    &fallbacks,
  ) or_return

  writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = mat.texture_descriptor_set,
      dstBinding = 0,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[0],
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = mat.texture_descriptor_set,
      dstBinding = 1,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[1],
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = mat.texture_descriptor_set,
      dstBinding = 2,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[2],
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = mat.texture_descriptor_set,
      dstBinding = 3,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[3],
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = mat.texture_descriptor_set,
      dstBinding = 4,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[4],
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = mat.texture_descriptor_set,
      dstBinding = 5,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &vk.DescriptorBufferInfo {
        buffer = mat.fallback_buffer.buffer,
        offset = 0,
        range = size_of(MaterialFallbacks),
      },
    },
  }

  vk.UpdateDescriptorSets(
    mat.ctx.vkd,
    len(writes),
    raw_data(writes[:]),
    0,
    nil,
  )
  return .SUCCESS
}

// Update bone buffer (for skinned meshes)
material_update_bone_buffer :: proc(
  mat: ^Material,
  buffer: vk.Buffer,
  size: vk.DeviceSize,
) {
  if mat.ctx == nil || mat.texture_descriptor_set == 0 {
    return
  }
  vkd := mat.ctx.vkd

  buffer_info := vk.DescriptorBufferInfo {
    buffer = buffer,
    offset = 0,
    range  = size,
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = mat.skinning_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(vkd, 1, &write, 0, nil)
}
build_3d_pipelines :: proc(
  ctx: ^VulkanContext,
  target_color_format: vk.Format,
  target_depth_format: vk.Format,
) -> vk.Result {
  bindings_main := [?]vk.DescriptorSetLayoutBinding {
    {   // Scene Uniforms (view, proj, time)
      binding         = 0,
      descriptorType  = .UNIFORM_BUFFER_DYNAMIC,
      descriptorCount = 1,
      stageFlags      = {.VERTEX, .FRAGMENT},
    },
    {   // Light Uniforms
      binding         = 1,
      descriptorType  = .UNIFORM_BUFFER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    },
    {   // Shadow Maps
      binding         = 2,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = MAX_SHADOW_MAPS,
      stageFlags      = {.FRAGMENT},
    },
    {   // Cube Shadow Maps
      binding         = 3,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = MAX_SHADOW_MAPS,
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
    &camera_descriptor_set_layout,
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
  texture_bindings := []vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
    {
      binding = 1,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
    {
      binding = 2,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
    {
      binding = 3,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
    {
      binding = 4,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
    {
      binding = 5,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
  }
  vk.CreateDescriptorSetLayout(
    ctx.vkd,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = u32(len(texture_bindings)),
      pBindings = raw_data(texture_bindings),
    },
    nil,
    &texture_descriptor_set_layout,
  ) or_return
  skinning_bindings := []vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX},
    },
  }
  vk.CreateDescriptorSetLayout(
    ctx.vkd,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = u32(len(skinning_bindings)),
      pBindings = raw_data(skinning_bindings),
    },
    nil,
    &skinning_descriptor_set_layout,
  ) or_return

  // Environment map descriptor set layout
  environment_bindings := []vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
  }
  vk.CreateDescriptorSetLayout(
    ctx.vkd,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = u32(len(environment_bindings)),
      pBindings = raw_data(environment_bindings),
    },
    nil,
    &environment_descriptor_set_layout,
  ) or_return

  set_layouts := [?]vk.DescriptorSetLayout {
    camera_descriptor_set_layout, // set = 0
    texture_descriptor_set_layout, // set = 1
    skinning_descriptor_set_layout, // set = 2
    environment_descriptor_set_layout, // set = 3
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
    &pipeline_layout,
  ) or_return
  for features in 0 ..< SHADER_VARIANT_COUNT {
      configs[features] = ShaderConfig {
        is_skinned              = (features & SHADER_FEATURE_SKINNING) != 0,
        has_albedo_texture      = (features & SHADER_FEATURE_ALBEDO_TEXTURE) != 0,
        has_metallic_roughness_texture = (features & SHADER_FEATURE_METALLIC_ROUGHNESS_TEXTURE) != 0,
        has_normal_texture      = (features & SHADER_FEATURE_NORMAL_TEXTURE) != 0,
        has_displacement_texture= (features & SHADER_FEATURE_DISPLACEMENT_TEXTURE) != 0,
        has_emissive_texture    = (features & SHADER_FEATURE_EMISSIVE_TEXTURE) != 0,
        is_lit                  = (features & SHADER_FEATURE_LIT) != 0,
      }
      entries[features] = [SHADER_OPTION_COUNT]vk.SpecializationMapEntry {
        {
          constantID = 0,
          offset = u32(offset_of(ShaderConfig, is_skinned)),
          size = size_of(b32),
        },
        {
          constantID = 1,
          offset = u32(offset_of(ShaderConfig, has_albedo_texture)),
          size = size_of(b32),
        },
        {
          constantID = 2,
          offset = u32(offset_of(ShaderConfig, has_metallic_roughness_texture)),
          size = size_of(b32),
        },
        {
          constantID = 3,
          offset = u32(offset_of(ShaderConfig, has_normal_texture)),
          size = size_of(b32),
        },
        {
          constantID = 4,
          offset = u32(offset_of(ShaderConfig, has_displacement_texture)),
          size = size_of(b32),
        },
        {
          constantID = 5,
          offset = u32(offset_of(ShaderConfig, has_emissive_texture)),
          size = size_of(b32),
        },
        {
          constantID = 6,
          offset = u32(offset_of(ShaderConfig, is_lit)),
          size = size_of(b32),
        },
      }
    spec_infos[features] = vk.SpecializationInfo {
      mapEntryCount = len(entries[features]),
      pMapEntries   = raw_data(entries[features][:]),
      dataSize      = size_of(ShaderConfig),
      pData         = &configs[features],
    }
    shader_stages_arr[features] = [?]vk.PipelineShaderStageCreateInfo {
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.VERTEX},
        module = vert_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[features],
      },
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.FRAGMENT},
        module = frag_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[features],
      },
    }
    fmt.printfln(
      "Creating pipeline for features: %08b with config %v with vertex input %v",
      features,
      configs[features],
      vertex_input_info,
    )
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
    raw_data(pipelines[:]),
  ) or_return
  return .SUCCESS
}


create_material :: proc(
  engine: ^Engine,
  features: u32 = 0,
  albedo_handle: Handle = {},
  metallic_roughness_handle: Handle = {},
  normal_handle: Handle = {},
  displacement_handle: Handle = {},
  emissive_handle: Handle = {},
  albedo_value: linalg.Vector4f32 = {1, 1, 1, 1},
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: linalg.Vector4f32 = {},
) -> (
  ret: Handle,
  mat: ^Material,
  res: vk.Result,
) {
  ret, mat = resource.alloc(&engine.materials)
  mat.ctx = &engine.ctx
  mat.features = features

  mat.albedo_handle = albedo_handle
  mat.metallic_roughness_handle = metallic_roughness_handle
  mat.normal_handle = normal_handle
  mat.displacement_handle = displacement_handle
  mat.emissive_handle = emissive_handle

  mat.albedo_value = albedo_value
  mat.metallic_value = metallic_value
  mat.roughness_value = roughness_value
  mat.emissive_value = emissive_value

  material_init_descriptor_set_layout(mat, &engine.ctx) or_return

  // Bind textures if handles are valid, otherwise fallback to flat values in shader
  albedo := resource.get(&engine.textures, albedo_handle)
  metallic_roughness := resource.get(&engine.textures, metallic_roughness_handle)
  normal := resource.get(&engine.textures, normal_handle)
  displacement := resource.get(&engine.textures, displacement_handle)
  emissive := resource.get(&engine.textures, emissive_handle)
  material_update_textures(
    mat,
    albedo,
    metallic_roughness,
    normal,
    displacement,
    emissive,
  ) or_return
  res = .SUCCESS
  return
}
