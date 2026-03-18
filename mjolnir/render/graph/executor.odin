package render_graph

import "core:fmt"
import "core:log"
import vk "vendor:vulkan"

// ============================================================================
// Graph Execution Iterator
// ============================================================================

next_pass :: proc(
  iter: ^GraphPassIterator,
) -> (
  pass: ^PassInstance,
  ok: bool,
) {
  for iter.pass_idx < len(iter.graph.sorted_passes) {
    pass_id := iter.graph.sorted_passes[iter.pass_idx]
    iter.pass_idx += 1
    p := get_pass(iter.graph, pass_id)
    log.debugf("Executing pass: %s", p.name)
    cmd := iter.graphics_cmd if p.queue == .GRAPHICS else iter.compute_cmd
    emit_barriers_for_pass(iter.graph, pass_id, cmd, iter.frame_index)
    iter.resources = resolve_pass_resources(iter.graph, p, iter.frame_index)
    iter.cmd = cmd
    return p, true
  }
  return nil, false
}

pass_done :: proc(iter: ^GraphPassIterator) {
  cleanup_pass_resources(&iter.resources)
}

// ============================================================================
// Barrier Emission
// ============================================================================

@(private = "package")
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

    res := get_resource(graph, barrier.resource_id)

    switch d in res.data {
    case ResourceBuffer:
      actual_variants := max(len(d.buffers), 1)
      variant_idx := compute_variant_index(frame_index, barrier.frame_offset, actual_variants)
      buf: vk.Buffer
      if res.is_external {
        buf = d.external
      } else if variant_idx < len(d.buffers) {
        buf = d.buffers[variant_idx]
      }
      if buf != 0 {
        append(
          &buffer_barriers,
          vk.BufferMemoryBarrier {
            sType               = .BUFFER_MEMORY_BARRIER,
            srcAccessMask       = barrier.src_access,
            dstAccessMask       = barrier.dst_access,
            srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            buffer              = buf,
            offset              = 0,
            size                = vk.DeviceSize(vk.WHOLE_SIZE),
          },
        )
      }

    case ResourceTexture:
      _emit_image_barrier(
        d.images[:],
        d.external_image,
        res.is_external,
        frame_index,
        barrier,
        &image_barriers,
      )

    case ResourceTextureCube:
      _emit_image_barrier(
        d.images[:],
        d.external_image,
        res.is_external,
        frame_index,
        barrier,
        &image_barriers,
      )
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

@(private)
_emit_image_barrier :: proc(
  images: []vk.Image,
  external_image: vk.Image,
  is_external: bool,
  frame_index: u32,
  barrier: Barrier,
  image_barriers: ^[dynamic]vk.ImageMemoryBarrier,
) {
  actual_variants := max(len(images), 1)
  variant_idx := compute_variant_index(frame_index, barrier.frame_offset, actual_variants)
  img: vk.Image
  if is_external {
    img = external_image
  } else if variant_idx < len(images) {
    img = images[variant_idx]
  }
  if img == 0 {return}
  append(
    image_barriers,
    vk.ImageMemoryBarrier {
      sType               = .IMAGE_MEMORY_BARRIER,
      srcAccessMask       = barrier.src_access,
      dstAccessMask       = barrier.dst_access,
      oldLayout           = barrier.old_layout,
      newLayout           = barrier.new_layout,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image               = img,
      subresourceRange    = {
        aspectMask     = barrier.aspect,
        baseMipLevel   = 0,
        levelCount     = vk.REMAINING_MIP_LEVELS,
        baseArrayLayer = 0,
        layerCount     = vk.REMAINING_ARRAY_LAYERS,
      },
    },
  )
}

// ============================================================================
// Resource Resolution
// ============================================================================

@(private = "package")
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
  }

  for read in pass.reads {
    resolve_resource(graph, read.resource_name, read.frame_offset, frame_index, &resources)
  }
  for write in pass.writes {
    resolve_resource(graph, write.resource_name, write.frame_offset, frame_index, &resources)
  }

  return resources
}

@(private = "package")
resolve_resource :: proc(
  graph: ^Graph,
  resource_name: string,
  frame_offset: FrameOffset,
  frame_index: u32,
  resources: ^PassResources,
) {
  res_id, found := find_resource_by_name(graph, resource_name)
  if !found {
    fmt.eprintf("ERROR: Resource '%s' not found\n", resource_name)
    return
  }

  res := get_resource(graph, res_id)
  phys_res := res
  if res.is_alias {
    phys_res = get_resource(graph, res.alias_target)
  }

  switch d in phys_res.data {
  case ResourceBuffer:
    actual_variants := max(len(d.buffers), 1)
    variant_idx := compute_variant_index(frame_index, frame_offset, actual_variants)
    resolved: ResolvedBuffer
    if phys_res.is_external {
      resolved = ResolvedBuffer{buffer = d.external}
    } else if variant_idx < len(d.buffers) {
      resolved = ResolvedBuffer{buffer = d.buffers[variant_idx]}
    }
    resources.buffers[resource_name] = resolved

  case ResourceTexture:
    actual_variants := max(len(d.images), 1)
    variant_idx := compute_variant_index(frame_index, frame_offset, actual_variants)
    resources.textures[resource_name] = _resolve_texture_images(
      d.images[:],
      d.image_views[:],
      d.texture_handle_bits[:],
      d.external_image,
      d.external_image_view,
      phys_res.is_external,
      variant_idx,
    )

  case ResourceTextureCube:
    actual_variants := max(len(d.images), 1)
    variant_idx := compute_variant_index(frame_index, frame_offset, actual_variants)
    resources.textures[resource_name] = _resolve_texture_images(
      d.images[:],
      d.image_views[:],
      d.texture_handle_bits[:],
      d.external_image,
      d.external_image_view,
      phys_res.is_external,
      variant_idx,
    )
  }
}

@(private)
_resolve_texture_images :: proc(
  images: []vk.Image,
  image_views: []vk.ImageView,
  handle_bits: []u64,
  external_image: vk.Image,
  external_image_view: vk.ImageView,
  is_external: bool,
  variant_idx: int,
) -> ResolvedTexture {
  if is_external {
    return ResolvedTexture{image = external_image, view = external_image_view}
  }
  if variant_idx < len(images) {
    h: u64
    if variant_idx < len(handle_bits) {h = handle_bits[variant_idx]}
    return ResolvedTexture {
      image       = images[variant_idx],
      view        = image_views[variant_idx],
      handle_bits = h,
    }
  }
  return {}
}

@(private = "package")
compute_variant_index :: proc(
  frame_index: u32,
  offset: FrameOffset,
  frames_in_flight: int,
) -> int {
  offset_frame := i32(frame_index) + i32(offset)
  variant := int(offset_frame) % frames_in_flight
  if variant < 0 {
    variant += frames_in_flight
  }
  return variant
}

@(private = "package")
cleanup_pass_resources :: proc(resources: ^PassResources) {
  delete(resources.textures)
  delete(resources.buffers)
}
