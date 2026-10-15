package render

import "rhi"

// The frame: every pass in order, with the barriers between them. With async compute (Vulkan on
// a device with a compute queue family) render records three command lists: the uploads, the
// compute list (depth pyramids and the camera cull, for the next frame) and the graphics list,
// ordered against each other and the previous frame's by timeline values. Otherwise one list
// carries it all, the cull last, and the queue and its barriers order it.

// Every global memory dependency the frame records, by the work it orders: a barrier is
// (writes made, reads that must see them) between two stage sets.
@(private)
Barrier :: enum {
  // a fill or dispatch writes what a later dispatch reads or writes
  FILL_TO_COMPUTE,
  // colors a pass wrote are sampled by a later one (render-to-texture, post-process input)
  COLOR_TO_SAMPLE,
  GBUFFER_TO_LIGHTING,
  LIGHTING_TO_FORWARD,
  FORWARD_TO_COMPUTE,
  SHADOW_TO_LIGHTING,
  CULL_TO_INDIRECT,
  CULL_TO_COPY,
  INDIRECT_TO_FILL,
  FILL_TO_CULL,
  // the previous simulation and this frame's draws use what the particle pass rewrites
  PARTICLES_TO_FILL,
  POST_PASS,
  // the cull recorded after the frame on one queue: it rewrites the lists and pyramids that
  // draws and the previous cull read, from depth the frame wrote
  FRAME_TO_CULL,
}

@(private = "file")
BARRIERS := [Barrier]rhi.Barrier {
  .FILL_TO_COMPUTE = {
    src_stage = {.COMPUTE_SHADER, .TRANSFER}, dst_stage = {.COMPUTE_SHADER},
    src_access = {.SHADER_WRITE, .TRANSFER_WRITE}, dst_access = {.SHADER_READ, .SHADER_WRITE},
  },
  .COLOR_TO_SAMPLE = {
    src_stage = {.COLOR_ATTACHMENT_OUTPUT}, dst_stage = {.FRAGMENT_SHADER},
    src_access = {.COLOR_ATTACHMENT_WRITE}, dst_access = {.SHADER_READ},
  },
  .GBUFFER_TO_LIGHTING = {
    src_stage = {.COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS},
    dst_stage = {.FRAGMENT_SHADER, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
    src_access = {.COLOR_ATTACHMENT_WRITE, .DEPTH_ATTACHMENT_WRITE},
    dst_access = {.SHADER_READ, .DEPTH_ATTACHMENT_READ},
  },
  .LIGHTING_TO_FORWARD = {
    src_stage = {.FRAGMENT_SHADER, .COMPUTE_SHADER, .COLOR_ATTACHMENT_OUTPUT},
    dst_stage = {.DRAW_INDIRECT, .VERTEX_SHADER, .EARLY_FRAGMENT_TESTS, .COLOR_ATTACHMENT_OUTPUT},
    src_access = {.SHADER_WRITE, .COLOR_ATTACHMENT_WRITE},
    dst_access = {.INDIRECT_READ, .SHADER_READ, .DEPTH_ATTACHMENT_READ, .DEPTH_ATTACHMENT_WRITE, .COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
  },
  .FORWARD_TO_COMPUTE = {
    src_stage = {.LATE_FRAGMENT_TESTS}, dst_stage = {.COMPUTE_SHADER, .FRAGMENT_SHADER},
    src_access = {.DEPTH_ATTACHMENT_WRITE}, dst_access = {.SHADER_READ},
  },
  .SHADOW_TO_LIGHTING = {
    src_stage = {.LATE_FRAGMENT_TESTS}, dst_stage = {.FRAGMENT_SHADER},
    src_access = {.DEPTH_ATTACHMENT_WRITE}, dst_access = {.SHADER_READ},
  },
  .CULL_TO_INDIRECT = {
    src_stage = {.COMPUTE_SHADER}, dst_stage = {.DRAW_INDIRECT},
    src_access = {.SHADER_WRITE}, dst_access = {.INDIRECT_READ},
  },
  .CULL_TO_COPY = {
    src_stage = {.COMPUTE_SHADER, .DRAW_INDIRECT}, dst_stage = {.TRANSFER},
    src_access = {.SHADER_WRITE}, dst_access = {.TRANSFER_READ},
  },
  .INDIRECT_TO_FILL = {src_stage = {.DRAW_INDIRECT}, dst_stage = {.TRANSFER}},
  .FILL_TO_CULL = {
    src_stage = {.TRANSFER}, dst_stage = {.COMPUTE_SHADER},
    src_access = {.TRANSFER_WRITE}, dst_access = {.SHADER_READ, .SHADER_WRITE},
  },
  .PARTICLES_TO_FILL = {
    src_stage = {.DRAW_INDIRECT, .VERTEX_SHADER, .COMPUTE_SHADER}, dst_stage = {.COMPUTE_SHADER, .TRANSFER},
    src_access = {.SHADER_WRITE}, dst_access = {.SHADER_READ, .SHADER_WRITE, .TRANSFER_WRITE},
  },
  .POST_PASS = {
    src_stage = {.COLOR_ATTACHMENT_OUTPUT, .FRAGMENT_SHADER}, dst_stage = {.FRAGMENT_SHADER, .COLOR_ATTACHMENT_OUTPUT},
    src_access = {.COLOR_ATTACHMENT_WRITE}, dst_access = {.SHADER_READ, .COLOR_ATTACHMENT_WRITE},
  },
  .FRAME_TO_CULL = {
    src_stage = {.DRAW_INDIRECT, .COMPUTE_SHADER, .TRANSFER, .LATE_FRAGMENT_TESTS}, dst_stage = {.COMPUTE_SHADER, .TRANSFER},
    src_access = {.SHADER_WRITE, .TRANSFER_WRITE, .DEPTH_ATTACHMENT_WRITE}, dst_access = {.SHADER_READ, .SHADER_WRITE, .TRANSFER_WRITE},
  },
}

// Records `barriers` as one dependency.
@(private)
barrier :: proc(r: ^Renderer, cmd: rhi.CommandList, barriers: ..Barrier) {
  barrier_discard(r, cmd, nil, ..barriers)
}

// Records `barriers` and the discard of `textures` as one dependency.
@(private)
barrier_discard :: proc(r: ^Renderer, cmd: rhi.CommandList, textures: []TextureHandle, barriers: ..Barrier) {
  descs: [len(Barrier)]rhi.Barrier
  for b, i in barriers do descs[i] = BARRIERS[b]
  dev.cmd_barrier(&r.gpu, cmd, descs[:len(barriers)], textures)
}

// Phase by phase across cameras (G-buffer, lighting, forward) so one barrier serves every
// camera; render scopes cannot hold barriers.
@(private = "file")
camera_passes :: proc(r: ^Renderer, cmd: rhi.CommandList, f: u32) {
  if len(r.live_cameras) == 0 do return
  discards := make([dynamic]TextureHandle, context.temp_allocator)
  for &cam in r.live_cameras do for a in AttachmentType do append(&discards, cam.attachments[a])
  // render-to-texture: a material may sample last frame's lit image
  barrier_discard(r, cmd, discards[:], .CULL_TO_INDIRECT, .COLOR_TO_SAMPLE)
  for &cam in r.live_cameras do material_record(r, cmd, f, &cam, .GBUFFER)
  barrier(r, cmd, .GBUFFER_TO_LIGHTING)
  for &cam in r.live_cameras do lighting_record(r, cmd, f, &cam)
  barrier(r, cmd, .LIGHTING_TO_FORWARD)
  for &cam in r.live_cameras do material_record(r, cmd, f, &cam, .FORWARD)
  barrier(r, cmd, .FORWARD_TO_COMPUTE)
}

// Without a main camera nothing else covers the presented image.
@(private = "file")
clear_backbuffer :: proc(r: ^Renderer, cmd: rhi.CommandList) {
  colors := [1]rhi.ColorTarget{{texture = BACKBUFFER, load = .CLEAR}}
  dev.cmd_begin_pass(&r.gpu, cmd, {colors = colors[:]})
  dev.cmd_end_pass(&r.gpu, cmd)
}

// Records, submits and presents the frame flush described. RESIZE: the swapchain is out of date.
@(private)
frame_run :: proc(r: ^Renderer) -> (submitted: bool, status: rhi.FrameStatus) {
  if !dev.ready(&r.gpu) do return false, .OK
  // the frame slot's previous submissions are done: its per-frame buffers may be rewritten
  slot, waited := dev.frame_wait(&r.gpu)
  if !waited do return false, .ERROR
  f := slot.index
  tables_sync(r, f)
  overlay_upload(r, f)
  if !shadow_atlas_reserve(r, f, r.shadow_view_count) do return false, .ERROR
  pyramids_bind(r)
  if begun := dev.frame_begin(&r.gpu, r.framebuffer_size); begun != .OK do return false, begun
  bindless := r.res.caps.bindless
  async := r.res.caps.async_compute
  main_cam: ^FrameCamera
  if r.main_live >= 0 do main_cam = &r.live_cameras[r.main_live]

  // The staged uploads land first: on their own submission, which the compute list waits for
  // and the graphics list follows on its queue, or at the head of the one list.
  uploaded: rhi.SyncPoint
  if async {
    uploads := [1]rhi.CommandList{dev.cmd_begin(&r.gpu, .GRAPHICS)}
    dev.cmd_flush_uploads(&r.gpu, uploads[0])
    dev.cmd_end(&r.gpu, uploads[0])
    uploaded = dev.submit(&r.gpu, {queue = .GRAPHICS, cmds = uploads[:]})
  }
  cmd := dev.cmd_begin(&r.gpu, .GRAPHICS)
  if !async do dev.cmd_flush_uploads(&r.gpu, cmd)
  compute := dev.cmd_begin(&r.gpu, .COMPUTE) if async else cmd
  if !bindless do cull_record(r, cmd, f)
  shadow_record(r, cmd, f)
  camera_passes(r, cmd, f)
  if main_cam != nil {
    slot := main_cam.slot if bindless else main_cam.next_slot
    barrier(r, cmd, .CULL_TO_COPY)
    draw_count_record(r, cmd, slot, f)
    barrier(r, cmd, .COLOR_TO_SAMPLE)
    post_record(r, cmd, f, main_cam)
    debug_line_record(r, cmd, f, main_cam)
  } else {
    clear_backbuffer(r, cmd)
  }
  overlay_record(r, cmd, f)
  // after drawing: the next frame draws what this simulates
  particles_simulate(r, cmd, f)
  if bindless {
    if !async do barrier(r, cmd, .FRAME_TO_CULL)
    cull_record(r, compute, f)
  }
  dev.cmd_end(&r.gpu, cmd)
  graphics_cmds := [1]rhi.CommandList{cmd}
  if !async {
    dev.submit(&r.gpu, {queue = .GRAPHICS, cmds = graphics_cmds[:], present = true})
    return true, dev.frame_present(&r.gpu)
  }
  dev.cmd_end(&r.gpu, compute)

  // submissions chain across frames: compute n waits this frame's uploads, which follow
  // graphics n-1 on its queue (depth, draw lists); graphics n waits compute n-1 (the lists it
  // draws, the depth it rewrites)
  compute_cmds := [1]rhi.CommandList{compute}
  compute_waits := [1]rhi.SyncPoint{uploaded}
  compute_done := dev.submit(&r.gpu, {queue = .COMPUTE, cmds = compute_cmds[:], waits = compute_waits[:]})
  graphics_waits: [1]rhi.SyncPoint
  count := 0
  if r.last_compute.value != 0 {
    graphics_waits[0] = {r.last_compute.queue, r.last_compute.value, {.DRAW_INDIRECT, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}}
    count = 1
  }
  dev.submit(&r.gpu, {queue = .GRAPHICS, cmds = graphics_cmds[:], waits = graphics_waits[:count], present = true})
  r.last_compute = compute_done
  return true, dev.frame_present(&r.gpu)
}
