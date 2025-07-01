package mjolnir

import "core:fmt"
import "core:log"
import "core:mem"
import "core:time"
import "geometry"
import "resource"
import mu "vendor:microui"
import vk "vendor:vulkan"

SHADER_DEPTH_PREPASS_VERT :: #load("shader/depth_prepass/vert.spv")

DEPTH_PREPASS_OPTION_COUNT :: 1
DEPTH_PREPASS_VARIANT_COUNT: u32 : 1 << DEPTH_PREPASS_OPTION_COUNT

RendererDepthPrepass :: struct {
  pipeline_layout: vk.PipelineLayout,
  pipelines:       [DEPTH_PREPASS_VARIANT_COUNT]vk.Pipeline,
}

renderer_depth_prepass_init :: proc(
  self: ^RendererDepthPrepass,
  swapchain_extent: vk.Extent2D,
) -> (
  res: vk.Result,
) {
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX},
    size       = size_of(PushConstant),
  }
  set_layouts := [?]vk.DescriptorSetLayout {
    g_camera_descriptor_set_layout, // set = 0 (camera uniforms)
    g_bindless_bone_buffer_set_layout, // set = 1 (for skinning)
  }
  pipeline_layout_info := vk.PipelineLayoutCreateInfo {
    sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount         = len(set_layouts),
    pSetLayouts            = raw_data(set_layouts[:]),
    pushConstantRangeCount = 1,
    pPushConstantRanges    = &push_constant_range,
  }
  vk.CreatePipelineLayout(
    g_device,
    &pipeline_layout_info,
    nil,
    &self.pipeline_layout,
  ) or_return
  for mask in 0 ..< DEPTH_PREPASS_VARIANT_COUNT {
    features := transmute(ShaderFeatureSet)mask & ShaderFeatureSet{.SKINNING}
    config := ShaderConfig {
      is_skinned = .SKINNING in features,
    }
    renderer_depth_prepass_build_pipeline(
      self,
      &config,
      &self.pipelines[mask],
      swapchain_extent,
    ) or_return
  }
  return .SUCCESS
}

renderer_depth_prepass_deinit :: proc(self: ^RendererDepthPrepass) {
  for &p in self.pipelines {
    vk.DestroyPipeline(g_device, p, nil)
    p = 0
  }
  vk.DestroyPipelineLayout(g_device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}

renderer_depth_prepass_begin :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  // Use global g_frame_index
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = engine.frames[g_frame_index].depth_buffer.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {depthStencil = {1.0, 0}},
  }
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = engine.swapchain.extent},
    layerCount = 1,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0.0,
    y        = f32(engine.swapchain.extent.height),
    width    = f32(engine.swapchain.extent.width),
    height   = -f32(engine.swapchain.extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  scissor := vk.Rect2D {
    offset = {x = 0, y = 0},
    extent = engine.swapchain.extent,
  }
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
  camera_uniform := data_buffer_get(
    &engine.frames[g_frame_index].camera_uniform,
  )
  camera_uniform.view = geometry.calculate_view_matrix(engine.scene.camera)
  camera_uniform.projection = geometry.calculate_projection_matrix(
    engine.scene.camera,
  )
}

renderer_depth_prepass_end :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  vk.CmdEndRenderingKHR(command_buffer)
}

renderer_depth_prepass_render :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
) {
  camera_frustum := geometry.camera_make_frustum(engine.scene.camera)
  temp_arena: mem.Arena
  temp_allocator_buffer := make([]u8, mem.Megabyte) // 1MB should be enough for depth pre-pass batching
  defer delete(temp_allocator_buffer)
  mem.arena_init(&temp_arena, temp_allocator_buffer)
  temp_allocator := mem.arena_allocator(&temp_arena)
  batching_ctx := BatchingContext {
    engine  = engine,
    frustum = camera_frustum,
    lights  = make([dynamic]LightUniform, temp_allocator),
    batches = make(map[BatchKey][dynamic]BatchData, temp_allocator),
  }
  renderer_depth_prepass_populate_batches(&batching_ctx)
  layout := engine.depth_prepass.pipeline_layout
  descriptor_sets := [?]vk.DescriptorSet {
    g_camera_descriptor_sets[g_frame_index], // set 0
    g_bindless_bone_buffer_descriptor_set, // set 1
  }
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    layout,
    0,
    len(descriptor_sets),
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )
  rendered_count := renderer_depth_prepass_render_batches(
    &engine.depth_prepass,
    &batching_ctx,
    command_buffer,
  )
  if mu.window(
    &engine.ui.ctx,
    "Depth Pre-pass",
    {360, 200, 300, 100},
    {.NO_CLOSE},
  ) {
    mu.label(&engine.ui.ctx, fmt.tprintf("Pre-pass: %v", rendered_count))
    mu.label(
      &engine.ui.ctx,
      fmt.tprintf("Batches: %v", len(batching_ctx.batches)),
    )
  }
}

// Populate batches for depth prepass rendering
renderer_depth_prepass_populate_batches :: proc(ctx: ^BatchingContext) {
  for &entry in ctx.engine.scene.nodes.entries do if entry.active {
    node := &entry.item
    #partial switch data in node.attachment {
    case MeshAttachment:
      mesh, found_mesh := resource.get(g_meshes, data.handle)
      if !found_mesh do continue
      material, found_mat := resource.get(g_materials, data.material)
      if !found_mat do continue
      // Skip transparent and wireframe materials in depth pre-pass
      // Wireframe materials need to write their own depth with bias
      if material.type == .WIREFRAME {
        continue
      }
      world_aabb := geometry.aabb_transform(mesh.aabb, node.transform.world_matrix)
      if !geometry.frustum_test_aabb(&ctx.frustum, world_aabb) do continue
      // Depth prepass only cares about skinning
      depth_features := material.features & ShaderFeatureSet{.SKINNING}
      batch_key := BatchKey {
        features      = depth_features,
        material_type = material.type,
      }
      // Find or create batch group for this feature set
      batch_group, group_found := &ctx.batches[batch_key]
      if !group_found {
        ctx.batches[batch_key] = make([dynamic]BatchData, allocator = context.temp_allocator)
        batch_group = &ctx.batches[batch_key]
      }
      // Find or create batch data for this specific material within the group
      batch_data: ^BatchData = nil
      for &batch in batch_group {
        if batch.material_handle == data.material {
          batch_data = &batch
          break
        }
      }
      if batch_data == nil {
        new_batch := BatchData {
          material_handle = data.material,
          nodes           = make([dynamic]^Node, allocator = context.temp_allocator),
        }
        append(batch_group, new_batch)
        batch_data = &batch_group[len(batch_group) - 1]
      }
      append(&batch_data.nodes, node)
    }
  }
}

renderer_depth_prepass_render_batches :: proc(
  self: ^RendererDepthPrepass,
  ctx: ^BatchingContext,
  command_buffer: vk.CommandBuffer,
) -> int {
  rendered := 0
  current_pipeline: vk.Pipeline = 0
  for batch_key, batch_group in ctx.batches {
    if batch_key.material_type == .WIREFRAME {
      continue
    }
    for batch_data in batch_group {
      material := resource.get(
        g_materials,
        batch_data.material_handle,
      ) or_continue
      for node in batch_data.nodes {
        #partial switch data in node.attachment {
        case MeshAttachment:
          mesh := resource.get(g_meshes, data.handle) or_continue
          mesh_skinning, mesh_has_skin := &mesh.skinning.?
          node_skinning, node_has_skin := data.skinning.?
          pipeline := renderer_depth_prepass_get_pipeline(
            self,
            material,
            mesh,
            data,
          )
          if pipeline != current_pipeline {
            vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline)
            current_pipeline = pipeline
          }
          push_constant := PushConstant {
            world = node.transform.world_matrix,
          }
          if node_has_skin {
            push_constant.bone_matrix_offset =
              node_skinning.bone_matrix_offset +
              g_frame_index * g_bone_matrix_slab.capacity
          }
          vk.CmdPushConstants(
            command_buffer,
            self.pipeline_layout,
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
          if mesh_has_skin {
            vk.CmdBindVertexBuffers(
              command_buffer,
              1,
              1,
              &mesh_skinning.skin_buffer.buffer,
              &offset,
            )
          }
          vk.CmdBindIndexBuffer(
            command_buffer,
            mesh.index_buffer.buffer,
            0,
            .UINT32,
          )
          vk.CmdDrawIndexed(command_buffer, mesh.indices_len, 1, 0, 0, 0)
          rendered += 1
        }
      }
    }
  }
  return rendered
}

renderer_depth_prepass_get_pipeline :: proc(
  self: ^RendererDepthPrepass,
  material: ^Material,
  mesh: ^Mesh,
  data: MeshAttachment,
) -> vk.Pipeline {
  features := material.features & ShaderFeatureSet{.SKINNING}
  return self.pipelines[transmute(u32)features]
}

renderer_depth_prepass_build_pipeline :: proc(
  self: ^RendererDepthPrepass,
  config: ^ShaderConfig,
  pipeline: ^vk.Pipeline,
  swapchain_extent: vk.Extent2D,
) -> (
  res: vk.Result,
) {
  log.debugf("Building depth prepass pipeline with config: %v", config)
  vert_shader_module := create_shader_module(
    SHADER_DEPTH_PREPASS_VERT,
  ) or_return
  defer vk.DestroyShaderModule(g_device, vert_shader_module, nil)
  entry := vk.SpecializationMapEntry {
    constantID = 0,
    offset     = u32(offset_of(ShaderConfig, is_skinned)),
    size       = size_of(b32),
  }
  spec_info := vk.SpecializationInfo {
    mapEntryCount = 1,
    pMapEntries   = &entry,
    dataSize      = size_of(ShaderConfig),
    pData         = config,
  }
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_shader_module,
      pName = "main",
      pSpecializationInfo = &spec_info,
    },
  }
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
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology               = .TRIANGLE_LIST,
    primitiveRestartEnable = false,
  }
  viewport := vk.Viewport {
    x        = 0.0,
    y        = f32(swapchain_extent.height),
    width    = f32(swapchain_extent.width),
    height   = -f32(swapchain_extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = swapchain_extent,
  }
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    pViewports    = &viewport,
    scissorCount  = 1,
    pScissors     = &scissor,
  }
  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode             = .FILL,
    cullMode                = {.BACK},
    frontFace               = .COUNTER_CLOCKWISE,
    depthBiasEnable         = true,
    depthBiasConstantFactor = 0.1,
    depthBiasSlopeFactor    = 0.2,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    sampleShadingEnable  = false,
    rasterizationSamples = {._1},
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
  }
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable       = true,
    depthWriteEnable      = true,
    depthCompareOp        = .LESS,
    depthBoundsTestEnable = false,
    stencilTestEnable     = false,
  }
  dynamic_rendering := vk.PipelineRenderingCreateInfoKHR {
    sType                 = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    depthAttachmentFormat = .D32_SFLOAT,
  }
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &dynamic_rendering,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pDepthStencilState  = &depth_stencil,
    pColorBlendState    = &color_blending,
    pDynamicState       = &dynamic_state,
    layout              = self.pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    g_device,
    0,
    1,
    &pipeline_info,
    nil,
    pipeline,
  ) or_return
  return .SUCCESS
}
