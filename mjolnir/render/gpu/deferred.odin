package gpu

import vk "vendor:vulkan"

// Deferred GPU-resource destruction. A resource freed at runtime may still be
// read by frames already submitted to the GPU (up to FRAMES_IN_FLIGHT-1 of
// them), so destroying its vk handles inline is a use-after-free. Instead enqueue
// the raw handles with a ready frame; deferred_tick() destroys them once enough
// frames have been presented that no in-flight frame can reference them.
//
// Pool-managed images (texture_manager) handle their own deferral via the pool's
// retirement grace. This queue is for loose resources with no owning pool — e.g.
// the per-frame shadow draw buffers freed when a light despawns.

TrashItem :: struct {
  ready:  u64,
  buffer: vk.Buffer,
  memory: vk.DeviceMemory,
}

DeferredTrash :: struct {
  items: [dynamic]TrashItem,
  frame: u64,
}

@(private = "file")
enqueue :: proc(gctx: ^GPUContext, buffer: vk.Buffer, memory: vk.DeviceMemory) {
  append(&gctx.trash.items, TrashItem{gctx.trash.frame + FRAMES_IN_FLIGHT, buffer, memory})
}

// defer_destroy_mutable_buffer unmaps now (the CPU mapping is never read by the
// GPU, so it is safe to drop immediately) and queues the buffer + memory for
// destruction once it is no longer referenced by any in-flight frame. The
// passed buffer is zeroed so it cannot be destroyed twice.
defer_destroy_mutable_buffer :: proc(gctx: ^GPUContext, buffer: ^MutableBuffer($T)) {
  if buffer.buffer == 0 do return
  if buffer.mapped != nil {
    vk.UnmapMemory(gctx.device, buffer.memory)
    buffer.mapped = nil
  }
  enqueue(gctx, buffer.buffer, buffer.memory)
  buffer^ = {}
}

@(private = "file")
destroy_item :: proc(device: vk.Device, item: TrashItem) {
  vk.DestroyBuffer(device, item.buffer, nil)
  vk.FreeMemory(device, item.memory, nil)
}

// deferred_tick advances the frame counter and destroys every queued resource
// whose grace has elapsed. Call once per presented frame.
deferred_tick :: proc(gctx: ^GPUContext) {
  d := &gctx.trash
  d.frame += 1
  i := 0
  for i < len(d.items) {
    if d.items[i].ready > d.frame {
      i += 1
      continue
    }
    destroy_item(gctx.device, d.items[i])
    unordered_remove(&d.items, i)
  }
}

// deferred_flush destroys every queued resource now, ignoring grace. Use only
// after vkDeviceWaitIdle (teardown/shutdown), where no frame is in flight.
deferred_flush :: proc(gctx: ^GPUContext) {
  for item in gctx.trash.items {
    destroy_item(gctx.device, item)
  }
  clear(&gctx.trash.items)
}

@(private)
deferred_destroy :: proc(gctx: ^GPUContext) {
  delete(gctx.trash.items)
  gctx.trash = {}
}
