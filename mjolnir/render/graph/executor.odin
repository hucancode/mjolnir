package render_graph

import "core:fmt"
import "core:log"
import vk "vendor:vulkan"

// ============================================================================
// Graph Execution Iterator
// ============================================================================

// Advance the iterator to the next live pass.
// Emits barriers, resolves resources, and sets iter.resources / iter.cmd.
// Returns the pass and true; returns nil, false when all passes are done.
// The caller must call pass_done after processing each pass.
next_pass :: proc(
  iter: ^GraphPassIterator,
) -> (
  pass: ^PassInstance,
  ok: bool,
) {
  for iter._pass_idx < len(iter._graph.sorted_passes) {
    pass_id := iter._graph.sorted_passes[iter._pass_idx]
    iter._pass_idx += 1
    p := get_pass(iter._graph, pass_id)
    log.debugf("Executing pass: %s", p.name)
    cmd := iter._graphics_cmd if p.queue == .GRAPHICS else iter._compute_cmd
    emit_barriers_for_pass(iter._graph, pass_id, cmd, iter._frame_index)
    iter.resources = resolve_pass_resources(iter._graph, p, iter._frame_index)
    iter.cmd = cmd
    return p, true
  }
  return nil, false
}

// Release resources allocated by the preceding next_pass call.
// Must be called once per successful next_pass before calling next_pass again.
pass_done :: proc(iter: ^GraphPassIterator) {
  cleanup_pass_resources(&iter.resources)
}

// ============================================================================
// Barrier Emission
// ============================================================================

emit_barriers_for_pass :: proc(
  graph: ^Graph,
  pass_id: PassInstanceId,
  cmd: vk.CommandBuffer,
  frame_index: u32,
) {
  barriers, has_barriers := graph.barriers[pass_id]
  if !has_barriers || len(barriers) == 0 {
    return
  }

  buffer_barriers := make([dynamic]vk.BufferMemoryBarrier, 0, len(barriers))
  image_barriers := make([dynamic]vk.ImageMemoryBarrier, 0, len(barriers))
  defer delete(buffer_barriers)
  defer delete(image_barriers)

  src_stage_mask: vk.PipelineStageFlags = {}
  dst_stage_mask: vk.PipelineStageFlags = {}

  for barrier in barriers {
    src_stage_mask |= barrier.src_stage
    dst_stage_mask |= barrier.dst_stage

    // Resolve the actual GPU handle at emit time using the current frame index.
    // This correctly handles multi-variant resources (NEXT/PREV frame offsets)
    // and external resources whose handles may change each frame.
    res := get_resource(graph, barrier.resource_id)
    switch res.type {
    case .BUFFER:
      actual_variants := max(len(res.buffers), 1)
      variant_idx := compute_variant_index(
        frame_index,
        barrier.frame_offset,
        actual_variants,
      )
      buf: vk.Buffer
      if res.buffer_desc.is_external {
        buf = res.external_buffer
      } else if variant_idx < len(res.buffers) {
        buf = res.buffers[variant_idx]
      }
      if buf != 0 {
        append(
          &buffer_barriers,
          vk.BufferMemoryBarrier {
            sType = .BUFFER_MEMORY_BARRIER,
            srcAccessMask = barrier.src_access,
            dstAccessMask = barrier.dst_access,
            srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            buffer = buf,
            offset = 0,
            size = vk.DeviceSize(vk.WHOLE_SIZE),
          },
        )
      }

    case .TEXTURE_2D, .TEXTURE_CUBE:
      actual_variants := max(len(res.images), 1)
      variant_idx := compute_variant_index(
        frame_index,
        barrier.frame_offset,
        actual_variants,
      )
      img: vk.Image
      if res.texture_desc.is_external {
        img = res.external_image
      } else if variant_idx < len(res.images) {
        img = res.images[variant_idx]
      }
      if img != 0 {
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
            image = img,
            subresourceRange = {
              aspectMask = barrier.aspect,
              baseMipLevel = 0,
              levelCount = vk.REMAINING_MIP_LEVELS,
              baseArrayLayer = 0,
              layerCount = vk.REMAINING_ARRAY_LAYERS,
            },
          },
        )
      }
    }
  }

  if len(buffer_barriers) > 0 || len(image_barriers) > 0 {
    vk.CmdPipelineBarrier(
      cmd,
      src_stage_mask,
      dst_stage_mask,
      {},
      0,
      nil,
      u32(len(buffer_barriers)),
      raw_data(buffer_barriers),
      u32(len(image_barriers)),
      raw_data(image_barriers),
    )
  }
}

// ============================================================================
// Resource Resolution
// ============================================================================

resolve_pass_resources :: proc(
  graph: ^Graph,
  pass: ^PassInstance,
  frame_index: u32,
) -> PassResources {
  resources := PassResources {
    textures     = make(map[string]ResolvedTexture),
    buffers      = make(map[string]ResolvedBuffer),
    scope        = pass.scope,
    instance_idx = pass.instance,
  }

  // Resolve instance handle based on scope
  switch pass.scope {
  case .PER_CAMERA:
    if int(pass.instance) < len(graph.camera_handles) {
      resources.camera_handle = graph.camera_handles[pass.instance]
    }
  case .PER_POINT_LIGHT, .PER_SPOT_LIGHT, .PER_DIRECTIONAL_LIGHT:
    if int(pass.instance) < len(graph.light_handles) {
      resources.light_handle = graph.light_handles[pass.instance]
    }
  case .GLOBAL:
  // No handle mapping needed
  }

  // Resolve all read resources
  for read in pass.reads {
    resolve_resource(
      graph,
      read.resource_name,
      read.frame_offset,
      frame_index,
      &resources,
    )
  }

  // Resolve all write resources
  for write in pass.writes {
    resolve_resource(
      graph,
      write.resource_name,
      write.frame_offset,
      frame_index,
      &resources,
    )
  }

  return resources
}

resolve_resource :: proc(
  graph: ^Graph,
  resource_name: string,
  frame_offset: FrameOffset,
  frame_index: u32,
  resources: ^PassResources,
) {
  // Find resource instance
  res_id, found := find_resource_by_name(graph, resource_name)
  if !found {
    fmt.eprintf("ERROR: Resource '%s' not found\n", resource_name)
    return
  }

  res := get_resource(graph, res_id)

  // Follow alias chain: aliased resources share GPU handles with their target.
  // barrier.resource_id already points to the physical resource, but here we
  // look up by name so we must resolve the chain manually.
  phys_res := res
  if res.is_alias {
    phys_res = get_resource(graph, res.alias_target)
  }

  // Use actual allocated variant count, not frames_in_flight.
  // Resources accessed only with .CURRENT have variant_count=1, so variant_idx
  // must always be 0 regardless of frame_index.
  actual_variants: int
  switch phys_res.type {
  case .BUFFER:
    actual_variants = max(len(phys_res.buffers), 1)
  case .TEXTURE_2D, .TEXTURE_CUBE:
    actual_variants = max(len(phys_res.images), 1)
  }

  variant_idx := compute_variant_index(
    frame_index,
    frame_offset,
    actual_variants,
  )

  // Resolve based on resource type using physical resource's GPU handles
  switch phys_res.type {
  case .BUFFER:
    resolved := resolve_buffer(phys_res, variant_idx)
    resources.buffers[resource_name] = resolved

  case .TEXTURE_2D, .TEXTURE_CUBE:
    resolved := resolve_texture(phys_res, variant_idx)
    resources.textures[resource_name] = resolved
  }
}

resolve_buffer :: proc(
  res: ^ResourceInstance,
  variant_idx: int,
) -> ResolvedBuffer {
  buffer: vk.Buffer
  size: vk.DeviceSize

  if res.buffer_desc.is_external {
    buffer = res.external_buffer
    size = res.buffer_desc.size
  } else if variant_idx < len(res.buffers) {
    buffer = res.buffers[variant_idx]
    size = res.buffer_desc.size
  }

  return ResolvedBuffer{buffer = buffer, size = size}
}

resolve_texture :: proc(
  res: ^ResourceInstance,
  variant_idx: int,
) -> ResolvedTexture {
  image: vk.Image
  view: vk.ImageView
  handle_bits: u64
  format := res.texture_desc.format
  width := res.texture_desc.width
  height := res.texture_desc.height

  if res.texture_desc.is_external {
    image = res.external_image
    view = res.external_image_view
  } else if variant_idx < len(res.images) {
    image = res.images[variant_idx]
    view = res.image_views[variant_idx]
    if variant_idx < len(res.texture_handle_bits) {
      handle_bits = res.texture_handle_bits[variant_idx]
    }
  }

  return ResolvedTexture {
    image = image,
    view = view,
    format = format,
    width = width,
    height = height,
    handle_bits = handle_bits,
  }
}

compute_variant_index :: proc(
  frame_index: u32,
  offset: FrameOffset,
  frames_in_flight: int,
) -> int {
  // Compute frame index with offset
  offset_frame := i32(frame_index) + i32(offset)

  // Wrap around frames in flight
  variant := int(offset_frame) % frames_in_flight

  // Handle negative modulo
  if variant < 0 {
    variant += frames_in_flight
  }

  return variant
}

cleanup_pass_resources :: proc(resources: ^PassResources) {
  delete(resources.textures)
  delete(resources.buffers)
}
