package gpu

import vk "vendor:vulkan"

// Buffer copies queued by queue_buffer_write and recorded at the start of the
// next frame's command buffer by record_uploads, so uploading never waits on
// the GPU.
@(private)
PendingCopy :: struct {
  staging: vk.Buffer,
  memory:  vk.DeviceMemory,
  dst:     vk.Buffer,
  region:  vk.BufferCopy,
}

// Stage `data` for `buffer` at element `index`. The copy lands when the next
// frame records its uploads.
queue_buffer_write :: proc(
  gctx: ^GPUContext,
  buffer: ^ImmutableBuffer($T),
  data: []T,
  index: int = 0,
) -> vk.Result {
  staging := create_mutable_buffer(gctx, T, len(data), {.TRANSFER_SRC}) or_return
  copy(get_all(&staging), data)
  vk.UnmapMemory(gctx.device, staging.memory)
  append(
    &gctx.uploads,
    PendingCopy {
      staging = staging.buffer,
      memory = staging.memory,
      dst = buffer.buffer,
      region = {
        dstOffset = vk.DeviceSize(index * size_of(T)),
        size = vk.DeviceSize(staging.bytes_count),
      },
    },
  )
  return .SUCCESS
}

// Record every queued copy, then make them visible to vertex input and
// vertex-shader storage reads. Staging buffers are released once this
// frame can no longer be in flight.
record_uploads :: proc(gctx: ^GPUContext, cmd: vk.CommandBuffer) {
  if len(gctx.uploads) == 0 do return
  for &c in gctx.uploads {
    vk.CmdCopyBuffer(cmd, c.staging, c.dst, 1, &c.region)
    enqueue(gctx, c.staging, c.memory)
  }
  clear(&gctx.uploads)
  memory_barrier(
    cmd,
    {.TRANSFER_WRITE},
    {.VERTEX_ATTRIBUTE_READ, .INDEX_READ, .SHADER_STORAGE_READ},
    {.COPY},
    {.VERTEX_ATTRIBUTE_INPUT, .INDEX_INPUT, .VERTEX_SHADER},
  )
}

// Drop queued copies that were never recorded. Use only when no frame is
// in flight.
@(private)
discard_uploads :: proc(gctx: ^GPUContext) {
  for c in gctx.uploads {
    vk.DestroyBuffer(gctx.device, c.staging, nil)
    vk.FreeMemory(gctx.device, c.memory, nil)
  }
  clear(&gctx.uploads)
}
