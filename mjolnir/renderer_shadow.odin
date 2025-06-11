package mjolnir

import "core:log"
import "core:math"
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
  pipeline_layout: vk.PipelineLayout,
  pipelines:       [SHADOW_SHADER_VARIANT_COUNT]vk.Pipeline,
  camera_descriptor_set_layout: vk.DescriptorSetLayout,
  skinning_descriptor_set_layout: vk.DescriptorSetLayout,
}

renderer_shadow_init :: proc(
  self: ^RendererShadow,
  depth_format: vk.Format = .D32_SFLOAT,
) -> vk.Result {
  // Create dedicated camera descriptor set layout for shadow
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
  // Create dedicated skinning descriptor set layout for shadow
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
  return .SUCCESS
}

renderer_shadow_deinit :: proc(self: ^RendererShadow) {
  for &p in self.pipelines {
    vk.DestroyPipeline(g_device, p, nil)
    p = 0
  }
  vk.DestroyPipelineLayout(g_device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
  vk.DestroyDescriptorSetLayout(g_device, self.camera_descriptor_set_layout, nil)
  self.camera_descriptor_set_layout = 0
  vk.DestroyDescriptorSetLayout(g_device, self.skinning_descriptor_set_layout, nil)
  self.skinning_descriptor_set_layout = 0
}

render_shadow_pass :: proc(
  engine: ^Engine,
  light_uniform: ^SceneLightUniform,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  renderer := &engine.renderer
  for i := 0; i < int(light_uniform.light_count); i += 1 {
    cube_shadow := renderer_get_cube_shadow_map(renderer, i)
    shadow_map_texture := renderer_get_shadow_map(renderer, i)
    // Transition shadow map to depth attachment
    initial_barriers := [?]vk.ImageMemoryBarrier {
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .UNDEFINED,
        newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = cube_shadow.image,
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
        image = shadow_map_texture.image,
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
  for i := 0; i < int(light_uniform.light_count); i += 1 {
    light := &light_uniform.lights[i]
    if !light.has_shadow || i >= MAX_SHADOW_MAPS {
      continue
    }
    if light.kind == .POINT {
      cube_shadow := renderer_get_cube_shadow_map(renderer, i)
      light_pos := light.position.xyz
      // Cube face directions and up vectors
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
      proj := linalg.matrix4_perspective(
        math.PI * 0.5,
        1.0,
        0.01,
        light.radius,
      )
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
            extent = {
              width = cube_shadow.width,
              height = cube_shadow.height,
            },
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
          extent = {
            width = cube_shadow.width,
            height = cube_shadow.height,
          },
        }
        shadow_scene_uniform := SceneUniform {
          view       = view,
          projection = proj,
        }
        data_buffer_write(
          renderer_get_camera_uniform(renderer),
          &shadow_scene_uniform,
          i * 6 + face + 1,
        )
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
          frustum         = geometry.make_frustum(proj * view),
        }
        scene_traverse_linear(
          &engine.scene,
          &shadow_render_ctx,
          render_single_shadow,
        )
        vk.CmdEndRenderingKHR(command_buffer)
      }
    } else {
      shadow_map_texture := renderer_get_shadow_map(renderer, i)
      view: linalg.Matrix4f32
      proj: linalg.Matrix4f32
      if light.kind == .DIRECTIONAL {
        view = linalg.matrix4_look_at(
          light.position.xyz,
          light.position.xyz + light.direction.xyz,
          linalg.VECTOR3F32_Y_AXIS,
        )
        ortho_size: f32 = 20.0
        proj = linalg.matrix_ortho3d(
          -ortho_size,
          ortho_size,
          -ortho_size,
          ortho_size,
          0.1,
          light.radius,
        )
      } else {
        view = linalg.matrix4_look_at(
          light.position.xyz,
          light.position.xyz + light.direction.xyz,
          linalg.VECTOR3F32_X_AXIS,
          // TODO: hardcoding up vector will not work if the light is perfectly aligned with said vector
        )
        proj = linalg.matrix4_perspective(light.angle, 1.0, 0.01, light.radius)
      }
      light.view_proj = proj * view
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
      shadow_scene_uniform := SceneUniform {
        view       = view,
        projection = proj,
      }
      data_buffer_write(
        renderer_get_camera_uniform(renderer),
        &shadow_scene_uniform,
        i * 6 + 1,
      )
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
        frustum         = geometry.make_frustum(proj * view),
      }
      scene_traverse_linear(
        &engine.scene,
        &shadow_render_ctx,
        render_single_shadow,
      )
      vk.CmdEndRenderingKHR(command_buffer)
    }
  }
  for i := 0; i < int(light_uniform.light_count); i += 1 {
    cube_shadow := renderer_get_cube_shadow_map(renderer, i)
    shadow_map_texture := renderer_get_shadow_map(renderer, i)
    final_barriers := [?]vk.ImageMemoryBarrier {
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        newLayout = .SHADER_READ_ONLY_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = cube_shadow.image,
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
        image = shadow_map_texture.image,
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
  return .SUCCESS
}

render_single_shadow :: proc(node: ^Node, cb_context: rawptr) -> bool {
  ctx := (^ShadowRenderContext)(cb_context)
  frame := ctx.engine.renderer.frame_index
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
    layout := ctx.engine.renderer.shadow.pipeline_layout
    descriptor_sets: []vk.DescriptorSet
    shadow_frame := &ctx.engine.renderer.frames[frame]
    if mesh_has_skin {
      pipeline = renderer_shadow_get_pipeline(
        &ctx.engine.renderer.shadow,
        {.SKINNING},
      )
      descriptor_sets = {
        shadow_frame.shadow_camera_descriptor_set, // set 0 (shadow pass)
        material.skinning_descriptor_sets[frame], // set 1
      }
    } else {
      pipeline = renderer_shadow_get_pipeline(&ctx.engine.renderer.shadow)
      descriptor_sets = {
        shadow_frame.shadow_camera_descriptor_set, // set 0 (shadow pass)
      }
    }
    vk.CmdBindPipeline(ctx.command_buffer, .GRAPHICS, pipeline)
    offset_shadow := data_buffer_offset_of(
      renderer_get_camera_uniform(&ctx.engine.renderer)^,
      1 + shadow_idx * 6 + shadow_layer,
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
        node_skinning.bone_buffers[frame].buffer,
        vk.DeviceSize(node_skinning.bone_buffers[frame].bytes_count),
        frame,
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

renderer_shadow_get_pipeline :: proc(
  self: ^RendererShadow,
  features: ShadowShaderFeatureSet = {},
) -> vk.Pipeline {
  return self.pipelines[transmute(u32)features]
}
