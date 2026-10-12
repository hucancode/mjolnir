package render

import "gpu"
import vk "vendor:vulkan"

// Counts at the head of a draw list buffer, one per list; commands follow.
DRAW_LIST_HEADER :: 8
#assert(len(MaterialType) <= DRAW_LIST_HEADER)
@(private)
DRAW_COMMAND_SIZE :: size_of(vk.DrawIndexedIndirectCommand)

// Bindless draw list slots: camera slot c takes c * FRAMES_IN_FLIGHT + frame,
// the shadow lists take the slots after every camera's.
@(private)
CAMERA_DRAW_SLOT_BASE :: 0
@(private)
SHADOW_DRAW_SLOT_BASE :: MAX_ACTIVE_CAMERAS * gpu.FRAMES_IN_FLIGHT
@(private)
MAX_DRAW_LIST_SLOTS :: SHADOW_DRAW_SLOT_BASE + gpu.FRAMES_IN_FLIGHT

// Per-frame indirect draw lists: one device-local buffer per frame in flight
// holding up to DRAW_LIST_HEADER lists, each `capacity` draws. A cull pass
// writes them through the bindless draw list array (slot `slot + frame`), and
// vkCmdDrawIndexedIndirectCount consumes them straight from the buffer: list
// i has its count at u32 i and its commands from DRAW_LIST_HEADER u32s plus
// i * capacity commands. A frame's lists hold garbage until its first cull.
DrawLists :: struct {
  buffers:  [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
  slot:     u32,
  capacity: u32, // draws per list
}

draw_lists_init :: proc(
  self: ^DrawLists,
  r: ^Manager,
  slot: u32,
  lists: u32,
  capacity: u32,
) -> vk.Result {
  self.slot = slot
  self.capacity = capacity
  size := vk.DeviceSize(DRAW_LIST_HEADER * size_of(u32) + int(lists) * int(capacity) * DRAW_COMMAND_SIZE)
  for &buffer, frame in self.buffers {
    buffer = gpu.buffer_create(&r.gctx, size, {.STORAGE_BUFFER, .INDIRECT_BUFFER}, host_visible = false) or_return
    gpu.write_descriptor(
      &r.gctx,
      r.texture_manager.descriptor_set,
      BINDING_DRAW_LISTS,
      slot + u32(frame),
      .STORAGE_BUFFER,
      gpu.buffer_info(&buffer),
    )
  }
  return .SUCCESS
}

// Queue the buffers for destruction once no frame in flight reads them.
draw_lists_destroy :: proc(self: ^DrawLists, gctx: ^gpu.GPUContext) {
  for buffer in self.buffers do if buffer.buffer != 0 do gpu.defer_destroy(gctx, buffer)
  self^ = {}
}

// Zero frame `frame_index`'s counts so the cull can append. Order earlier
// indirect reads of the lists before it and the cull after it.
draw_lists_clear :: proc(self: ^DrawLists, cmd: vk.CommandBuffer, frame_index: u32) {
  vk.CmdFillBuffer(cmd, self.buffers[frame_index].buffer, 0, DRAW_LIST_HEADER * size_of(u32), 0)
}

// Draw list `list` of frame `frame_index`. Call inside a render scope.
draw_lists_draw :: proc(self: ^DrawLists, cmd: vk.CommandBuffer, frame_index: u32, list: u32) {
  buffer := self.buffers[frame_index].buffer
  vk.CmdDrawIndexedIndirectCount(
    cmd,
    buffer,
    vk.DeviceSize(DRAW_LIST_HEADER * size_of(u32) + int(list) * int(self.capacity) * DRAW_COMMAND_SIZE),
    buffer,
    vk.DeviceSize(list * size_of(u32)),
    self.capacity,
    DRAW_COMMAND_SIZE,
  )
}

// Copy frame `frame_index`'s counts into `dst` once the draws that read
// them are recorded.
draw_lists_copy_counts :: proc(self: ^DrawLists, cmd: vk.CommandBuffer, frame_index: u32, dst: ^gpu.Buffer) {
  gpu.memory_barrier(cmd, {.SHADER_WRITE}, {.TRANSFER_READ}, {.COMPUTE_SHADER, .DRAW_INDIRECT}, {.TRANSFER})
  region := vk.BufferCopy{size = DRAW_LIST_HEADER * size_of(u32)}
  vk.CmdCopyBuffer(cmd, self.buffers[frame_index].buffer, dst.buffer, 1, &region)
}

// Make the draw lists written by cull compute passes readable as indirect
// args.
@(private)
indirect_barrier :: proc(cmd: vk.CommandBuffer) {
  gpu.memory_barrier(cmd, {.SHADER_WRITE}, {.INDIRECT_COMMAND_READ}, {.COMPUTE_SHADER}, {.DRAW_INDIRECT})
}
