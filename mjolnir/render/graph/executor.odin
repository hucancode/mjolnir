package render_graph

import "core:log"
import vk "vendor:vulkan"

// ============================================================================
// PUBLIC API - EXECUTE PHASE
// ============================================================================

// Execute graph for a frame with automatic barrier insertion
graph_execute :: proc(
  g: ^Graph,
  cmd: vk.CommandBuffer,
  frame_index: u32,
) -> Result {
  exec_ctx: ^GraphExecutionContext = nil
  if g.has_exec_ctx {
    exec_ctx = &g.exec_ctx
  }

  for pass_id in g.execution_order {
    pass := &g.passes[pass_id]

    // Insert barriers before pass
    if barriers, has_barriers := g.barriers[pass_id]; has_barriers {
      _emit_pass_barriers(g, cmd, barriers[:], frame_index)
    }

    resources := _build_pass_resources(g, pass, frame_index)

    // Execute pass
    ctx := PassContext {
      graph       = g,
      exec_ctx    = exec_ctx,
      resources   = resources,
      frame_index = frame_index,
      scope_index = pass.scope_index,
      cmd         = cmd,
    }
    pass.execute(&ctx)
    delete(ctx.resources)
  }

  log.infof("Executed %d passes", len(g.execution_order))
  return .SUCCESS
}

// ============================================================================
// PRIVATE HELPERS
// ============================================================================

@(private)
_append_pass_resource :: proc(
  g: ^Graph,
  resources: ^map[ResourceKey]Resource,
  key: ResourceKey,
  frame_index: u32,
) {
  if _, exists := resources[key]; exists {
    return
  }

  handle, ok := graph_get_resolved_resource(
    g,
    key.index,
    frame_index,
    key.scope_index,
  )
  if !ok do return

  resources[key] = handle
}

@(private)
_build_pass_resources :: proc(
  g: ^Graph,
  pass: ^PassInstance,
  frame_index: u32,
) -> map[ResourceKey]Resource {
  resources := make(map[ResourceKey]Resource)

  for key in pass.inputs {
    _append_pass_resource(g, &resources, key, frame_index)
  }
  for key in pass.outputs {
    _append_pass_resource(g, &resources, key, frame_index)
  }

  return resources
}

@(private)
_emit_pass_barriers :: proc(
  g: ^Graph,
  cmd: vk.CommandBuffer,
  barriers: []Barrier,
  frame_index: u32,
) {
  if len(barriers) == 0 do return

  buffer_barriers := make(
    [dynamic]vk.BufferMemoryBarrier,
    0,
    len(barriers),
    context.temp_allocator,
  )
  image_barriers := make(
    [dynamic]vk.ImageMemoryBarrier,
    0,
    len(barriers),
    context.temp_allocator,
  )

  src_stage := vk.PipelineStageFlags{}
  dst_stage := vk.PipelineStageFlags{}

  for barrier in barriers {
    desc, ok := g.resources[barrier.resource_key]
    if !ok {
      log.warnf(
        "Failed to find resource descriptor for index=%v scope=%d",
        barrier.resource_key.index,
        barrier.resource_key.scope_index,
      )
      continue
    }

    handle, handle_ok := graph_get_resolved_resource(
      g,
      barrier.resource_key.index,
      frame_index,
      barrier.resource_key.scope_index,
    )
    if !handle_ok {
      // Resource may be inactive for this frame/scope or missing due to setup.
      continue
    }

    src_stage |= barrier.src_stage
    dst_stage |= barrier.dst_stage

    switch h in handle {
    case Buffer:
      append(
        &buffer_barriers,
        vk.BufferMemoryBarrier {
          sType = .BUFFER_MEMORY_BARRIER,
          srcAccessMask = barrier.src_access,
          dstAccessMask = barrier.dst_access,
          srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
          dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
          buffer = h.buffer,
          offset = 0,
          size = h.size,
        },
      )

    case Texture:
      level_count := u32(1)
      if tex_format, has_format := desc.format.(TextureFormat);
         has_format && tex_format.mip_levels > 0 {
        level_count = tex_format.mip_levels
      }
      append(
        &image_barriers,
        vk.ImageMemoryBarrier {
          sType = .IMAGE_MEMORY_BARRIER,
          srcAccessMask = barrier.src_access,
          dstAccessMask = barrier.dst_access,
          oldLayout = barrier.old_layout,
          newLayout = barrier.new_layout,
          srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
          dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
          image = h.image,
          subresourceRange = {
            aspectMask = {.COLOR},
            baseMipLevel = 0,
            levelCount = level_count,
            baseArrayLayer = 0,
            layerCount = 1,
          },
        },
      )

    case DepthTexture:
      append(
        &image_barriers,
        vk.ImageMemoryBarrier {
          sType = .IMAGE_MEMORY_BARRIER,
          srcAccessMask = barrier.src_access,
          dstAccessMask = barrier.dst_access,
          oldLayout = barrier.old_layout,
          newLayout = barrier.new_layout,
          srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
          dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
          image = h.image,
          subresourceRange = {
            aspectMask = {.DEPTH},
            baseMipLevel = 0,
            levelCount = 1,
            baseArrayLayer = 0,
            layerCount = 1,
          },
        },
      )
    }
  }

  if len(buffer_barriers) == 0 && len(image_barriers) == 0 {
    return
  }

  buffer_ptr: ^vk.BufferMemoryBarrier = nil
  image_ptr: ^vk.ImageMemoryBarrier = nil
  if len(buffer_barriers) > 0 {
    buffer_ptr = raw_data(buffer_barriers[:])
  }
  if len(image_barriers) > 0 {
    image_ptr = raw_data(image_barriers[:])
  }

  vk.CmdPipelineBarrier(
    cmd,
    src_stage,
    dst_stage,
    {},
    0,
    nil,
    u32(len(buffer_barriers)),
    buffer_ptr,
    u32(len(image_barriers)),
    image_ptr,
  )
}
