package world

import "core:log"
import "core:math"
import gpu "../gpu"
import geometry "../geometry"
import resources "../resources"
import vk "vendor:vulkan"

@(private)
render_depth_pass :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  task: ^VisibilityTask,
  resources_manager: ^resources.Manager,
  request: VisibilityRequest,
) {
  // Get depth texture from resources system
  depth_texture := resources.get(resources_manager.image_2d_buffers, task.depth_texture)

  // Begin dynamic rendering for depth rendering
  depth_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = depth_texture.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {depthStencil = {depth = 1.0, stencil = 0}},
  }

  render_info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {
      offset = {0, 0},
      extent = {system.depth_width, system.depth_height},
    },
    layerCount = 1,
    pDepthAttachment = &depth_attachment,
  }

  vk.CmdBeginRendering(command_buffer, &render_info)

  // Set viewport and scissor
  // Use negative height to flip Y axis (Vulkan convention: +Y down, we want +Y up)
  viewport := vk.Viewport {
    x = 0,
    y = f32(system.depth_height), // Start from bottom when using negative height
    width = f32(system.depth_width),
    height = -f32(system.depth_height), // Negative height flips Y
    minDepth = 0.0,
    maxDepth = 1.0,
  }

  scissor := vk.Rect2D {
    offset = {0, 0},
    extent = {system.depth_width, system.depth_height},
  }

  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

  // Bind depth pipeline
  if system.depth_pipeline != 0 {
    vk.CmdBindPipeline(command_buffer, .GRAPHICS, system.depth_pipeline)

    // Bind all descriptor sets like geometry renderer
    descriptor_sets := [?]vk.DescriptorSet {
      resources_manager.camera_buffer_descriptor_set,
      resources_manager.textures_descriptor_set,
      resources_manager.bone_buffer_descriptor_set,
      resources_manager.material_buffer_descriptor_set,
      resources_manager.world_matrix_descriptor_set,
      resources_manager.node_data_descriptor_set,
      resources_manager.mesh_data_descriptor_set,
      resources_manager.vertex_skinning_descriptor_set,
    }
    vk.CmdBindDescriptorSets(
      command_buffer,
      .GRAPHICS,
      system.depth_pipeline_layout,
      0,
      len(descriptor_sets),
      raw_data(descriptor_sets[:]),
      0,
      nil,
    )

    // Push camera index
    camera_index := request.camera_index
    vk.CmdPushConstants(
      command_buffer,
      system.depth_pipeline_layout,
      {.VERTEX},
      0,
      size_of(u32),
      &camera_index,
    )

    // Bind vertex and index buffers from resources
    vertex_buffers := [?]vk.Buffer{resources_manager.vertex_buffer.buffer}
    offsets := [?]vk.DeviceSize{0}
    vk.CmdBindVertexBuffers(command_buffer, 0, 1, raw_data(vertex_buffers[:]), raw_data(offsets[:]))
    vk.CmdBindIndexBuffer(command_buffer, resources_manager.index_buffer.buffer, 0, .UINT32)

    vk.CmdDrawIndexedIndirectCount(
      command_buffer,
      task.late_draw_commands.buffer,
      0, // offset
      task.late_draw_count.buffer,
      0, // count offset
      system.max_draws,
      draw_command_stride(),
    )
  }

  vk.CmdEndRendering(command_buffer)

  // No barrier here - main dispatch function handles synchronization
}

@(private)
build_depth_pyramid :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  task: ^VisibilityTask,
  resources_manager: ^resources.Manager,
) {
  // Bind depth reduction pipeline
  vk.CmdBindPipeline(command_buffer, .COMPUTE, system.depth_reduce_pipeline)

  // Generate ALL mip levels using the same shader
  // For mip 0, reads from depth texture; for others, reads from previous mip
  for mip in 0 ..< task.depth_pyramid.mip_levels {
    // Bind descriptor set for this mip level
    vk.CmdBindDescriptorSets(
      command_buffer,
      .COMPUTE,
      system.depth_reduce_layout,
      0,
      1,
      &task.depth_reduce_descriptor_sets[mip],
      0,
      nil,
    )

    // Push constants with current mip level
    push_constants := DepthReducePushConstants {
      current_mip = u32(mip),
    }

    vk.CmdPushConstants(
      command_buffer,
      system.depth_reduce_layout,
      {.COMPUTE},
      0,
      size_of(push_constants),
      &push_constants,
    )

    // Calculate dispatch size for this mip level
    // Use pyramid dimensions, not depth texture dimensions!
    mip_width := max(1, task.depth_pyramid.width >> mip)
    mip_height := max(1, task.depth_pyramid.height >> mip)
    dispatch_x := (mip_width + 31) / 32
    dispatch_y := (mip_height + 31) / 32

    vk.CmdDispatch(command_buffer, dispatch_x, dispatch_y, 1)

    // Only synchronize the dependency chain, don't transition layouts
    if mip < task.depth_pyramid.mip_levels - 1 {
      vk.CmdPipelineBarrier(
        command_buffer,
        {.COMPUTE_SHADER},
        {.COMPUTE_SHADER},
        {},
        0,
        nil,
        0,
        nil,
        0,
        nil,
      )
    }
  }

  // Get pyramid texture from resources system
  pyramid_texture := resources.get(resources_manager.image_2d_buffers, task.depth_pyramid.texture)

  // Final layout transition for ALL mips at once after generation completes
  final_barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    srcAccessMask = {.SHADER_WRITE},
    dstAccessMask = {.SHADER_READ},
    oldLayout = .GENERAL,
    newLayout = .SHADER_READ_ONLY_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = pyramid_texture.image,
    subresourceRange = {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = task.depth_pyramid.mip_levels,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.COMPUTE_SHADER},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &final_barrier,
  )
}

@(private)
execute_late_pass :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  task: ^VisibilityTask,
  request: VisibilityRequest,
  resources_manager: ^resources.Manager,
) {
  // Bind late pass pipeline and descriptor set
  vk.CmdBindPipeline(command_buffer, .COMPUTE, system.late_cull_pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    system.late_cull_layout,
    0,
    1,
    &task.late_descriptor_set,
    0,
    nil,
  )

  // Push constants with occlusion enabled
  push_constants := VisibilityPushConstants {
    camera_index      = request.camera_index,
    node_count        = system.node_count,
    max_draws         = system.max_draws,
    include_flags     = request.include_flags,
    exclude_flags     = request.exclude_flags,
    pyramid_width     = f32(task.depth_pyramid.width),
    pyramid_height    = f32(task.depth_pyramid.height),
    depth_bias        = system.depth_bias,
    occlusion_enabled = 1, // Enable occlusion test
  }

  vk.CmdPushConstants(
    command_buffer,
    system.late_cull_layout,
    {.COMPUTE},
    0,
    size_of(push_constants),
    &push_constants,
  )

  // Dispatch compute shader
  dispatch_x := (system.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_x, 1, 1)
}

@(private)
log_culling_stats :: proc(
  system: ^VisibilitySystem,
  frame_index: u32,
  category: VisibilityCategory,
  task: ^VisibilityTask,
) {
  // Read draw counts from mapped memory
  late_count: u32 = 0

  if task.late_draw_count.mapped != nil {
    late_count = task.late_draw_count.mapped[0]
  }

  // Calculate culling efficiency
  efficiency: f32 = 0.0
  if system.node_count > 0 {
    efficiency = f32(late_count) / f32(system.node_count) * 100.0
  }

  log.infof("[Frame %d][%v] Culling Stats: Total Objects=%d | Late Pass=%d | Efficiency=%.1f%%",
    frame_index,
    category,
    system.node_count,
    late_count,
    efficiency,
  )
}
