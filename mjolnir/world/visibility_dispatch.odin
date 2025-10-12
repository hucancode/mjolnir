package world

import "core:log"
import "core:math"
import gpu "../gpu"
import geometry "../geometry"
import resources "../resources"
import vk "vendor:vulkan"

// Main dispatch function for 2-pass occlusion culling
visibility_system_dispatch_2pass :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  task_category: VisibilityCategory,
  request: VisibilityRequest,
  resources_manager: ^resources.Manager,
) -> VisibilityResult {
  result := VisibilityResult {
    draw_buffer    = 0,
    count_buffer   = 0,
    command_stride = draw_command_stride(),
  }

  if system.node_count == 0 {
    return result
  }

  if frame_index >= resources.MAX_FRAMES_IN_FLIGHT {
    log.errorf("visibility_system_dispatch_2pass: invalid frame index %d", frame_index)
    return result
  }

  frame := &system.frames[frame_index]
  task := &frame.tasks[int(task_category)]

  // Always use 2-pass occlusion culling

  // Clear buffers
  vk.CmdFillBuffer(
    command_buffer,
    task.early_draw_count.buffer,
    0,
    vk.DeviceSize(task.early_draw_count.bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    task.late_draw_count.buffer,
    0,
    vk.DeviceSize(task.late_draw_count.bytes_count),
    0,
  )

  // === STEP 1: EARLY PASS COMPUTE ===
  // Use previous frame's visibility to conservatively cull
  execute_early_pass(
    system,
    gpu_context,
    command_buffer,
    frame_index,
    task,
    request,
    resources_manager,
  )

  // Barrier: Wait for early compute to finish before graphics can read draw commands
  early_compute_done := vk.BufferMemoryBarrier {
    sType         = .BUFFER_MEMORY_BARRIER,
    srcAccessMask = {.SHADER_WRITE},
    dstAccessMask = {.INDIRECT_COMMAND_READ},
    buffer        = task.early_draw_commands.buffer,
    size          = vk.DeviceSize(task.early_draw_commands.bytes_count),
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
    {},
    0,
    nil,
    1,
    &early_compute_done,
    0,
    nil,
  )

  // === STEP 2: RENDER DEPTH FROM EARLY PASS ===
  render_depth_pass(
    system,
    gpu_context,
    command_buffer,
    frame_index,
    task,
    resources_manager,
    request,
    true, // early pass
  )

  // Barrier: Wait for depth rendering to finish before compute shader reads it
  depth_render_done := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    dstAccessMask = {.SHADER_READ},
    oldLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
    newLayout = .SHADER_READ_ONLY_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = task.depth_texture.image,
    subresourceRange = {
      aspectMask = {.DEPTH},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.LATE_FRAGMENT_TESTS},
    {.COMPUTE_SHADER},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &depth_render_done,
  )

  // === STEP 3: BUILD DEPTH PYRAMID ===
  // This copies depth to pyramid mip 0, then generates all mip levels
  // (includes final barrier inside the function)
  build_depth_pyramid(
    system,
    gpu_context,
    command_buffer,
    task,
  )

  // === STEP 4: LATE PASS COMPUTE ===
  // Full frustum + occlusion culling using depth pyramid
  execute_late_pass(
    system,
    gpu_context,
    command_buffer,
    frame_index,
    task,
    request,
    resources_manager,
  )

  // Barrier: Wait for late pass compute to finish before anyone reads the draw commands
  late_compute_done := [?]vk.BufferMemoryBarrier{
    {
      sType         = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.SHADER_WRITE},
      dstAccessMask = {.INDIRECT_COMMAND_READ},
      buffer        = task.late_draw_commands.buffer,
      size          = vk.DeviceSize(task.late_draw_commands.bytes_count),
    },
    {
      sType         = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.SHADER_WRITE},
      dstAccessMask = {.INDIRECT_COMMAND_READ},
      buffer        = task.late_draw_count.buffer,
      size          = vk.DeviceSize(task.late_draw_count.bytes_count),
    },
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
    {},
    0,
    nil,
    len(late_compute_done),
    raw_data(late_compute_done[:]),
    0,
    nil,
  )

  // Set result to late pass draw buffer (final visibility)
  result.draw_buffer = task.late_draw_commands.buffer
  result.count_buffer = task.late_draw_count.buffer

  // Log draw counts if statistics are enabled
  if system.stats_enabled {
    log_culling_stats(system, frame_index, task_category, task)
  }

  return result
}

@(private)
execute_early_pass :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  task: ^VisibilityTask,
  request: VisibilityRequest,
  resources_manager: ^resources.Manager,
) {
  // Barrier: Ensure buffers are ready
  buffer_barriers := [?]vk.BufferMemoryBarrier {
    {
      sType         = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.TRANSFER_WRITE},
      dstAccessMask = {.SHADER_WRITE},
      buffer        = task.early_draw_count.buffer,
      size          = vk.DeviceSize(task.early_draw_count.bytes_count),
    },
    {
      sType         = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.TRANSFER_WRITE},
      dstAccessMask = {.SHADER_WRITE},
      buffer        = task.early_draw_commands.buffer,
      size          = vk.DeviceSize(task.early_draw_commands.bytes_count),
    },
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.TRANSFER},
    {.COMPUTE_SHADER},
    {},
    0,
    nil,
    len(buffer_barriers),
    raw_data(buffer_barriers[:]),
    0,
    nil,
  )

  // Bind early pass pipeline and descriptor set
  vk.CmdBindPipeline(command_buffer, .COMPUTE, system.early_cull_pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    system.early_cull_layout,
    0,
    1,
    &task.early_descriptor_set,
    0,
    nil,
  )

  // Push constants
  push_constants := VisibilityPushConstants {
    camera_index      = request.camera_index,
    node_count        = system.node_count,
    max_draws         = system.max_draws,
    include_flags     = request.include_flags,
    exclude_flags     = request.exclude_flags,
    pyramid_width     = f32(task.depth_pyramid.width),  // Use pyramid dimensions, not depth texture
    pyramid_height    = f32(task.depth_pyramid.height),
    depth_bias        = system.depth_bias,
    occlusion_enabled = 0, // No occlusion test in early pass
  }

  vk.CmdPushConstants(
    command_buffer,
    system.early_cull_layout,
    {.COMPUTE},
    0,
    size_of(push_constants),
    &push_constants,
  )

  // Dispatch compute shader
  dispatch_x := (system.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_x, 1, 1)

  // No barrier here - main dispatch function handles synchronization
}

@(private)
render_depth_pass :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  task: ^VisibilityTask,
  resources_manager: ^resources.Manager,
  request: VisibilityRequest,
  is_early_pass: bool,
) {
  // Begin render pass for depth rendering
  clear_value := vk.ClearValue {
    depthStencil = {depth = 1.0, stencil = 0}, // Clear to far depth
  }

  render_pass_begin := vk.RenderPassBeginInfo {
    sType = .RENDER_PASS_BEGIN_INFO,
    renderPass = task.depth_render_pass,
    framebuffer = task.depth_framebuffer,
    renderArea = {
      offset = {0, 0},
      extent = {system.depth_width, system.depth_height},
    },
    clearValueCount = 1,
    pClearValues = &clear_value,
  }

  vk.CmdBeginRenderPass(command_buffer, &render_pass_begin, .INLINE)

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

    // Issue indirect draw call using early pass draw commands
    draw_buffer := is_early_pass ? task.early_draw_commands.buffer : task.late_draw_commands.buffer
    count_buffer := is_early_pass ? task.early_draw_count.buffer : task.late_draw_count.buffer

    vk.CmdDrawIndexedIndirectCount(
      command_buffer,
      draw_buffer,
      0, // offset
      count_buffer,
      0, // count offset
      system.max_draws,
      draw_command_stride(),
    )
  }

  vk.CmdEndRenderPass(command_buffer)

  // No barrier here - main dispatch function handles synchronization
}

@(private)
build_depth_pyramid :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  task: ^VisibilityTask,
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

  // Final layout transition for ALL mips at once after generation completes
  final_barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    srcAccessMask = {.SHADER_WRITE},
    dstAccessMask = {.SHADER_READ},
    oldLayout = .GENERAL,
    newLayout = .SHADER_READ_ONLY_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = task.depth_pyramid.texture.image,
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
  // Note: Buffers already cleared at start of dispatch - no need to clear again

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

  // No barrier here - main dispatch function handles synchronization
}

@(private)
log_culling_stats :: proc(
  system: ^VisibilitySystem,
  frame_index: u32,
  category: VisibilityCategory,
  task: ^VisibilityTask,
) {
  // Read draw counts from mapped memory
  early_count: u32 = 0
  late_count: u32 = 0

  if task.early_draw_count.mapped != nil {
    early_count = task.early_draw_count.mapped[0]
  }

  if task.late_draw_count.mapped != nil {
    late_count = task.late_draw_count.mapped[0]
  }

  // Calculate culling efficiency
  efficiency: f32 = 0.0
  if system.node_count > 0 {
    efficiency = f32(late_count) / f32(system.node_count) * 100.0
  }

  reduction: f32 = 0.0
  if early_count > 0 {
    reduction = (1.0 - f32(late_count) / f32(early_count)) * 100.0
  }

  log.infof("[Frame %d][%s] Culling Stats: Total Objects=%d | Early Pass=%d | Late Pass=%d | Efficiency=%.1f%% | Occlusion Reduction=%.1f%%",
    frame_index,
    visibility_category_name(category),
    system.node_count,
    early_count,
    late_count,
    efficiency,
    reduction
  )
}

// Legacy fallback for simple frustum culling
@(private)
visibility_system_dispatch_legacy :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  task_category: VisibilityCategory,
  request: VisibilityRequest,
) -> VisibilityResult {
  // This would use the original frustum-only culling implementation
  // For now, return empty result
  return VisibilityResult {
    draw_buffer    = 0,
    count_buffer   = 0,
    command_stride = draw_command_stride(),
  }
}
