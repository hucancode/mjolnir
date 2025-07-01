package mjolnir

import "core:log"
import linalg "core:math/linalg"
import "core:mem"
import "geometry"
import "resource"
import vk "vendor:vulkan"

SHADER_SHADOW_VERT :: #load("shader/shadow/vert.spv")

SHADOW_SHADER_OPTION_COUNT: u32 : 1 // Only SKINNING
SHADOW_SHADER_VARIANT_COUNT: u32 : 1 << SHADOW_SHADER_OPTION_COUNT

ShadowShaderConfig :: struct {
  is_skinned: b32,
}

RendererShadow :: struct {
  pipeline_layout:              vk.PipelineLayout,
  pipelines:                    [SHADOW_SHADER_VARIANT_COUNT]vk.Pipeline,
  camera_descriptor_set_layout: vk.DescriptorSetLayout,
  frames:                       [MAX_FRAMES_IN_FLIGHT]struct {
    camera_uniform:        DataBuffer(CameraUniform),
    camera_descriptor_set: vk.DescriptorSet,
  },
}

renderer_shadow_init :: proc(
  self: ^RendererShadow,
  depth_format: vk.Format = .D32_SFLOAT,
) -> vk.Result {
  camera_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .UNIFORM_BUFFER_DYNAMIC,
      descriptorCount = 1,
      stageFlags = {.VERTEX},
    },
  }
  vk.CreateDescriptorSetLayout(
    g_device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = 1,
      pBindings = raw_data(camera_bindings[:]),
    },
    nil,
    &self.camera_descriptor_set_layout,
  ) or_return
  set_layouts := [?]vk.DescriptorSetLayout {
    self.camera_descriptor_set_layout,
    g_bindless_bone_buffer_set_layout,
  }
  push_constant_range := [?]vk.PushConstantRange {
    {stageFlags = {.VERTEX}, size = size_of(PushConstant)},
  }
  vk.CreatePipelineLayout(
    g_device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(set_layouts),
      pSetLayouts = raw_data(set_layouts[:]),
      pushConstantRangeCount = len(push_constant_range),
      pPushConstantRanges = raw_data(push_constant_range[:]),
    },
    nil,
    &self.pipeline_layout,
  ) or_return
  vert_module := create_shader_module(SHADER_SHADOW_VERT) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
  }
  dynamic_states_values := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = u32(len(dynamic_states_values)),
    pDynamicStates    = raw_data(dynamic_states_values[:]),
  }
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode             = .FILL,
    cullMode                = {.BACK},
    frontFace               = .COUNTER_CLOCKWISE,
    depthBiasEnable         = true,
    depthBiasConstantFactor = 1.25,
    depthBiasClamp          = 0.0,
    depthBiasSlopeFactor    = 1.75,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = true,
    depthCompareOp   = .LESS,
  }
  rendering_info_khr := vk.PipelineRenderingCreateInfoKHR {
    sType                 = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    depthAttachmentFormat = depth_format,
  }
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(geometry.VERTEX_BINDING_DESCRIPTION),
    pVertexBindingDescriptions      = raw_data(
      geometry.VERTEX_BINDING_DESCRIPTION[:],
    ),
    vertexAttributeDescriptionCount = len(
      geometry.SIMPLE_VERTEX_ATTRIBUTE_DESCRIPTIONS,
    ),
    pVertexAttributeDescriptions    = raw_data(
      geometry.SIMPLE_VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
    ),
  }
  pipeline_infos: [SHADOW_SHADER_VARIANT_COUNT]vk.GraphicsPipelineCreateInfo
  configs: [SHADOW_SHADER_VARIANT_COUNT]ShadowShaderConfig
  entries: [SHADOW_SHADER_VARIANT_COUNT][SHADOW_SHADER_OPTION_COUNT]vk.SpecializationMapEntry
  spec_infos: [SHADOW_SHADER_VARIANT_COUNT]vk.SpecializationInfo
  shader_stages: [SHADOW_SHADER_VARIANT_COUNT][1]vk.PipelineShaderStageCreateInfo
  for mask in 0 ..< SHADOW_SHADER_VARIANT_COUNT {
    features := transmute(ShaderFeatureSet)mask & ShaderFeatureSet{.SKINNING}
    configs[mask] = {
      is_skinned = .SKINNING in features,
    }
    entries[mask] = [SHADOW_SHADER_OPTION_COUNT]vk.SpecializationMapEntry {
      {
        constantID = 0,
        offset = u32(offset_of(ShadowShaderConfig, is_skinned)),
        size = size_of(b32),
      },
    }
    spec_infos[mask] = {
      mapEntryCount = len(entries[mask]),
      pMapEntries   = raw_data(entries[mask][:]),
      dataSize      = size_of(ShadowShaderConfig),
      pData         = &configs[mask],
    }
    shader_stages[mask] = [1]vk.PipelineShaderStageCreateInfo {
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.VERTEX},
        module = vert_module,
        pName = "main",
        pSpecializationInfo = &spec_infos[mask],
      },
    }
    pipeline_infos[mask] = {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      pNext               = &rendering_info_khr,
      stageCount          = len(shader_stages[mask]),
      pStages             = raw_data(shader_stages[mask][:]),
      pVertexInputState   = &vertex_input_info,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pDynamicState       = &dynamic_state_info,
      pDepthStencilState  = &depth_stencil_state,
      layout              = self.pipeline_layout,
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
  for &frame in self.frames {
    frame.camera_uniform = create_host_visible_buffer(
      CameraUniform,
      (6 * MAX_LIGHTS),
      {.UNIFORM_BUFFER},
    ) or_return
    vk.AllocateDescriptorSets(
      g_device,
      &{
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = g_descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &self.camera_descriptor_set_layout,
      },
      &frame.camera_descriptor_set,
    ) or_return

    writes := [?]vk.WriteDescriptorSet {
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = frame.camera_descriptor_set,
        dstBinding = 0,
        descriptorType = .UNIFORM_BUFFER_DYNAMIC,
        descriptorCount = 1,
        pBufferInfo = &{
          buffer = frame.camera_uniform.buffer,
          range = vk.DeviceSize(size_of(CameraUniform)),
        },
      },
    }
    vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
  }
  return .SUCCESS
}

renderer_shadow_deinit :: proc(self: ^RendererShadow) {
  for &frame in self.frames {
    // descriptor set will eventually be freed by the pool
    frame.camera_descriptor_set = 0
  }
  for &p in self.pipelines {
    vk.DestroyPipeline(g_device, p, nil)
    p = 0
  }
  vk.DestroyPipelineLayout(g_device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
  vk.DestroyDescriptorSetLayout(
    g_device,
    self.camera_descriptor_set_layout,
    nil,
  )
  self.camera_descriptor_set_layout = 0
}

renderer_shadow_begin :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  initial_barriers := make([dynamic]vk.ImageMemoryBarrier, 0)
  defer delete(initial_barriers)
  // Transition all shadow maps to depth attachment optimal
  for light, i in engine.visible_lights[g_frame_index] do if light.has_shadow {
    switch light.kind {
    case .POINT:
      append(&initial_barriers, vk.ImageMemoryBarrier {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .UNDEFINED,
        newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = engine.frames[g_frame_index].cube_shadow_maps[i].image,
        subresourceRange = {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 6,
        },
        dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      })
    case .DIRECTIONAL, .SPOT:
      append(&initial_barriers, vk.ImageMemoryBarrier {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .UNDEFINED,
        newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = engine.frames[g_frame_index].shadow_maps[i].image,
        subresourceRange = {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 1,
        },
        dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      })
    }
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.TOP_OF_PIPE},
    {.EARLY_FRAGMENT_TESTS},
    {},
    0, nil,
    0, nil,
    u32(len(initial_barriers)), raw_data(initial_barriers),
  )
}

renderer_shadow_render :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  // Create temporary arena for batching context allocations
  temp_arena: mem.Arena
  temp_buffer := make([]u8, mem.Megabyte)
  defer delete(temp_buffer)
  mem.arena_init(&temp_arena, temp_buffer)
  temp_allocator := mem.arena_allocator(&temp_arena)
  lights := &engine.visible_lights[g_frame_index]
  for light, i in lights do if light.has_shadow {
    switch light.kind {
    case .POINT:
      cube_shadow := &engine.frames[g_frame_index].cube_shadow_maps[i]
      light_pos := light.position.xyz
      face_dirs := [6][3]f32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
      face_ups := [6][3]f32{{0, -1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}, {0, -1, 0}, {0, -1, 0}}
      for face in 0 ..< 6 {
        view := linalg.matrix4_look_at(light_pos, light_pos + face_dirs[face], face_ups[face])
        face_depth_attachment := vk.RenderingAttachmentInfoKHR {
          sType = .RENDERING_ATTACHMENT_INFO_KHR,
          imageView = cube_shadow.face_views[face],
          imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
          loadOp = .CLEAR,
          storeOp = .STORE,
          clearValue = {depthStencil = {depth = 1.0}},
        }
        face_render_info := vk.RenderingInfoKHR {
          sType = .RENDERING_INFO_KHR,
          renderArea = {extent = {width = cube_shadow.width, height = cube_shadow.height}},
          layerCount = 1,
          pDepthAttachment = &face_depth_attachment,
        }
        viewport := vk.Viewport {
          width    = f32(cube_shadow.width),
          height   = f32(cube_shadow.height),
          minDepth = 0.0,
          maxDepth = 1.0,
        }
        scissor := vk.Rect2D {
          extent = {width = cube_shadow.width, height = cube_shadow.height},
        }
        camera_uniform := data_buffer_get(&engine.shadow.frames[g_frame_index].camera_uniform, u32(i) * 6 + u32(face))
        camera_uniform.view = view
        camera_uniform.projection = light.projection
        vk.CmdBeginRenderingKHR(command_buffer, &face_render_info)
        vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
        vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
        shadow_ctx := BatchingContext {
          engine  = engine,
          frustum = geometry.make_frustum(light.projection * view),
          batches = make(map[BatchKey][dynamic]BatchData, allocator = temp_allocator),
        }
        collect_shadow_data(&shadow_ctx)
        render_shadow_batches(&shadow_ctx, command_buffer, u32(i), u32(face))
        vk.CmdEndRenderingKHR(command_buffer)
      }
    case .DIRECTIONAL, .SPOT:
      shadow_map_texture := &engine.frames[g_frame_index].shadow_maps[i]
      depth_attachment := vk.RenderingAttachmentInfoKHR {
        sType = .RENDERING_ATTACHMENT_INFO_KHR,
        imageView = shadow_map_texture.view,
        imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        loadOp = .CLEAR,
        storeOp = .STORE,
        clearValue = {depthStencil = {1.0, 0}},
      }
      render_info_khr := vk.RenderingInfoKHR {
        sType = .RENDERING_INFO_KHR,
        renderArea = {extent = {width = shadow_map_texture.width, height = shadow_map_texture.height}},
        layerCount = 1,
        pDepthAttachment = &depth_attachment,
      }
      camera_uniform := data_buffer_get(&engine.shadow.frames[g_frame_index].camera_uniform, u32(i) * 6)
      camera_uniform.view = light.view
      camera_uniform.projection = light.projection
      vk.CmdBeginRenderingKHR(command_buffer, &render_info_khr)
      viewport := vk.Viewport {
        width    = f32(shadow_map_texture.width),
        height   = f32(shadow_map_texture.height),
        minDepth = 0.0,
        maxDepth = 1.0,
      }
      scissor := vk.Rect2D {
        extent = {width = shadow_map_texture.width, height = shadow_map_texture.height},
      }
      vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
      vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
      shadow_ctx := BatchingContext {
        engine  = engine,
        frustum = geometry.make_frustum(light.projection * light.view),
        lights  = make([dynamic]LightUniform, allocator = temp_allocator),
        batches = make(map[BatchKey][dynamic]BatchData, allocator = temp_allocator),
      }
      collect_shadow_data(&shadow_ctx)
      render_shadow_batches(&shadow_ctx, command_buffer, u32(i), 0)
      vk.CmdEndRenderingKHR(command_buffer)
    }
  }
}

renderer_shadow_end :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  initial_barriers := make([dynamic]vk.ImageMemoryBarrier, 0)
  defer delete(initial_barriers)
  // Transition all shadow maps to depth attachment optimal
  for light, i in engine.visible_lights[g_frame_index] do if light.has_shadow {
    switch light.kind {
    case .POINT:
      append(&initial_barriers, vk.ImageMemoryBarrier {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .UNDEFINED,
        newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = engine.frames[g_frame_index].cube_shadow_maps[i].image,
        subresourceRange = {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 6,
        },
        dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      })
    case .DIRECTIONAL, .SPOT:
      append(&initial_barriers, vk.ImageMemoryBarrier {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .UNDEFINED,
        newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = engine.frames[g_frame_index].shadow_maps[i].image,
        subresourceRange = {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 1,
        },
        dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      })
    }
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.TOP_OF_PIPE},
    {.EARLY_FRAGMENT_TESTS},
    {},
    0, nil,
    0, nil,
    u32(len(initial_barriers)), raw_data(initial_barriers),
  )
}

renderer_shadow_get_pipeline :: proc(
  self: ^RendererShadow,
  features: ShaderFeatureSet = {},
) -> vk.Pipeline {
  // Extract only the SKINNING bit from features
  mask: u32 = 0
  if .SKINNING in features {
    mask = 1
  }
  return self.pipelines[mask]
}

// Collect all shadow-casting mesh nodes and group them by features using unified batching
collect_shadow_data :: proc(ctx: ^BatchingContext) {
  // Traverse scene and collect shadow-casting mesh nodes grouped by features
  for &entry in ctx.engine.scene.nodes.entries do if entry.active {
    node := &entry.item
    #partial switch data in node.attachment {
    case MeshAttachment:
      if !data.cast_shadow do continue
      mesh := resource.get(g_meshes, data.handle)
      if mesh == nil do continue
      material := resource.get(g_materials, data.material)
      if material == nil do continue

      world_aabb := geometry.aabb_transform(mesh.aabb, node.transform.world_matrix)
      if !geometry.frustum_test_aabb(&ctx.frustum, world_aabb) do continue
      _, mesh_has_skin := &mesh.skinning.?
      _, node_has_skin := data.skinning.?
      is_skinned := mesh_has_skin && node_has_skin
      // Create batch key based on skinning only (shadows only care about this feature)
      shadow_features: ShaderFeatureSet
      if is_skinned {
        shadow_features += {.SKINNING}
      }
      batch_key := BatchKey {
        features      = shadow_features,
        material_type = material.type, // Keep material type for consistency
      }
      batch_group, group_found := &ctx.batches[batch_key]
      if !group_found {
        ctx.batches[batch_key] = make([dynamic]BatchData, allocator = context.temp_allocator)
        batch_group = &ctx.batches[batch_key]
      }
      if len(batch_group) == 0 {
        // rendering shadow is not material dependent, we need 1 material for all
        new_batch := BatchData {
          nodes = make([dynamic]^Node, allocator = context.temp_allocator),
        }
        append(batch_group, new_batch)
      }
      append(&batch_group[0].nodes, node)
    }
  }
}

// Render shadow batches efficiently using unified batching
render_shadow_batches :: proc(
  ctx: ^BatchingContext,
  command_buffer: vk.CommandBuffer,
  shadow_idx: u32,
  shadow_layer: u32,
) {
  layout := ctx.engine.shadow.pipeline_layout
  frame := &ctx.engine.shadow.frames[g_frame_index]
  current_pipeline: vk.Pipeline = 0
  rendered_count: u32 = 0

  // Render each feature batch (minimizing pipeline switches)
  for batch_key, batch_group in ctx.batches {
    // Just extract skinning from the batch key features
    shadow_features: ShaderFeatureSet = {}
    is_skinned := .SKINNING in batch_key.features
    if is_skinned {
      shadow_features += {.SKINNING}
    }
    pipeline := renderer_shadow_get_pipeline(
      &ctx.engine.shadow,
      shadow_features,
    )
    if pipeline != current_pipeline {
      vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline)
      current_pipeline = pipeline
    }
    offset_shadow := data_buffer_offset_of(
      &frame.camera_uniform,
      shadow_idx * 6 + shadow_layer,
    )
    offsets := [1]u32{offset_shadow}
    if is_skinned {
      descriptor_sets := [?]vk.DescriptorSet {
        frame.camera_descriptor_set,
        g_bindless_bone_buffer_descriptor_set,
      }
      vk.CmdBindDescriptorSets(
        command_buffer,
        .GRAPHICS,
        layout,
        0,
        2,
        raw_data(descriptor_sets[:]),
        len(offsets),
        raw_data(offsets[:]),
      )
    } else {
      // Bind descriptor sets for static meshes
      descriptor_sets := [?]vk.DescriptorSet{frame.camera_descriptor_set}
      vk.CmdBindDescriptorSets(
        command_buffer,
        .GRAPHICS,
        layout,
        0,
        1,
        raw_data(descriptor_sets[:]),
        len(offsets),
        raw_data(offsets[:]),
      )
    }
    for batch_data in batch_group {
      for node in batch_data.nodes {
        render_single_shadow_node(
          ctx.engine,
          command_buffer,
          layout,
          node,
          is_skinned,
          &rendered_count,
        )
      }
    }
  }
}

render_single_shadow_node :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
  layout: vk.PipelineLayout,
  node: ^Node,
  is_skinned: bool,
  rendered_count: ^u32,
) {
  mesh_attachment := node.attachment.(MeshAttachment)
  mesh, found_mesh := resource.get(g_meshes, mesh_attachment.handle)
  if !found_mesh do return
  mesh_skinning, mesh_has_skin := &mesh.skinning.?
  node_skinning, node_has_skin := mesh_attachment.skinning.?
  push_constant := PushConstant {
    world = node.transform.world_matrix,
  }
  if is_skinned && node_has_skin {
    push_constant.bone_matrix_offset = node_skinning.bone_matrix_offset
  }
  vk.CmdPushConstants(
    command_buffer,
    layout,
    {.VERTEX},
    0,
    size_of(PushConstant),
    &push_constant,
  )
  offset: vk.DeviceSize = 0
  vk.CmdBindVertexBuffers(
    command_buffer,
    0,
    1,
    &mesh.vertex_buffer.buffer,
    &offset,
  )
  if is_skinned && mesh_has_skin && node_has_skin {
    vk.CmdBindVertexBuffers(
      command_buffer,
      1,
      1,
      &mesh_skinning.skin_buffer.buffer,
      &offset,
    )
  }
  vk.CmdBindIndexBuffer(command_buffer, mesh.index_buffer.buffer, 0, .UINT32)
  vk.CmdDrawIndexed(command_buffer, mesh.indices_len, 1, 0, 0, 0)
  rendered_count^ += 1
}
