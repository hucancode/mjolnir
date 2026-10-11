package render

import "gpu"
import vk "vendor:vulkan"

// Draw pipelines participate in indirect-draw culling; a camera's DrawBuffers
// hold one draw list per pipeline, in enum order (matches cull.comp).
DrawPipeline :: enum {
  OPAQUE,
  TRANSPARENT,
  SPRITE,
  WIREFRAME,
  RANDOM_COLOR,
}

// Per-frame indirect draw lists: a cull pass writes `count[f]` and
// `commands[f]`, vkCmdDrawIndexedIndirectCount consumes them. List i has its
// count at element i and its commands from element i * max_draws.
DrawBuffers :: struct {
  count:    [gpu.FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  commands: [gpu.FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
}

draw_buffers_init :: proc(
  self: ^DrawBuffers,
  gctx: ^gpu.GPUContext,
  max_draws: u32,
  lists := 1,
) -> vk.Result {
  for frame in 0 ..< gpu.FRAMES_IN_FLIGHT {
    self.count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      lists,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    self.commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws) * lists,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
  }
  return .SUCCESS
}

// Queue the buffers for destruction once no frame in flight reads them.
draw_buffers_destroy :: proc(self: ^DrawBuffers, gctx: ^gpu.GPUContext) {
  for frame in 0 ..< gpu.FRAMES_IN_FLIGHT {
    gpu.defer_destroy_mutable_buffer(gctx, &self.count[frame])
    gpu.defer_destroy_mutable_buffer(gctx, &self.commands[frame])
  }
}

// Make a draw list written by a cull compute pass readable as indirect args.
@(private)
indirect_barrier :: proc(
  cmd: vk.CommandBuffer,
  commands: ^gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  count: ^gpu.MutableBuffer(u32),
) {
  for b in ([2]struct {
      buffer: vk.Buffer,
      size:   int,
    }{{commands.buffer, commands.bytes_count}, {count.buffer, count.bytes_count}}) {
    gpu.buffer_barrier(
      cmd,
      b.buffer,
      vk.DeviceSize(b.size),
      {.SHADER_WRITE},
      {.INDIRECT_COMMAND_READ},
      {.COMPUTE_SHADER},
      {.DRAW_INDIRECT},
    )
  }
}
