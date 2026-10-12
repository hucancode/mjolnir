package gpu

import vk "vendor:vulkan"

// Deferred GPU-resource destruction. A resource freed at runtime may still be
// read by frames already submitted to the GPU, so destroying its vk handles
// inline is a use-after-free. Instead enqueue the handles; deferred_tick
// destroys them RETIRE_GRACE frames later.
//
// Pool-managed resources (textures, meshes) defer through their pool's
// retirement grace, which also holds back their bindless index. This queue is
// for resources with no owning pool.

// Frames (submissions, counted by frame_serial) a freed GPU resource or pool
// slot waits before it is destroyed or reused: the frames in flight, plus one
// because async compute culls a frame ahead (graphics n+1 draws the lists
// compute n built).
RETIRE_GRACE :: FRAMES_IN_FLIGHT + 1

Trash :: union {
  Buffer,
  vk.ImageView,
}

@(private)
TrashItem :: struct {
  ready: u64,
  trash: Trash,
}

// Queue `trash` for destruction once no frame in flight can use it.
defer_destroy :: proc(gctx: ^GPUContext, trash: Trash) {
  append(&gctx.trash, TrashItem{gctx.frame_serial + RETIRE_GRACE, trash})
}

@(private = "file")
destroy_item :: proc(device: vk.Device, item: ^TrashItem) {
  switch &t in item.trash {
  case Buffer:
    buffer_destroy(device, &t)
  case vk.ImageView:
    vk.DestroyImageView(device, t, nil)
  }
}

// deferred_tick destroys every queued resource whose grace has elapsed. Call
// once per frame, after wait_frame.
deferred_tick :: proc(gctx: ^GPUContext) {
  i := 0
  for i < len(gctx.trash) {
    if gctx.trash[i].ready > gctx.frame_serial {
      i += 1
      continue
    }
    destroy_item(gctx.device, &gctx.trash[i])
    unordered_remove(&gctx.trash, i)
  }
}

// deferred_flush destroys every queued resource now, ignoring grace. Use only
// after vkDeviceWaitIdle (teardown/shutdown), where no frame is in flight.
deferred_flush :: proc(gctx: ^GPUContext) {
  discard_uploads(gctx)
  for &item in gctx.trash do destroy_item(gctx.device, &item)
  clear(&gctx.trash)
}

