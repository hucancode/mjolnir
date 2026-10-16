package vulkan_backend

import "core:mem"
import "core:slice"
import "core:sync"
import vk "vendor:vulkan"

@(private = "file")
STAGING_BLOCK_SIZE :: 8 * 1024 * 1024
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

@(private)
PendingCopy :: struct {
  src, dst: vk.Buffer,
  region:   vk.BufferCopy,
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

@(private)
PendingFill :: struct {
  dst:          vk.Buffer,
  offset, size: vk.DeviceSize,
  value:        u32,
}

// Uploads is the pending staged-write state of a GPUContext. Writes go into host-visible
// staging blocks and are recorded in bulk by record_uploads, so uploading never waits on the GPU.
Uploads :: struct {
  blocks: [dynamic]StagingBlock,
  copies: [dynamic]PendingCopy,
  fills:  [dynamic]PendingFill,
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
    return b.buffer.buffer, at, &b.buffer.mapped[at], .SUCCESS
  }
  block := StagingBlock {
    buffer = buffer_create(gctx, vk.DeviceSize(max(size, STAGING_BLOCK_SIZE)), {.TRANSFER_SRC}) or_return,
    used   = size,
  }
  append(&u.blocks, block)
  return block.buffer.buffer, 0, block.buffer.mapped, .SUCCESS
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

// queue_buffer_fill fills size bytes of buffer from byte offset with the u32 value, in the next recorded command buffer.
// The range must not overlap a queued write to the same buffer.
queue_buffer_fill :: proc(
  gctx: ^GPUContext,
  buffer: ^Buffer,
  offset: vk.DeviceSize = 0,
  size := vk.DeviceSize(vk.WHOLE_SIZE),
  value: u32 = 0,
) {
  sync.mutex_guard(&gctx.uploads.mutex)
  append(&gctx.uploads.fills, PendingFill{buffer.buffer, offset, size, value})
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
      extent = img.extent,
      aspect = infer_aspect_mask(img.format),
      mip_levels = img.mip_levels,
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
  if len(u.copies) == 0 && len(u.fills) == 0 && len(u.images) == 0 do return
  for f in u.fills do vk.CmdFillBuffer(cmd, f.dst, f.offset, f.size, f.value)
  slice.sort_by(u.copies[:], proc(a, b: PendingCopy) -> bool {
    if a.src != b.src do return a.src < b.src
    return a.dst < b.dst
  })
  regions := make([]vk.BufferCopy, len(u.copies), context.temp_allocator)
  for c, i in u.copies do regions[i] = c.region
  for start := 0; start < len(u.copies); {
    end := start + 1
    for end < len(u.copies) && u.copies[end].src == u.copies[start].src && u.copies[end].dst == u.copies[start].dst {
      end += 1
    }
    vk.CmdCopyBuffer(cmd, u.copies[start].src, u.copies[start].dst, u32(end - start), &regions[start])
    start = end
  }
  if len(u.images) > 0 do record_image_uploads(cmd, u.images[:])
  clear(&u.copies)
  clear(&u.fills)
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

// submit_uploads records every queued upload into a one-shot command buffer and waits for it,
// so a following deferred_flush drops none. Not while a frame is being recorded.
submit_uploads :: proc(gctx: ^GPUContext) -> vk.Result {
  cmd := begin_single_time_command(gctx) or_return
  record_uploads(gctx, cmd)
  return end_single_time_command(gctx, &cmd)
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
  clear(&gctx.uploads.fills)
  clear(&gctx.uploads.images)
  clear(&gctx.uploads.inits)
  for &b in gctx.uploads.blocks do b.used, b.ready = 0, 0
}

@(private)
uploads_destroy :: proc(gctx: ^GPUContext) {
  for &b in gctx.uploads.blocks do buffer_destroy(gctx, &b.buffer)
  delete(gctx.uploads.blocks)
  delete(gctx.uploads.copies)
  delete(gctx.uploads.fills)
  delete(gctx.uploads.images)
  delete(gctx.uploads.inits)
  gctx.uploads = {}
}
