package mjolnir

import "core:log"
import linalg "core:math/linalg"
import "core:mem"
import "core:time"
import "geometry"
import "resource"
import vk "vendor:vulkan"

RendererGBuffer :: struct {
  pipelines:             [SHADER_VARIANT_COUNT]vk.Pipeline,
  pipeline_layout:       vk.PipelineLayout,
  descriptor_set_layout: vk.DescriptorSetLayout,
  normal_buffer:         ImageBuffer,
  albedo_buffer:         ImageBuffer,
  metallic_roughness_buffer: ImageBuffer,
  emissive_buffer:       ImageBuffer,
  descriptor_sets:       [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  scene_uniform_buffers: [MAX_FRAMES_IN_FLIGHT]DataBuffer(SceneUniform),
  light_uniform_buffers: [MAX_FRAMES_IN_FLIGHT]DataBuffer(SceneLightUniform),
}

// Helper to create images for G-buffer
renderer_gbuffer_create_images :: proc(self: ^RendererGBuffer, width: u32, height: u32) -> vk.Result {
    self.normal_buffer = malloc_image_buffer(
        width,
        height,
        .R8G8B8A8_UNORM,
        .OPTIMAL,
        {.COLOR_ATTACHMENT, .SAMPLED},
        {.DEVICE_LOCAL},
    ) or_return
    self.normal_buffer.view = create_image_view(
        self.normal_buffer.image,
        .R8G8B8A8_UNORM,
        {.COLOR},
    ) or_return
    self.albedo_buffer = malloc_image_buffer(
        width,
        height,
        .R8G8B8A8_UNORM,
        .OPTIMAL,
        {.COLOR_ATTACHMENT, .SAMPLED},
        {.DEVICE_LOCAL},
    ) or_return
    self.albedo_buffer.view = create_image_view(
        self.albedo_buffer.image,
        .R8G8B8A8_UNORM,
        {.COLOR},
    ) or_return
    self.metallic_roughness_buffer = malloc_image_buffer(
        width,
        height,
        .R8G8B8A8_UNORM,
        .OPTIMAL,
        {.COLOR_ATTACHMENT, .SAMPLED},
        {.DEVICE_LOCAL},
    ) or_return
    self.metallic_roughness_buffer.view = create_image_view(
        self.metallic_roughness_buffer.image,
        .R8G8B8A8_UNORM,
        {.COLOR},
    ) or_return
    self.emissive_buffer = malloc_image_buffer(
        width,
        height,
        .R8G8B8A8_UNORM,
        .OPTIMAL,
        {.COLOR_ATTACHMENT, .SAMPLED},
        {.DEVICE_LOCAL},
    ) or_return
    self.emissive_buffer.view = create_image_view(
        self.emissive_buffer.image,
        .R8G8B8A8_UNORM,
        {.COLOR},
    ) or_return
    return .SUCCESS
}

// Helper to deinit images for G-buffer
renderer_gbuffer_deinit_images :: proc(self: ^RendererGBuffer) {
    image_buffer_deinit(&self.normal_buffer)
    image_buffer_deinit(&self.albedo_buffer)
    image_buffer_deinit(&self.metallic_roughness_buffer)
    image_buffer_deinit(&self.emissive_buffer)
}

// Helper to recreate images for G-buffer
renderer_gbuffer_recreate_images :: proc(self: ^RendererGBuffer, width: u32, height: u32) -> vk.Result {
    renderer_gbuffer_deinit_images(self)
    return renderer_gbuffer_create_images(self, width, height)
}

renderer_gbuffer_init :: proc(
  self: ^RendererGBuffer,
  width: u32,
  height: u32,
) -> vk.Result {
  renderer_gbuffer_create_images(self, width, height) or_return
  depth_format: vk.Format = .D32_SFLOAT
  // Create uniform buffers
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    self.scene_uniform_buffers[i] = create_host_visible_buffer(
      SceneUniform,
      1,
      {.UNIFORM_BUFFER},
    ) or_return

    self.light_uniform_buffers[i] = create_host_visible_buffer(
      SceneLightUniform,
      1,
      {.UNIFORM_BUFFER},
    ) or_return
  }
  bindings := [?]vk.DescriptorSetLayoutBinding {
    // Scene uniform (set = 0, binding = 0)
    {
      binding = 0,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX, .FRAGMENT},
    },
    // Light uniform (set = 0, binding = 1)
    {
      binding = 1,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX, .FRAGMENT},
    },
    // Shadow maps (set = 0, binding = 2) - required for layout compatibility
    {
      binding = 2,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = MAX_SHADOW_MAPS,
      stageFlags = {.FRAGMENT},
    },
    // Cube shadow maps (set = 0, binding = 3) - required for layout compatibility
    {
      binding = 3,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = MAX_SHADOW_MAPS,
      stageFlags = {.FRAGMENT},
    },
  }
  vk.CreateDescriptorSetLayout(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &self.descriptor_set_layout,
  ) or_return
  set_layouts := [?]vk.DescriptorSetLayout {
    self.descriptor_set_layout, // set = 0 (camera/scene uniforms)
    g_bindless_textures_layout, // set = 1 (textures)
    g_bindless_samplers_layout, // set = 2 (samplers)
    g_bindless_bone_buffer_set_layout, // set = 3 (bone matrices)
  }
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX, .FRAGMENT},
    size       = size_of(PushConstant),
  }
  vk.CreatePipelineLayout(
    g_device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(set_layouts),
      pSetLayouts = raw_data(set_layouts[:]),
      pushConstantRangeCount = 1,
      pPushConstantRanges = &push_constant_range,
    },
    nil,
    &self.pipeline_layout,
  ) or_return
  // Create descriptor sets (only for set 0 - camera/scene uniforms)
  // Other sets (textures, samplers, bone matrices) use global descriptor sets
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    vk.AllocateDescriptorSets(
      g_device,
      &{
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = g_descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &self.descriptor_set_layout,
      },
      &self.descriptor_sets[i],
    ) or_return
    // Update descriptor sets - camera/scene uniforms and dummy shadow maps for compatibility
    scene_buffer_info := vk.DescriptorBufferInfo {
      buffer = self.scene_uniform_buffers[i].buffer,
      range  = vk.DeviceSize(self.scene_uniform_buffers[i].bytes_count),
    }
    light_buffer_info := vk.DescriptorBufferInfo {
      buffer = self.light_uniform_buffers[i].buffer,
      range  = vk.DeviceSize(self.light_uniform_buffers[i].bytes_count),
    }
    writes := [?]vk.WriteDescriptorSet {
      // Scene uniform (binding 0)
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[i],
        dstBinding = 0,
        descriptorType = .UNIFORM_BUFFER,
        descriptorCount = 1,
        pBufferInfo = &scene_buffer_info,
      },
      // Light uniform (binding 1)
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[i],
        dstBinding = 1,
        descriptorType = .UNIFORM_BUFFER,
        descriptorCount = 1,
        pBufferInfo = &light_buffer_info,
      },
    }
    vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
  }
  self.pipelines = {}
  log.info("About to build G-buffer pipelines...")
  // Create G-buffer specific pipelines (focus on normals output)
  renderer_gbuffer_build_pipelines(self, depth_format) or_return
  log.info("G-buffer renderer initialized successfully")
  return .SUCCESS
}

renderer_gbuffer_build_pipelines :: proc(
  self: ^RendererGBuffer,
  depth_format: vk.Format,
) -> vk.Result {
  vert_shader_code := #load("shader/gbuffer/vert.spv")
  vert_module := create_shader_module(vert_shader_code) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  frag_shader_code := #load("shader/gbuffer/frag.spv")
  frag_module := create_shader_module(frag_shader_code) or_return
  defer vk.DestroyShaderModule(g_device, frag_module, nil)
  vertex_bindings := [?]vk.VertexInputBindingDescription {
    {binding = 0, stride = size_of(geometry.Vertex), inputRate = .VERTEX},
    {
      binding = 1,
      stride = size_of(geometry.SkinningData),
      inputRate = .VERTEX,
    },
  }
  vertex_attributes := [?]vk.VertexInputAttributeDescription {
    {
      location = 0,
      binding = 0,
      format = .R32G32B32_SFLOAT,
      offset = u32(offset_of(geometry.Vertex, position)),
    },
    {
      location = 1,
      binding = 0,
      format = .R32G32B32_SFLOAT,
      offset = u32(offset_of(geometry.Vertex, normal)),
    },
    {
      location = 2,
      binding = 0,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(geometry.Vertex, color)),
    },
    {
      location = 3,
      binding = 0,
      format = .R32G32_SFLOAT,
      offset = u32(offset_of(geometry.Vertex, uv)),
    },
    {
      location = 4,
      binding = 1,
      format = .R32G32B32A32_UINT,
      offset = u32(offset_of(geometry.SkinningData, joints)),
    },
    {
      location = 5,
      binding = 1,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(geometry.SkinningData, weights)),
    },
  }
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(vertex_bindings),
    pVertexBindingDescriptions      = raw_data(vertex_bindings[:]),
    vertexAttributeDescriptionCount = len(vertex_attributes),
    pVertexAttributeDescriptions    = raw_data(vertex_attributes[:]),
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
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = true,
    depthCompareOp   = .LESS,
  }
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    colorWriteMask = {.R, .G, .B, .A},
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }
  color_formats := [?]vk.Format{
    .R8G8B8A8_UNORM, // normal
    .R8G8B8A8_UNORM, // albedo
    .R8G8B8A8_UNORM, // metallic/roughness
    .R8G8B8A8_UNORM, // emissive
  }
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
    depthAttachmentFormat   = depth_format,
  }
  pipeline_infos: [SHADER_VARIANT_COUNT]vk.GraphicsPipelineCreateInfo
  configs: [SHADER_VARIANT_COUNT]ShaderConfig
  entries: [SHADER_VARIANT_COUNT][SHADER_OPTION_COUNT]vk.SpecializationMapEntry
  spec_infos: [SHADER_VARIANT_COUNT]vk.SpecializationInfo
  shader_stages: [SHADER_VARIANT_COUNT][2]vk.PipelineShaderStageCreateInfo
  for mask in 0 ..< SHADER_VARIANT_COUNT {
    features := transmute(ShaderFeatureSet)mask
    configs[mask] = ShaderConfig {
      is_skinned                     = .SKINNING in features,
      has_albedo_texture             = .ALBEDO_TEXTURE in features,
      has_metallic_roughness_texture = .METALLIC_ROUGHNESS_TEXTURE in features,
      has_normal_texture             = .NORMAL_TEXTURE in features,
      has_displacement_texture       = .DISPLACEMENT_TEXTURE in features,
      has_emissive_texture           = .EMISSIVE_TEXTURE in features,
    }
    entries[mask] = [SHADER_OPTION_COUNT]vk.SpecializationMapEntry {
      { constantID = 0, offset = u32(offset_of(ShaderConfig, is_skinned)),                     size = size_of(b32) },
      { constantID = 1, offset = u32(offset_of(ShaderConfig, has_albedo_texture)),             size = size_of(b32) },
      { constantID = 2, offset = u32(offset_of(ShaderConfig, has_metallic_roughness_texture)), size = size_of(b32) },
      { constantID = 3, offset = u32(offset_of(ShaderConfig, has_normal_texture)),             size = size_of(b32) },
      { constantID = 4, offset = u32(offset_of(ShaderConfig, has_displacement_texture)),       size = size_of(b32) },
      { constantID = 5, offset = u32(offset_of(ShaderConfig, has_emissive_texture)),           size = size_of(b32) },
    }
    spec_infos[mask] = {
      mapEntryCount = len(entries[mask]),
      pMapEntries   = raw_data(entries[mask][:]),
      dataSize      = size_of(ShaderConfig),
      pData         = &configs[mask],
    }
    shader_stages[mask] = [2]vk.PipelineShaderStageCreateInfo {
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.VERTEX},
        module = vert_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[mask],
      },
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.FRAGMENT},
        module = frag_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[mask],
      },
    }
    pipeline_infos[mask] = {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      stageCount          = len(shader_stages[mask]),
      pStages             = raw_data(shader_stages[mask][:]),
      pVertexInputState   = &vertex_input_info,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pDepthStencilState  = &depth_stencil,
      pColorBlendState    = &color_blending,
      pDynamicState       = &dynamic_state,
      layout              = self.pipeline_layout,
      pNext               = &rendering_info,
    }
  }
  vk.CreateGraphicsPipelines(
    g_device,
    0,
    len(pipeline_infos),
    raw_data(pipeline_infos[:]),
    nil,
    raw_data(self.pipelines[:]),
  ) or_return
  return .SUCCESS
}

renderer_gbuffer_begin :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
  extent: vk.Extent2D,
) {
  prepare_image_for_render(command_buffer, engine.gbuffer.normal_buffer.image, .COLOR_ATTACHMENT_OPTIMAL)
  prepare_image_for_render(command_buffer, engine.gbuffer.albedo_buffer.image, .COLOR_ATTACHMENT_OPTIMAL)
  prepare_image_for_render(command_buffer, engine.gbuffer.metallic_roughness_buffer.image, .COLOR_ATTACHMENT_OPTIMAL)
  prepare_image_for_render(command_buffer, engine.gbuffer.emissive_buffer.image, .COLOR_ATTACHMENT_OPTIMAL)
  normal_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = engine.gbuffer.normal_buffer.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  albedo_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = engine.gbuffer.albedo_buffer.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  metallic_roughness_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = engine.gbuffer.metallic_roughness_buffer.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  emissive_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = engine.gbuffer.emissive_buffer.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType       = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView   = engine.depth_prepass.depth_buffer.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }
  color_attachments := [?]vk.RenderingAttachmentInfoKHR{
    normal_attachment,
    albedo_attachment,
    metallic_roughness_attachment,
    emissive_attachment,
  }
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = extent},
    layerCount = 1,
    colorAttachmentCount = len(color_attachments),
    pColorAttachments = raw_data(color_attachments[:]),
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0.0,
    y        = f32(extent.height),
    width    = f32(extent.width),
    height   = -f32(extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

renderer_gbuffer_end :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  vk.CmdEndRenderingKHR(command_buffer)
  prepare_image_for_shader_read(command_buffer, engine.gbuffer.normal_buffer.image)
  prepare_image_for_shader_read(command_buffer, engine.gbuffer.albedo_buffer.image)
  prepare_image_for_shader_read(command_buffer, engine.gbuffer.metallic_roughness_buffer.image)
  prepare_image_for_shader_read(command_buffer, engine.gbuffer.emissive_buffer.image)
}

renderer_gbuffer_render :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  scene_uniform := data_buffer_get(
    &engine.gbuffer.scene_uniform_buffers[g_frame_index],
  )
  scene_uniform.view = geometry.calculate_view_matrix(engine.scene.camera)
  scene_uniform.projection = geometry.calculate_projection_matrix(
    engine.scene.camera,
  )
  scene_uniform.time = f32(
    time.duration_seconds(time.since(engine.start_timestamp)),
  )
  camera_frustum := geometry.camera_make_frustum(engine.scene.camera)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    engine.gbuffer.pipeline_layout,
    0,
    1,
    &engine.gbuffer.descriptor_sets[g_frame_index],
    0,
    nil,
  )
  mesh_count := 0
  for &entry in engine.scene.nodes.entries do if entry.active {
    node := &entry.item
    #partial switch data in node.attachment {
    case MeshAttachment:
      mesh := resource.get(g_meshes, data.handle)
      if mesh == nil do continue
      material := resource.get(g_materials, data.material)
      if material == nil do continue
      mesh_count += 1
      world_aabb := geometry.aabb_transform(mesh.aabb, node.transform.world_matrix)
      if !geometry.frustum_test_aabb(&camera_frustum, world_aabb) do continue
      texture_indices: MaterialTextures = {
        albedo_index             = min(MAX_TEXTURES - 1, material.albedo.index),
        metallic_roughness_index = min(MAX_TEXTURES - 1, material.metallic_roughness.index),
        normal_index             = min(MAX_TEXTURES - 1, material.normal.index),
        displacement_index       = min(MAX_TEXTURES - 1, material.displacement.index),
        emissive_index           = min(MAX_TEXTURES - 1, material.emissive.index),
      }
      node_skinning, has_skinning := data.skinning.?
      if has_skinning {
        texture_indices.bone_matrix_offset = node_skinning.bone_matrix_offset + g_frame_index * g_bone_matrix_slab.capacity
      }
      push_constants := PushConstant {
        world           = node.transform.world_matrix,
        textures        = texture_indices,
        metallic_value  = material.metallic_value,
        roughness_value = material.roughness_value,
        emissive_value  = material.emissive_value,
      }
      features := material.features & ShaderFeatureSet{.SKINNING}
      pipeline := renderer_gbuffer_get_pipeline(&engine.gbuffer, features)
      vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline)
      descriptor_sets := [?]vk.DescriptorSet {
        engine.gbuffer.descriptor_sets[g_frame_index], // set = 0 (camera/scene uniforms)
        g_bindless_textures, // set = 1 (textures)
        g_bindless_samplers, // set = 2 (samplers)
        g_bindless_bone_buffer_descriptor_set, // set = 3 (bone matrices)
      }
      vk.CmdBindDescriptorSets(command_buffer, .GRAPHICS, engine.gbuffer.pipeline_layout, 0, len(descriptor_sets), raw_data(descriptor_sets[:]), 0, nil)
      vk.CmdPushConstants(command_buffer, engine.gbuffer.pipeline_layout, {.VERTEX, .FRAGMENT}, 0, size_of(PushConstant), &push_constants)
      offset: vk.DeviceSize = 0
      vk.CmdBindVertexBuffers(command_buffer, 0, 1, &mesh.vertex_buffer.buffer, &offset)
      if skinning, has_skinning := &mesh.skinning.?; has_skinning {
        vk.CmdBindVertexBuffers(command_buffer, 1, 1, &skinning.skin_buffer.buffer, &offset)
      }
      vk.CmdBindIndexBuffer(command_buffer, mesh.index_buffer.buffer, 0, .UINT32)
      vk.CmdDrawIndexed(command_buffer, mesh.indices_len, 1, 0, 0, 0)
    }
  }
}

renderer_gbuffer_get_pipeline :: proc(
  self: ^RendererGBuffer,
  features: ShaderFeatureSet = {},
) -> vk.Pipeline {
  return self.pipelines[transmute(u32)features]
}

renderer_gbuffer_deinit :: proc(self: ^RendererGBuffer) {
  for pipeline in self.pipelines {
    if pipeline != 0 {
      vk.DestroyPipeline(g_device, pipeline, nil)
    }
  }
  vk.DestroyPipelineLayout(g_device, self.pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(g_device, self.descriptor_set_layout, nil)
  image_buffer_deinit(&self.normal_buffer)
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    data_buffer_deinit(&self.scene_uniform_buffers[i])
    data_buffer_deinit(&self.light_uniform_buffers[i])
  }
}
