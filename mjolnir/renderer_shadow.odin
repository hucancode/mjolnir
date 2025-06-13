package mjolnir

import "core:log"
import linalg "core:math/linalg"
import "geometry"
import "resource"
import vk "vendor:vulkan"

SHADER_SHADOW_VERT :: #load("shader/shadow/vert.spv")

ShadowShaderFeatures :: enum {
  SKINNING = 0,
}
ShadowShaderFeatureSet :: bit_set[ShadowShaderFeatures;u32]

SHADOW_SHADER_OPTION_COUNT: u32 : len(ShadowShaderFeatures)
SHADOW_SHADER_VARIANT_COUNT: u32 : 1 << SHADOW_SHADER_OPTION_COUNT

ShadowShaderConfig :: struct {
  is_skinned: b32,
}

RendererShadow :: struct {
  pipeline_layout:                vk.PipelineLayout,
  pipelines:                      [SHADOW_SHADER_VARIANT_COUNT]vk.Pipeline,
  camera_descriptor_set_layout:   vk.DescriptorSetLayout,
  skinning_descriptor_set_layout: vk.DescriptorSetLayout,
  frames:                         [MAX_FRAMES_IN_FLIGHT]struct {
    camera_uniform:        DataBuffer(SceneUniform),
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
  skinning_bindings := [1]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX},
    },
  }
  vk.CreateDescriptorSetLayout(
    g_device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = 1,
      pBindings = raw_data(skinning_bindings[:]),
    },
    nil,
    &self.skinning_descriptor_set_layout,
  ) or_return
  set_layouts := [?]vk.DescriptorSetLayout {
    self.camera_descriptor_set_layout,
    self.skinning_descriptor_set_layout,
  }
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX},
    size       = size_of(linalg.Matrix4f32),
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
    lineWidth               = 1.0,
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
    features := transmute(ShadowShaderFeatureSet)mask
    configs[mask] = ShadowShaderConfig {
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
      SceneUniform,
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
          range = vk.DeviceSize(size_of(SceneUniform)),
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
  vk.DestroyDescriptorSetLayout(
    g_device,
    self.skinning_descriptor_set_layout,
    nil,
  )
  self.skinning_descriptor_set_layout = 0
}

renderer_shadow_begin :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  // Transition all shadow maps to depth attachment optimal
  for light in engine.visible_lights[g_frame_index] {
    if !light.has_shadow {
      continue
    }
    initial_barriers := [?]vk.ImageMemoryBarrier {
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .UNDEFINED,
        newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = light.cube_shadow_map.image,
        subresourceRange = {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 6,
        },
        dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      },
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .UNDEFINED,
        newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = light.shadow_map.image,
        subresourceRange = {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 1,
        },
        dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      },
    }
    vk.CmdPipelineBarrier(
      command_buffer,
      {.TOP_OF_PIPE},
      {.EARLY_FRAGMENT_TESTS},
      {},
      0,
      nil,
      0,
      nil,
      len(initial_barriers),
      raw_data(initial_barriers[:]),
    )
  }
}

renderer_shadow_render :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  lights := &engine.visible_lights[g_frame_index]
  for light, i in lights {
    if !light.has_shadow {
      continue
    }
    if light.kind == .POINT {
      cube_shadow := light.cube_shadow_map
      light_pos := light.position.xyz
      face_dirs := [6][3]f32 {
        {1, 0, 0},
        {-1, 0, 0},
        {0, 1, 0},
        {0, -1, 0},
        {0, 0, 1},
        {0, 0, -1},
      }
      face_ups := [6][3]f32 {
        {0, -1, 0},
        {0, -1, 0},
        {0, 0, 1},
        {0, 0, -1},
        {0, -1, 0},
        {0, -1, 0},
      }
      for face in 0 ..< 6 {
        view := linalg.matrix4_look_at(
          light_pos,
          light_pos + face_dirs[face],
          face_ups[face],
        )
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
          renderArea = {
            extent = {width = cube_shadow.width, height = cube_shadow.height},
          },
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
        shadow_scene_uniform := data_buffer_get(
          &engine.shadow.frames[g_frame_index].camera_uniform,
          u32(i) * 6 + u32(face),
        )
        shadow_scene_uniform.view = view
        shadow_scene_uniform.projection = light.projection
        vk.CmdBeginRenderingKHR(command_buffer, &face_render_info)
        vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
        vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
        obstacles_this_light: u32 = 0
        shadow_render_ctx := ShadowRenderContext {
          engine          = engine,
          command_buffer  = command_buffer,
          obstacles_count = &obstacles_this_light,
          shadow_idx      = u32(i),
          shadow_layer    = u32(face),
          frustum         = geometry.make_frustum(light.projection * view),
        }
        scene_traverse_linear(
          &engine.scene,
          &shadow_render_ctx,
          render_single_shadow,
        )
        vk.CmdEndRenderingKHR(command_buffer)
      }
    } else {
      shadow_map_texture := light.shadow_map
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
        renderArea = {
          extent = {
            width = shadow_map_texture.width,
            height = shadow_map_texture.height,
          },
        },
        layerCount = 1,
        pDepthAttachment = &depth_attachment,
      }
      shadow_scene_uniform := data_buffer_get(
        &engine.shadow.frames[g_frame_index].camera_uniform,
        u32(i) * 6,
      )
      shadow_scene_uniform.view = light.view
      shadow_scene_uniform.projection = light.projection
      vk.CmdBeginRenderingKHR(command_buffer, &render_info_khr)
      viewport := vk.Viewport {
        width    = f32(shadow_map_texture.width),
        height   = f32(shadow_map_texture.height),
        minDepth = 0.0,
        maxDepth = 1.0,
      }
      scissor := vk.Rect2D {
        extent = {
          width = shadow_map_texture.width,
          height = shadow_map_texture.height,
        },
      }
      vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
      vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
      obstacles_this_light: u32 = 0
      shadow_render_ctx := ShadowRenderContext {
        engine          = engine,
        command_buffer  = command_buffer,
        obstacles_count = &obstacles_this_light,
        shadow_idx      = u32(i),
        frustum         = geometry.make_frustum(light.projection * light.view),
      }
      scene_traverse_linear(
        &engine.scene,
        &shadow_render_ctx,
        render_single_shadow,
      )
      vk.CmdEndRenderingKHR(command_buffer)
    }
  }
}

renderer_shadow_end :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  // Transition all shadow maps to shader read optimal
  for light in &engine.visible_lights[g_frame_index] {
    if !light.has_shadow {
      continue
    }
    final_barriers := [?]vk.ImageMemoryBarrier {
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        newLayout = .SHADER_READ_ONLY_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = light.cube_shadow_map.image,
        subresourceRange = {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 6,
        },
        srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        dstAccessMask = {.SHADER_READ},
      },
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        newLayout = .SHADER_READ_ONLY_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = light.shadow_map.image,
        subresourceRange = {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 1,
        },
        srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        dstAccessMask = {.SHADER_READ},
      },
    }
    vk.CmdPipelineBarrier(
      command_buffer,
      {.LATE_FRAGMENT_TESTS},
      {.FRAGMENT_SHADER},
      {},
      0,
      nil,
      0,
      nil,
      len(final_barriers),
      raw_data(final_barriers[:]),
    )
  }
}

renderer_shadow_get_pipeline :: proc(
  self: ^RendererShadow,
  features: ShadowShaderFeatureSet = {},
) -> vk.Pipeline {
  return self.pipelines[transmute(u32)features]
}

render_single_shadow :: proc(node: ^Node, cb_context: rawptr) -> bool {
  ctx := (^ShadowRenderContext)(cb_context)
  shadow_idx := ctx.shadow_idx
  shadow_layer := ctx.shadow_layer
  #partial switch data in node.attachment {
  case MeshAttachment:
    if !data.cast_shadow {
      return true
    }
    mesh := resource.get(g_meshes, data.handle)
    if mesh == nil {
      return true
    }
    mesh_skinning, mesh_has_skin := &mesh.skinning.?
    node_skinning, node_has_skin := data.skinning.?
    world_aabb := geometry.aabb_transform(
      mesh.aabb,
      node.transform.world_matrix,
    )
    if !geometry.frustum_test_aabb(&ctx.frustum, world_aabb) {
      return true
    }
    material := resource.get(g_materials, data.material)
    if material == nil {
      return true
    }
    pipeline: vk.Pipeline
    layout := ctx.engine.shadow.pipeline_layout
    descriptor_sets: []vk.DescriptorSet
    frame := &ctx.engine.shadow.frames[g_frame_index]
    if mesh_has_skin {
      pipeline = renderer_shadow_get_pipeline(&ctx.engine.shadow, {.SKINNING})
      descriptor_sets = {
        frame.camera_descriptor_set, // set 0 (shadow pass)
        material.skinning_descriptor_sets[g_frame_index], // set 1
      }
    } else {
      pipeline = renderer_shadow_get_pipeline(&ctx.engine.shadow)
      descriptor_sets = {
        frame.camera_descriptor_set, // set 0 (shadow pass)
      }
    }
    vk.CmdBindPipeline(ctx.command_buffer, .GRAPHICS, pipeline)
    offset_shadow := data_buffer_offset_of(
      &frame.camera_uniform,
      shadow_idx * 6 + shadow_layer,
    )
    offsets := [1]u32{offset_shadow}
    vk.CmdBindDescriptorSets(
      ctx.command_buffer,
      .GRAPHICS,
      layout,
      0,
      u32(len(descriptor_sets)),
      raw_data(descriptor_sets[:]),
      len(offsets),
      raw_data(offsets[:]),
    )
    vk.CmdPushConstants(
      ctx.command_buffer,
      layout,
      {.VERTEX},
      0,
      size_of(linalg.Matrix4f32),
      &node.transform.world_matrix,
    )
    offset: vk.DeviceSize = 0
    vk.CmdBindVertexBuffers(
      ctx.command_buffer,
      0,
      1,
      &mesh.vertex_buffer.buffer,
      &offset,
    )
    if mesh_has_skin && node_has_skin {
      material_update_bone_buffer(
        material,
        node_skinning.bone_buffers[g_frame_index].buffer,
        vk.DeviceSize(node_skinning.bone_buffers[g_frame_index].bytes_count),
        g_frame_index,
      )
      vk.CmdBindVertexBuffers(
        ctx.command_buffer,
        1,
        1,
        &mesh_skinning.skin_buffer.buffer,
        &offset,
      )
    }
    vk.CmdBindIndexBuffer(
      ctx.command_buffer,
      mesh.index_buffer.buffer,
      0,
      .UINT32,
    )
    vk.CmdDrawIndexed(ctx.command_buffer, mesh.indices_len, 1, 0, 0, 0)
    ctx.obstacles_count^ += 1
  }
  return true
}
