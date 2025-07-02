package mjolnir

import "core:log"
import "core:time"
import "geometry"
import "resource"
import vk "vendor:vulkan"

RendererGBuffer :: struct {
  pipelines:       [SHADER_VARIANT_COUNT]vk.Pipeline,
  pipeline_layout: vk.PipelineLayout,
}

renderer_gbuffer_init :: proc(
  self: ^RendererGBuffer,
  width: u32,
  height: u32,
) -> vk.Result {
  depth_format: vk.Format = .D32_SFLOAT
  set_layouts := [?]vk.DescriptorSetLayout {
    g_camera_descriptor_set_layout, // set = 0 (camera uniforms)
    g_lights_descriptor_set_layout, // set = 1 (light uniforms)
    g_textures_set_layout, // set = 1 (textures)
    g_bindless_bone_buffer_set_layout, // set = 2 (bone matrices)
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
  log.info("About to build G-buffer pipelines...")
  vert_shader_code := #load("shader/gbuffer/vert.spv")
  vert_module := create_shader_module(vert_shader_code) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  frag_shader_code := #load("shader/gbuffer/frag.spv")
  frag_module := create_shader_module(frag_shader_code) or_return
  defer vk.DestroyShaderModule(g_device, frag_module, nil)
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(geometry.VERTEX_BINDING_DESCRIPTION),
    pVertexBindingDescriptions      = raw_data(geometry.VERTEX_BINDING_DESCRIPTION[:]),
    vertexAttributeDescriptionCount = len(geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS),
    pVertexAttributeDescriptions    = raw_data(geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:]),
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
  color_formats := [?]vk.Format {
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
    configs[mask] = {
      is_skinned                     = .SKINNING in features,
      has_albedo_texture             = .ALBEDO_TEXTURE in features,
      has_metallic_roughness_texture = .METALLIC_ROUGHNESS_TEXTURE in features,
      has_normal_texture             = .NORMAL_TEXTURE in features,
      has_displacement_texture       = .DISPLACEMENT_TEXTURE in features,
      has_emissive_texture           = .EMISSIVE_TEXTURE in features,
    }
    entries[mask] = [SHADER_OPTION_COUNT]vk.SpecializationMapEntry {
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
    }
    spec_infos[mask] = {
      mapEntryCount = len(entries[mask]),
      pMapEntries   = raw_data(entries[mask][:]),
      dataSize      = size_of(ShaderConfig),
      pData         = &configs[mask],
    }
    shader_stages[mask] = [?]vk.PipelineShaderStageCreateInfo {
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
  log.info("G-buffer renderer initialized successfully")
  return .SUCCESS
}

renderer_gbuffer_begin :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
  extent: vk.Extent2D,
) {
  frame := &engine.frames[g_frame_index]
  prepare_image_for_render(
    command_buffer,
    frame.gbuffer_normal.image,
    .COLOR_ATTACHMENT_OPTIMAL,
  )
  prepare_image_for_render(
    command_buffer,
    frame.gbuffer_albedo.image,
    .COLOR_ATTACHMENT_OPTIMAL,
  )
  prepare_image_for_render(
    command_buffer,
    frame.gbuffer_metallic_roughness.image,
    .COLOR_ATTACHMENT_OPTIMAL,
  )
  prepare_image_for_render(
    command_buffer,
    frame.gbuffer_emissive.image,
    .COLOR_ATTACHMENT_OPTIMAL,
  )
  normal_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = frame.gbuffer_normal.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  albedo_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = frame.gbuffer_albedo.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  metallic_roughness_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = frame.gbuffer_metallic_roughness.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  emissive_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = frame.gbuffer_emissive.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType       = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView   = frame.depth_buffer.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }
  color_attachments := [?]vk.RenderingAttachmentInfoKHR {
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
  frame := &engine.frames[g_frame_index]
  prepare_image_for_shader_read(command_buffer, frame.gbuffer_normal.image)
  prepare_image_for_shader_read(command_buffer, frame.gbuffer_albedo.image)
  prepare_image_for_shader_read(
    command_buffer,
    frame.gbuffer_metallic_roughness.image,
  )
  prepare_image_for_shader_read(command_buffer, frame.gbuffer_emissive.image)
}

renderer_gbuffer_render :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  camera_frustum := geometry.camera_make_frustum(engine.scene.camera)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    engine.gbuffer.pipeline_layout,
    0,
    1,
    &g_camera_descriptor_sets[g_frame_index],
    0,
    nil,
  )
  mesh_count := 0
  for &entry in engine.scene.nodes.entries do if entry.active {
    node := &entry.item
    mesh_att, has_mesh := &node.attachment.(MeshAttachment)
    if !has_mesh {
      continue
    }
    mesh := resource.get(g_meshes, mesh_att.handle)
    if mesh == nil do continue
    material := resource.get(g_materials, mesh_att.material)
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
    node_skinning, has_skinning := mesh_att.skinning.?
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
      g_camera_descriptor_sets[g_frame_index], // set = 0 (camera uniforms)
      g_lights_descriptor_sets[g_frame_index], // set = 1 (light uniforms)
      g_textures_descriptor_set, // set = 2 (textures)
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

renderer_gbuffer_get_pipeline :: proc(
  self: ^RendererGBuffer,
  features: ShaderFeatureSet = {},
) -> vk.Pipeline {
  return self.pipelines[transmute(u32)features]
}

renderer_gbuffer_deinit :: proc(self: ^RendererGBuffer) {
  for pipeline in self.pipelines {
    vk.DestroyPipeline(g_device, pipeline, nil)
  }
  vk.DestroyPipelineLayout(g_device, self.pipeline_layout, nil)
}
