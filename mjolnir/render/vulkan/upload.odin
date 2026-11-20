#+private
package vulkan_backend

import "core:mem"
import "core:slice"
import "core:sync"
import vk "vendor:vulkan"

@(private = "file")
STAGING_BLOCK_SIZE :: 8 * 1024 * 1024
// staging blocks kept when idle; past these, a block the GPU is done with is freed, so a burst of
// uploads (a level's textures) does not hold its peak of host memory for good. An oversized block
// (one upload past STAGING_BLOCK_SIZE) is never kept
@(private = "file")
STAGING_KEEP :: 2
// satisfies the buffer-to-image offset rule of every color format
@(private = "file")
STAGING_ALIGNMENT :: 16

@(private)
StagingBlock :: struct {
  buffer: Buffer,
  used:   int,
  // frame_serial from which a drained block may be rewritten
  ready:  u64,
}

// `ordered`: a copy between GPU buffers (queue_buffer_copy), recorded after the staged copies
// queued before it and before the ones queued after it
@(private)
PendingCopy :: struct {
  src, dst: vk.Buffer,
  region:   vk.BufferCopy,
  ordered:  bool,
}

// mip 0 comes from `src` at `offset`; the other mips are blitted down from it
@(private)
PendingImage :: struct {
  src:        vk.Buffer,
  offset:     vk.DeviceSize,
  image:      vk.Image,
  extent:     vk.Extent2D,
  aspect:     vk.ImageAspectFlags,
  mip_levels: u32,
}

// Uploads is the pending staged-write state of a GPUContext. Writes go into host-visible
// staging blocks and are recorded in bulk by record_uploads, so uploading never waits on the GPU.
Uploads :: struct {
  blocks: [dynamic]StagingBlock,
  copies: [dynamic]PendingCopy,
  images: [dynamic]PendingImage,
  // fresh images to move out of UNDEFINED
  inits:  [dynamic]ImageDiscard,
  // queuing may happen on any thread; record_uploads drains on the render thread
  mutex:  sync.Mutex,
}

@(private = "file")
staging_alloc :: proc(
  gctx: ^GPUContext,
  size: int,
) -> (
  src: vk.Buffer,
  offset: int,
  ptr: rawptr,
  ret: vk.Result,
) {
  u := &gctx.uploads
  for &b in u.blocks {
    if b.used == 0 && b.ready > gctx.frame_serial do continue
    at := mem.align_forward_int(b.used, STAGING_ALIGNMENT)
    if at + size > int(b.buffer.size) do continue
    b.used = at + size
    return b.buffer.buffer, at, &allocation_mapped(gctx, b.buffer.memory)[at], .SUCCESS
  }
  block := StagingBlock {
    buffer = buffer_create(gctx, vk.DeviceSize(max(size, STAGING_BLOCK_SIZE)), {.TRANSFER_SRC}) or_return,
    used   = size,
  }
  append(&u.blocks, block)
  return block.buffer.buffer, 0, allocation_mapped(gctx, block.buffer.memory), .SUCCESS
}

// queue_buffer_write stages data for buffer at element index (in elements of T); the copy lands in the next recorded command buffer.
queue_buffer_write :: proc(
  gctx: ^GPUContext,
  buffer: ^Buffer,
  data: []$T,
  index: int = 0,
) -> vk.Result {
  size := len(data) * size_of(T)
  if size == 0 do return .SUCCESS
  sync.mutex_guard(&gctx.uploads.mutex)
  src, offset, ptr := staging_alloc(gctx, size) or_return
  mem.copy(ptr, raw_data(data), size)
  append(
    &gctx.uploads.copies,
    PendingCopy {
      src = src,
      dst = buffer.buffer,
      region = {
        srcOffset = vk.DeviceSize(offset),
        dstOffset = vk.DeviceSize(index * size_of(T)),
        size = vk.DeviceSize(size),
      },
    },
  )
  return .SUCCESS
}

// queue_buffer_copy copies region of src into dst in the next recorded command buffer, in order
// with the staged writes queued around it.
queue_buffer_copy :: proc(gctx: ^GPUContext, src, dst: vk.Buffer, region: vk.BufferCopy) {
  sync.mutex_guard(&gctx.uploads.mutex)
  append(&gctx.uploads.copies, PendingCopy{src = src, dst = dst, region = region, ordered = true})
}

// queue_image_write stages size bytes of data as mip 0 of img, the rest of the chain blitted down, in the next recorded command buffer.
queue_image_write :: proc(
  gctx: ^GPUContext,
  img: ^Image,
  data: rawptr,
  size: int,
) -> vk.Result {
  sync.mutex_guard(&gctx.uploads.mutex)
  src, offset, ptr := staging_alloc(gctx, size) or_return
  mem.copy(ptr, data, size)
  append(
    &gctx.uploads.images,
    PendingImage {
      src = src,
      offset = vk.DeviceSize(offset),
      image = img.image,
      extent = {img.desc.extent.x, img.desc.extent.y},
      aspect = infer_aspect_mask(FORMATS[img.desc.format]),
      mip_levels = img.desc.mip_levels,
    },
  )
  return .SUCCESS
}

// queue_image_init moves a fresh image out of UNDEFINED in the next recorded command buffer.
queue_image_init :: proc(gctx: ^GPUContext, init: ImageDiscard) {
  sync.mutex_guard(&gctx.uploads.mutex)
  append(&gctx.uploads.inits, init)
}

// record_uploads records every queued image init and upload into cmd, and makes them visible
// to vertex input, indirect reads and shader access. Call once per command buffer on the render thread.
record_uploads :: proc(gctx: ^GPUContext, cmd: vk.CommandBuffer) {
  u := &gctx.uploads
  sync.mutex_guard(&u.mutex)
  if len(u.inits) > 0 {
    image_discard_barrier(cmd, ..u.inits[:])
    clear(&u.inits)
  }
  staging_trim(gctx)
  if len(u.copies) == 0 && len(u.images) == 0 do return
  // staged copies between ordered ones are batched by source and destination
  for start := 0; start < len(u.copies); {
    c := u.copies[start]
    if c.ordered {
      // earlier frames' and the staged writes land before the copy reads or overwrites
      memory_barrier(cmd, {.MEMORY_WRITE}, {.TRANSFER_READ, .TRANSFER_WRITE}, {.ALL_COMMANDS}, {.TRANSFER})
      region := c.region
      vk.CmdCopyBuffer(cmd, c.src, c.dst, 1, &region)
      start += 1
      if start < len(u.copies) && !u.copies[start].ordered do memory_barrier(cmd, {.TRANSFER_WRITE}, {.TRANSFER_READ, .TRANSFER_WRITE}, {.TRANSFER}, {.TRANSFER})
      continue
    }
    stop := start + 1
    for stop < len(u.copies) && !u.copies[stop].ordered do stop += 1
    record_staged_copies(cmd, u.copies[start:stop])
    start = stop
  }
  if len(u.images) > 0 do record_image_uploads(cmd, u.images[:])
  clear(&u.copies)
  clear(&u.images)
  for &b in u.blocks do if b.used > 0 {
    b.used = 0
    b.ready = gctx.frame_serial + RETIRE_GRACE
  }
  memory_barrier(
    cmd,
    {.TRANSFER_WRITE},
    {.VERTEX_ATTRIBUTE_READ, .INDEX_READ, .INDIRECT_COMMAND_READ, .SHADER_STORAGE_READ, .SHADER_STORAGE_WRITE, .SHADER_SAMPLED_READ},
    {.TRANSFER},
    {.VERTEX_ATTRIBUTE_INPUT, .INDEX_INPUT, .DRAW_INDIRECT, .VERTEX_SHADER, .FRAGMENT_SHADER, .COMPUTE_SHADER},
  )
}

// staging_trim frees the idle staging blocks past the first STAGING_KEEP of standard size; uploads
// mutex held.
@(private = "file")
staging_trim :: proc(gctx: ^GPUContext) {
  u := &gctx.uploads
  kept := 0
  for i := 0; i < len(u.blocks); {
    b := &u.blocks[i]
    idle := b.used == 0 && b.ready <= gctx.frame_serial
    standard := int(b.buffer.size) <= STAGING_BLOCK_SIZE
    if !idle || (standard && kept < STAGING_KEEP) {
      if idle do kept += 1
      i += 1
      continue
    }
    buffer_destroy(gctx, &b.buffer)
    ordered_remove(&u.blocks, i)
  }
}

// submit_uploads records every queued upload into a one-shot command buffer and waits for it,
// so a following deferred_flush drops none. Not while a frame is being recorded.
submit_uploads :: proc(gctx: ^GPUContext) -> vk.Result {
  alloc_info := vk.CommandBufferAllocateInfo {
    sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
    level              = .PRIMARY,
    commandPool        = gctx.command_pool,
    commandBufferCount = 1,
  }
  cmd: vk.CommandBuffer
  vk.AllocateCommandBuffers(gctx.device, &alloc_info, &cmd) or_return
  defer vk.FreeCommandBuffers(gctx.device, gctx.command_pool, 1, &cmd)
  begin_record(cmd) or_return
  record_uploads(gctx, cmd)
  vk.EndCommandBuffer(cmd) or_return
  cmd_info := vk.CommandBufferSubmitInfo {
    sType         = .COMMAND_BUFFER_SUBMIT_INFO,
    commandBuffer = cmd,
  }
  submit_info := vk.SubmitInfo2 {
    sType                  = .SUBMIT_INFO_2,
    commandBufferInfoCount = 1,
    pCommandBufferInfos    = &cmd_info,
  }
  vk.QueueSubmit2(gctx.graphics_queue, 1, &submit_info, 0) or_return
  return vk.QueueWaitIdle(gctx.graphics_queue)
}

@(private = "file")
record_staged_copies :: proc(cmd: vk.CommandBuffer, copies: []PendingCopy) {
  slice.sort_by(copies, proc(a, b: PendingCopy) -> bool {
    if a.src != b.src do return a.src < b.src
    return a.dst < b.dst
  })
  regions := make([]vk.BufferCopy, len(copies), context.temp_allocator)
  for c, i in copies do regions[i] = c.region
  for start := 0; start < len(copies); {
    end := start + 1
    for end < len(copies) && copies[end].src == copies[start].src && copies[end].dst == copies[start].dst do end += 1
    vk.CmdCopyBuffer(cmd, copies[start].src, copies[start].dst, u32(end - start), &regions[start])
    start = end
  }
}

@(private = "file")
record_image_uploads :: proc(cmd: vk.CommandBuffer, images: []PendingImage) {
  discards := make([]ImageDiscard, len(images), context.temp_allocator)
  max_mips: u32 = 1
  for img, i in images {
    discards[i] = {img.image, img.aspect, {.TRANSFER_WRITE}, {.TRANSFER}}
    max_mips = max(max_mips, img.mip_levels)
  }
  image_discard_barrier(cmd, ..discards)
  for img in images {
    region := vk.BufferImageCopy {
      bufferOffset = img.offset,
      imageSubresource = {aspectMask = img.aspect, layerCount = 1},
      imageExtent = {img.extent.width, img.extent.height, 1},
    }
    vk.CmdCopyBufferToImage(cmd, img.src, img.image, .GENERAL, 1, &region)
  }
  for level in 1 ..< max_mips {
    memory_barrier(cmd, {.TRANSFER_WRITE}, {.TRANSFER_READ}, {.TRANSFER}, {.TRANSFER})
    for img in images {
      if level >= img.mip_levels do continue
      src := [2]i32{max(i32(img.extent.width >> (level - 1)), 1), max(i32(img.extent.height >> (level - 1)), 1)}
      dst := [2]i32{max(src.x / 2, 1), max(src.y / 2, 1)}
      blit := vk.ImageBlit {
        srcOffsets = {{0, 0, 0}, {src.x, src.y, 1}},
        srcSubresource = {aspectMask = img.aspect, mipLevel = level - 1, layerCount = 1},
        dstOffsets = {{0, 0, 0}, {dst.x, dst.y, 1}},
        dstSubresource = {aspectMask = img.aspect, mipLevel = level, layerCount = 1},
      }
      vk.CmdBlitImage(cmd, img.image, .GENERAL, img.image, .GENERAL, 1, &blit, .LINEAR)
    }
  }
}

// only when no frame is in flight
@(private)
discard_uploads :: proc(gctx: ^GPUContext) {
  sync.mutex_guard(&gctx.uploads.mutex)
  clear(&gctx.uploads.copies)
  clear(&gctx.uploads.images)
  clear(&gctx.uploads.inits)
  for &b in gctx.uploads.blocks do b.used, b.ready = 0, 0
}

@(private)
uploads_destroy :: proc(gctx: ^GPUContext) {
  for &b in gctx.uploads.blocks do buffer_destroy(gctx, &b.buffer)
  delete(gctx.uploads.blocks)
  delete(gctx.uploads.copies)
  delete(gctx.uploads.images)
  delete(gctx.uploads.inits)
  gctx.uploads = {}
}
