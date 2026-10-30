package render

import "../containers"
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
  INDIRECT_TO_FILL,
  FILL_TO_CULL,
  // the previous simulation and this frame's draws use what the particle pass rewrites
  PARTICLES_TO_FILL,
  POST_PASS,
  // the previous frame's draws read the skinned vertices the skinning pass rewrites
  DRAW_TO_SKIN,
  SKIN_TO_DRAW,
  // the cull recorded after the frame on one queue: it rewrites the lists and pyramids that
  // draws and the previous cull read, from depth the frame wrote
  FRAME_TO_CULL,
  // your work (gpu.odin): after the uploads and the previous frame's draws and copies, between
  // two of its steps, and before what draws, samples or copies back its results
  FRAME_TO_GPU_WORK,
  GPU_WORK,
  GPU_WORK_TO_DRAW,
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
    dst_stage = {.COMPUTE_SHADER, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
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
    src_stage = {.LATE_FRAGMENT_TESTS}, dst_stage = {.COMPUTE_SHADER},
    src_access = {.DEPTH_ATTACHMENT_WRITE}, dst_access = {.SHADER_READ},
  },
  .CULL_TO_INDIRECT = {
    src_stage = {.COMPUTE_SHADER}, dst_stage = {.DRAW_INDIRECT},
    src_access = {.SHADER_WRITE}, dst_access = {.INDIRECT_READ},
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
  .DRAW_TO_SKIN = {src_stage = {.VERTEX_SHADER}, dst_stage = {.COMPUTE_SHADER}},
  .SKIN_TO_DRAW = {
    src_stage = {.COMPUTE_SHADER}, dst_stage = {.VERTEX_SHADER},
    src_access = {.SHADER_WRITE}, dst_access = {.SHADER_READ},
  },
  .FRAME_TO_GPU_WORK = {
    src_stage = {.DRAW_INDIRECT, .VERTEX_SHADER, .FRAGMENT_SHADER, .COMPUTE_SHADER, .TRANSFER}, dst_stage = {.COMPUTE_SHADER, .TRANSFER},
    src_access = {.SHADER_WRITE, .TRANSFER_WRITE}, dst_access = {.SHADER_READ, .SHADER_WRITE, .TRANSFER_WRITE},
  },
  .GPU_WORK = {
    src_stage = {.COMPUTE_SHADER, .TRANSFER}, dst_stage = {.DRAW_INDIRECT, .COMPUTE_SHADER, .TRANSFER},
    src_access = {.SHADER_WRITE, .TRANSFER_WRITE}, dst_access = {.INDIRECT_READ, .SHADER_READ, .SHADER_WRITE, .TRANSFER_WRITE},
  },
  .GPU_WORK_TO_DRAW = {
    src_stage = {.COMPUTE_SHADER, .TRANSFER}, dst_stage = {.DRAW_INDIRECT, .VERTEX_SHADER, .FRAGMENT_SHADER, .COMPUTE_SHADER, .TRANSFER},
    src_access = {.SHADER_WRITE, .TRANSFER_WRITE}, dst_access = {.INDIRECT_READ, .SHADER_READ, .TRANSFER_READ},
  },
  .FRAME_TO_CULL = {
    src_stage = {.DRAW_INDIRECT, .COMPUTE_SHADER, .TRANSFER, .LATE_FRAGMENT_TESTS}, dst_stage = {.COMPUTE_SHADER, .TRANSFER},
    src_access = {.SHADER_WRITE, .TRANSFER_WRITE, .DEPTH_ATTACHMENT_WRITE}, dst_access = {.SHADER_READ, .SHADER_WRITE, .TRANSFER_WRITE},
  },
}

// Records `barriers` as one dependency.
@(private)
barrier :: proc(self: ^Renderer, cmd: rhi.CommandList, barriers: ..Barrier) {
  barrier_discard(self, cmd, nil, ..barriers)
}

// Records `barriers` and the discard of `textures` as one dependency.
@(private)
barrier_discard :: proc(self: ^Renderer, cmd: rhi.CommandList, textures: []TextureHandle, barriers: ..Barrier) {
  descs: [len(Barrier)]rhi.Barrier
  for b, i in barriers do descs[i] = BARRIERS[b]
  dev.cmd_barrier(&self.gpu, cmd, descs[:len(barriers)], textures)
}

// Opens a label scope named `name` on cmd (a debugger's marker, timed where the device can:
// gpu_timings), closed at the end of the caller's block.
@(private, deferred_in = scope_end)
scope :: proc(self: ^Renderer, cmd: rhi.CommandList, name: string) {
  dev.cmd_label_begin(&self.gpu, cmd, name)
}

@(private)
scope_end :: proc(self: ^Renderer, cmd: rhi.CommandList, name: string) {
  dev.cmd_label_end(&self.gpu, cmd)
}

// gpu_timings is the GPU time of each pass of a recent frame, in the order they
// began; empty where the device cannot time them. Valid until the next frame.
gpu_timings :: proc(self: ^Renderer) -> []Timing {
  if !dev.ready(&self.gpu) do return nil
  return dev.frame_timings(&self.gpu)
}

// Phase by phase across cameras (G-buffer, lighting, forward) so one barrier serves every
// camera; render scopes cannot hold barriers. `closing` ends them, as one barrier.
@(private = "file")
camera_passes :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, closing: ..Barrier) {
  if self.slots[.CAMERAS].count == 0 do return
  discards := make([dynamic]TextureHandle, context.temp_allocator)
  c: u32
  for i in containers.slots_next(&self.slots[.CAMERAS], &c) do for a in CameraImage do append(&discards, self.camera_targets[i].images[a][f])
  // render-to-texture: a material may sample last frame's lit image
  barrier_discard(self, cmd, discards[:], .CULL_TO_INDIRECT, .COLOR_TO_SAMPLE)
  {
    scope(self, cmd, "gbuffer")
    c = 0
    for i in containers.slots_next(&self.slots[.CAMERAS], &c) do material_record(self, cmd, f, i, .GBUFFER)
  }
  barrier(self, cmd, .GBUFFER_TO_LIGHTING)
  {
    scope(self, cmd, "ambient occlusion")
    c = 0
    for i in containers.slots_next(&self.slots[.CAMERAS], &c) do ambient_occlusion_record(self, cmd, f, i)
  }
  barrier(self, cmd, .FILL_TO_COMPUTE)
  {
    scope(self, cmd, "lighting")
    c = 0
    for i in containers.slots_next(&self.slots[.CAMERAS], &c) do lighting_record(self, cmd, f, i)
  }
  barrier(self, cmd, .LIGHTING_TO_FORWARD)
  {
    scope(self, cmd, "forward")
    c = 0
    for i in containers.slots_next(&self.slots[.CAMERAS], &c) do material_record(self, cmd, f, i, .FORWARD)
  }
  barrier(self, cmd, .COLOR_TO_SAMPLE)
  {
    scope(self, cmd, "anti-aliasing")
    c = 0
    for i in containers.slots_next(&self.slots[.CAMERAS], &c) do anti_aliasing_record(self, cmd, f, i)
  }
  barrier(self, cmd, ..closing)
}

// Records, submits and presents the frame flush wrote. RESIZE: the swapchain is out of date.
@(private)
frame_run :: proc(self: ^Renderer, framebuffer_size: [2]u32) -> (submitted: bool, status: rhi.FrameStatus) {
  if !dev.ready(&self.gpu) do return false, .OK
  // the frame slot's previous submissions are done: its per-frame buffers may be rewritten
  if !dev.frame_wait(&self.gpu) do return false, .ERROR
  f := current_frame(self)
  capture_collect(self)
  tables_sync(self, f)
  overlay_upload(self, f)
  if !shadow_atlas_reserve(self, f, self.shadow_view_count) do return false, .ERROR
  pyramids_bind(self, f)
  if begun := dev.frame_begin(&self.gpu, framebuffer_size); begun != .OK do return false, begun
  async := dev.caps(&self.gpu).async_compute
  main := u32(self.main_camera)
  has_main := containers.slots_live(&self.slots[.CAMERAS], main)

  // The staged uploads land first, on a list of their own: their own submission, which the
  // compute list waits for and the graphics list follows on its queue, or the head of the one.
  uploads := dev.cmd_begin(&self.gpu, .GRAPHICS, 0)
  {
    scope(self, uploads, "uploads")
    dev.cmd_flush_uploads(&self.gpu, uploads)
  }
  dev.cmd_end(&self.gpu, uploads)
  cmd := dev.cmd_begin(&self.gpu, .GRAPHICS, 0)
  compute := dev.cmd_begin(&self.gpu, .COMPUTE, 0) if async else cmd
  {
    scope(self, cmd, "gpu work")
    gpu_work_record(self, cmd, f)
  }
  // before everything that draws a skinned node, so on the graphics list
  {
    scope(self, cmd, "skinning")
    skin_record(self, cmd, f)
  }
  // a when body is no scope of its own: the braces end the label
  when !BINDLESS {{
    scope(self, cmd, "cull")
    cull_record(self, cmd, f)
  }}
  {
    scope(self, cmd, "shadows")
    shadow_record(self, cmd, f)
  }
  camera_passes(self, cmd, f, .FORWARD_TO_COMPUTE, .COLOR_TO_SAMPLE)
  {
    scope(self, cmd, "post")
    c: u32
    for i in containers.slots_next(&self.slots[.CAMERAS], &c) do post_record(self, cmd, f, i, i == main)
  }
  if has_main {
    debug_line_record(self, cmd, f, main)
  } else {
    // nothing else covers the presented image
    colors := [1]rhi.ColorTarget{{texture = BACKBUFFER, load = .CLEAR}}
    dev.cmd_begin_pass(&self.gpu, cmd, {colors = colors[:]})
    dev.cmd_end_pass(&self.gpu, cmd)
  }
  {
    scope(self, cmd, "overlay")
    overlay_record(self, cmd, f)
  }
  // after drawing: the next frame draws what this simulates
  {
    scope(self, cmd, "particles")
    particles_simulate(self, cmd, f)
  }
  when BINDLESS {{
    if !async do barrier(self, cmd, .FRAME_TO_CULL)
    scope(self, compute, "cull")
    cull_record(self, compute, f)
  }}
  capture_record(self, cmd)
  dev.cmd_end(&self.gpu, cmd)
  if !async {
    cmds := [2]rhi.CommandList{uploads, cmd}
    dev.submit(&self.gpu, {queue = .GRAPHICS, cmds = cmds[:], present = true})
    return true, dev.frame_present(&self.gpu)
  }
  upload_cmds := [1]rhi.CommandList{uploads}
  uploaded := dev.submit(&self.gpu, {queue = .GRAPHICS, cmds = upload_cmds[:]})
  dev.cmd_end(&self.gpu, compute)

  // submissions chain across frames: compute n waits this frame's uploads, which follow
  // graphics n-1 on its queue (depth, draw lists); graphics n waits compute n-1 (the lists it
  // draws, the depth it rewrites)
  compute_cmds := [1]rhi.CommandList{compute}
  compute_waits := [1]rhi.SyncPoint{uploaded}
  compute_done := dev.submit(&self.gpu, {queue = .COMPUTE, cmds = compute_cmds[:], waits = compute_waits[:]})
  graphics_waits: [1]rhi.SyncPoint
  count := 0
  if self.last_compute.value != 0 {
    graphics_waits[0] = {self.last_compute.queue, self.last_compute.value, {.DRAW_INDIRECT, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}}
    count = 1
  }
  graphics_cmds := [1]rhi.CommandList{cmd}
  dev.submit(&self.gpu, {queue = .GRAPHICS, cmds = graphics_cmds[:], waits = graphics_waits[:count], present = true})
  self.last_compute = compute_done
  return true, dev.frame_present(&self.gpu)
}
