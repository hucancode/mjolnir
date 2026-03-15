package render_graph

import "../../gpu"
import "core:log"
import vk "vendor:vulkan"

// ============================================================================
// Resource Allocation
// ============================================================================

allocate_resources :: proc(
  graph: ^Graph,
  gctx: ^gpu.GPUContext,
  tm: ^gpu.TextureManager,
  loc := #caller_location,
) -> CompileError {
  needs_frame_variants := _needs_frame_variants(graph)
  defer delete(needs_frame_variants)

  for &res in graph.resource_instances {
    if res.is_alias do continue
    if res.is_external do continue

    switch &d in res.data {
    case ResourceTexture:
      variant_count :=
        graph.frames_in_flight if needs_frame_variants[res.name] || d.double_buffer else 1
      allocate_texture_2d(&res, &d, gctx, tm, variant_count) or_return

    case ResourceTextureCube:
      variant_count := graph.frames_in_flight if needs_frame_variants[res.name] else 1
      allocate_texture_cube(&res, &d, gctx, tm, variant_count) or_return

    case ResourceBuffer:
      variant_count := graph.frames_in_flight if needs_frame_variants[res.name] else 1
      allocate_buffer(&res, &d, gctx, variant_count) or_return
    }
  }

  return .NONE
}

// ============================================================================
// Buffer Allocation
// ============================================================================

allocate_buffer :: proc(
  res: ^ResourceInstance,
  data: ^ResourceBuffer,
  gctx: ^gpu.GPUContext,
  variant_count: int,
  loc := #caller_location,
) -> CompileError {
  data.buffers = make([dynamic]vk.Buffer, variant_count)
  data.buffer_memory = make([dynamic]vk.DeviceMemory, variant_count)

  for i in 0 ..< variant_count {
    create_info := vk.BufferCreateInfo {
      sType       = .BUFFER_CREATE_INFO,
      size        = data.size,
      usage       = data.usage,
      sharingMode = .EXCLUSIVE,
    }
    if vk.CreateBuffer(gctx.device, &create_info, nil, &data.buffers[i]) != .SUCCESS {
      log.errorf("graph allocator: failed to create buffer '%s'[%d]", res.name, i)
      return .ALLOCATION_FAILED
    }

    mem_reqs: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(gctx.device, data.buffers[i], &mem_reqs)

    data.buffer_memory[i] = gpu.allocate_memory(gctx, mem_reqs, {.DEVICE_LOCAL}) or_else 0
    if data.buffer_memory[i] == 0 {
      log.errorf(
        "graph allocator: failed to allocate memory for buffer '%s'[%d]",
        res.name,
        i,
      )
      return .ALLOCATION_FAILED
    }

    if vk.BindBufferMemory(gctx.device, data.buffers[i], data.buffer_memory[i], 0) != .SUCCESS {
      log.errorf(
        "graph allocator: failed to bind memory for buffer '%s'[%d]",
        res.name,
        i,
      )
      return .ALLOCATION_FAILED
    }
  }

  return .NONE
}

// ============================================================================
// Texture Allocation
// ============================================================================

allocate_texture_2d :: proc(
  res: ^ResourceInstance,
  data: ^ResourceTexture,
  gctx: ^gpu.GPUContext,
  tm: ^gpu.TextureManager,
  variant_count: int,
  loc := #caller_location,
) -> CompileError {
  data.images = make([dynamic]vk.Image, variant_count)
  data.image_views = make([dynamic]vk.ImageView, variant_count)
  data.texture_handle_bits = make([dynamic]u64, variant_count)

  extent := vk.Extent2D{data.width, data.height}

  for i in 0 ..< variant_count {
    handle, ret := gpu.allocate_texture_2d(tm, gctx, extent, data.format, data.usage)
    if ret != .SUCCESS {
      log.errorf(
        "graph allocator: failed to allocate texture_2d '%s'[%d]: %v",
        res.name,
        i,
        ret,
      )
      return .ALLOCATION_FAILED
    }

    img := gpu.get_texture_2d(tm, handle)
    data.images[i] = img.image
    data.image_views[i] = img.view
    data.texture_handle_bits[i] = transmute(u64)handle
  }

  return .NONE
}

allocate_texture_cube :: proc(
  res: ^ResourceInstance,
  data: ^ResourceTextureCube,
  gctx: ^gpu.GPUContext,
  tm: ^gpu.TextureManager,
  variant_count: int,
  loc := #caller_location,
) -> CompileError {
  data.images = make([dynamic]vk.Image, variant_count)
  data.image_views = make([dynamic]vk.ImageView, variant_count)
  data.texture_handle_bits = make([dynamic]u64, variant_count)

  for i in 0 ..< variant_count {
    handle, ret := gpu.allocate_texture_cube(tm, gctx, data.width, data.format, data.usage)
    if ret != .SUCCESS {
      log.errorf(
        "graph allocator: failed to allocate texture_cube '%s'[%d]: %v",
        res.name,
        i,
        ret,
      )
      return .ALLOCATION_FAILED
    }

    img := gpu.get_texture_cube(tm, handle)
    data.images[i] = img.image
    data.image_views[i] = img.view
    data.texture_handle_bits[i] = transmute(u64)handle
  }

  return .NONE
}

// ============================================================================
// Resource Deallocation
// ============================================================================

deallocate_resource :: proc(
  res: ^ResourceInstance,
  gctx: ^gpu.GPUContext,
  tm: ^gpu.TextureManager,
) {
  if res.is_alias {return}

  switch &d in res.data {
  case ResourceBuffer:
    for i in 0 ..< len(d.buffers) {
      vk.DestroyBuffer(gctx.device, d.buffers[i], nil)
      vk.FreeMemory(gctx.device, d.buffer_memory[i], nil)
    }
    delete(d.buffers)
    delete(d.buffer_memory)

  case ResourceTexture:
    for bits in d.texture_handle_bits {
      handle := transmute(gpu.Texture2DHandle)bits
      gpu.free_texture_2d(tm, gctx, handle)
    }
    delete(d.images)
    delete(d.image_views)
    delete(d.texture_handle_bits)

  case ResourceTextureCube:
    for bits in d.texture_handle_bits {
      handle := transmute(gpu.TextureCubeHandle)bits
      gpu.free_texture_cube(tm, gctx, handle)
    }
    delete(d.images)
    delete(d.image_views)
    delete(d.texture_handle_bits)
  }
}
