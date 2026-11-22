package render

import "../containers"
import "rhi"

// The frame is a graph (frame_graph.odin): each pass declares the textures and buffers it uses,
// next to its recording, which reads them back from its uses; the graph orders the passes into
// batches with a barrier between, and places the transient textures, the images a frame makes
// and drops (the G-buffer, ambient occlusion, a lit image under effects, the effects' steps).
// One graphics submission carries the uploads and the frame.

// PassKind is which recording a pass of the frame runs; its arg says over what: the index in
// gpu_work (GPU_*, READBACK), the camera (PYRAMID, the camera passes, PRESENT, DEBUG_LINES),
// effect_arg (EFFECT, POST_SHADER), else nothing.
@(private)
PassKind :: enum u8 {
  GPU_CLEAR,
  GPU_DISPATCH,
  READBACK,
  SKIN,
  LISTS_CLEAR,
  PYRAMID,
  CULL,
  SHADOW_LISTS_CLEAR,
  SHADOW_CULL,
  SHADOW,
  GBUFFER,
  AMBIENT_OCCLUSION,
  LIGHTING,
  FORWARD,
  EFFECT,
  POST_SHADER,
  PRESENT,
  DEBUG_LINES,
  CLEAR_BACKBUFFER,
  OVERLAY,
  PARTICLES_CLEAR,
  PARTICLES_EMIT,
  PARTICLES_SIMULATE,
  CAPTURE,
}

// No use: a pass slot left empty.
@(private)
NO_USE :: GraphUse{}

// A use of a texture; none for 0.
@(private)
texture_use :: proc "contextless" (texture: TextureHandle, access: Access) -> GraphUse {
  return {u32(texture), .TEXTURE, access} if texture != 0 else NO_USE
}

// A use of a buffer; none for 0.
@(private)
buffer_use :: proc "contextless" (buffer: rhi.Buffer, access: Access) -> GraphUse {
  return {u32(buffer), .BUFFER, access} if buffer != 0 else NO_USE
}

// A transient texture of the frame (graph_transient).
@(private)
transient_use :: proc(self: ^Renderer, desc: TextureDesc, access: Access) -> GraphUse {
  return {graph_transient(&self.frame_graph, desc), .TRANSIENT, access}
}

// The same resource as u, used as `access`.
@(private)
as :: proc "contextless" (u: GraphUse, access: Access) -> GraphUse {
  r := u
  r.access = access
  return r
}

// Declares a pass of the frame; its record reads uses back by place (pass_texture).
@(private)
declare :: proc(self: ^Renderer, name: string, type: PassType, kind: PassKind, arg: u32, uses: ..GraphUse) {
  graph_pass(&self.frame_graph, name, type, kind, arg, uses)
}

// A fresh list of uses, for a pass whose uses vary.
@(private)
uses_make :: proc() -> [dynamic]GraphUse {
  return make([dynamic]GraphUse, 0, 16, context.temp_allocator)
}

// The texture of a pass's use number `slot`: its handle, or a transient's texture this frame;
// 0 for none.
@(private)
pass_texture :: proc(self: ^Renderer, pass: GraphPass, slot: int) -> TextureHandle {
  if u32(slot) >= pass.use_count do return 0
  u := self.frame_graph.uses[pass.first_use + u32(slot)]
  if u.kind == .NONE do return 0
  return self.transients[self.frame_graph.placement[u.handle]] if u.kind == .TRANSIENT else TextureHandle(u.handle)
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

// memory_stats is the GPU memory the renderer's buffers and textures hold now. Vulkan reports it
// exactly (every block it took from the driver); WebGPU has no query, so it adds up the sizes
// of the live resources (MemoryStats.exact says which).
memory_stats :: proc(self: ^Renderer) -> MemoryStats {
  if !dev.ready(&self.gpu) do return {}
  return dev.memory_stats(&self.gpu)
}

// Every pass of the frame, in the order they run: your work, skinning, the cull (it sees this
// frame's nodes, so the frame draws what its nodes say), the shadows, each camera's passes and
// effects one camera after another, what draws over the presented image, then the particles the
// next frame draws.
@(private = "file")
frame_declare :: proc(self: ^Renderer) {
  graph_reset(&self.frame_graph)
  gpu_work_declare(self)
  skin_declare(self)
  cull_declare(self)
  shadow_declare(self)
  main := u32(MAIN_CAMERA)
  c: u32
  for i in containers.slots_next(&self.slots[.CAMERAS], &c) do camera_declare(self, i, i == main)
  if containers.slots_live(&self.slots[.CAMERAS], main) {
    debug_line_declare(self, main)
  } else {
    // nothing else covers the presented image
    declare(self, "clear", .RASTER, .CLEAR_BACKBUFFER, 0, texture_use(BACKBUFFER, .COLOR))
  }
  overlay_declare(self)
  particles_declare(self)
  capture_declare(self)
}

// Camera c's passes: G-buffer, ambient occlusion and lighting where it draws a deferred type,
// forward where it draws a forward one, into its image, or a lit image its effects then carry
// into its image; the presented camera's image is then copied to the window.
@(private)
camera_declare :: proc(self: ^Renderer, c: u32, present: bool) {
  targets := &self.camera_targets[c]
  final := texture_use(targets.final[history(self)], .WRITE)
  lit := final if post_steps(self, c) == 0 else transient_use(self, camera_image_desc(.FINAL_IMAGE, targets.extent), .WRITE)
  depth := texture_use(targets.depth, .DEPTH)
  list := buffer_use(self.draw_lists[c].buffer, .INDIRECT)
  skinned := skinned_use(self)
  normal := NO_USE
  if filter_deferred(targets.filter) {
    gbuffer: [4]GraphUse
    for a, i in ([4]CameraImage{.NORMAL, .ALBEDO, .METALLIC_ROUGHNESS, .EMISSIVE}) do gbuffer[i] = transient_use(self, camera_image_desc(a, targets.extent), .COLOR)
    declare(self, "gbuffer", .RASTER, .GBUFFER, c, gbuffer[0], gbuffer[1], gbuffer[2], gbuffer[3], depth, list, as(list, .READ), skinned)
    normal = gbuffer[0]
    ao := NO_USE
    if ambient_occlusion_on(self, c) {
      ao = transient_use(self, camera_image_desc(.AMBIENT_OCCLUSION, targets.extent), .WRITE)
      declare(self, "ambient occlusion", .COMPUTE, .AMBIENT_OCCLUSION, c, as(gbuffer[0], .READ), as(depth, .READ), ao)
    }
    declare(self, "lighting", .COMPUTE, .LIGHTING, c, as(gbuffer[0], .READ), as(gbuffer[1], .READ), as(gbuffer[2], .READ), as(gbuffer[3], .READ), as(depth, .READ), as(ao, .READ), texture_use(self.atlas, .READ), lit)
  }
  if filter_forward(targets.filter) {
    uses := uses_make()
    append(&uses, as(lit, .COLOR), depth, list, as(list, .READ), skinned, texture_use(self.atlas, .READ))
    particles_use(self, &uses)
    gpu_draws_use(self, &uses)
    declare(self, "forward", .RASTER, .FORWARD, c, ..uses[:])
  }
  post_declare(self, c, lit, final, normal)
  if present do declare(self, "present", .RASTER, .PRESENT, c, as(final, .READ), texture_use(BACKBUFFER, .COLOR))
}

@(private = "file")
pass_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, pass: GraphPass) {
  switch pass.kind {
  case .GPU_CLEAR:
    gpu_clear_record(self, cmd, pass.arg)
  case .GPU_DISPATCH:
    gpu_dispatch_record(self, cmd, f, pass.arg)
  case .READBACK:
    readback_record(self, cmd, pass.arg)
  case .SKIN:
    skin_record(self, cmd, f)
  case .LISTS_CLEAR:
    lists_clear_record(self, cmd)
  case .PYRAMID:
    pyramid_record(self, cmd, pass)
  case .CULL:
    cull_record(self, cmd, f)
  case .SHADOW_LISTS_CLEAR:
    draw_lists_clear(self, cmd, SHADOW_DRAW_SLOT)
  case .SHADOW_CULL:
    shadow_cull_record(self, cmd, f)
  case .SHADOW:
    shadow_record(self, cmd, f)
  case .GBUFFER:
    material_record(self, cmd, f, pass, .GBUFFER)
  case .AMBIENT_OCCLUSION:
    ambient_occlusion_record(self, cmd, f, pass)
  case .LIGHTING:
    lighting_record(self, cmd, f, pass)
  case .FORWARD:
    material_record(self, cmd, f, pass, .FORWARD)
  case .EFFECT:
    effect_record(self, cmd, f, pass)
  case .POST_SHADER:
    post_shader_record(self, cmd, f, pass)
  case .PRESENT:
    present_record(self, cmd, f, pass)
  case .DEBUG_LINES:
    debug_line_record(self, cmd, f, pass)
  case .CLEAR_BACKBUFFER:
    colors := [1]rhi.ColorTarget{{texture = BACKBUFFER, load = .CLEAR}}
    dev.cmd_begin_pass(&self.gpu, cmd, {colors = colors[:]})
    dev.cmd_end_pass(&self.gpu, cmd)
  case .OVERLAY:
    overlay_record(self, cmd, f)
  case .PARTICLES_CLEAR:
    particles_clear_record(self, cmd)
  case .PARTICLES_EMIT:
    particles_emit_record(self, cmd, f)
  case .PARTICLES_SIMULATE:
    particles_simulate_record(self, cmd, f)
  case .CAPTURE:
    capture_record(self, cmd)
  }
}

// Makes the textures the transients are placed in, keeping each one whose desc is unchanged:
// the frame's images are made again only when what the frame renders changes (a camera made,
// resized or given effects).
@(private = "file")
transients_realize :: proc(self: ^Renderer) -> bool {
  physical := self.frame_graph.physical[:]
  for desc, p in physical {
    if p < len(self.transients) {
      // the device fills in what a transient leaves zero (mips, layers)
      have := dev.texture_desc(&self.gpu, self.transients[p])
      if have.extent == desc.extent && have.format == desc.format && have.usage == desc.usage do continue
      texture_destroy(self, self.transients[p])
    } else {
      append(&self.transients, 0)
    }
    self.transients[p] = allocate_texture(self, desc, target = true) or_return
  }
  for t in self.transients[len(physical):] do texture_destroy(self, t)
  resize(&self.transients, len(physical))
  return true
}

// Each batch: its barrier and discards, then its passes, each in a label scope; a run of computing
// passes in a batch shares one compute scope.
@(private = "file")
frame_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32) {
  g := &self.frame_graph
  discards := make([dynamic]TextureHandle, context.temp_allocator)
  for bt in g.batches {
    barriers := [1]rhi.Barrier{bt.barrier}
    clear(&discards)
    for p in g.discards[bt.first_discard:][:bt.discard_count] do append(&discards, self.transients[p])
    if bt.barrier.src_stage != {} || len(discards) > 0 do dev.cmd_barrier(&self.gpu, cmd, barriers[:1 if bt.barrier.src_stage != {} else 0], discards[:])
    computing := false
    for pass in g.passes[bt.first:][:bt.count] {
      if computing != (pass.type == .COMPUTE) {
        if computing do dev.cmd_end_compute(&self.gpu, cmd)
        else do dev.cmd_begin_compute(&self.gpu, cmd)
        computing = !computing
      }
      dev.cmd_label_begin(&self.gpu, cmd, pass.name)
      pass_record(self, cmd, f, pass)
      dev.cmd_label_end(&self.gpu, cmd)
    }
    if computing do dev.cmd_end_compute(&self.gpu, cmd)
  }
}

// Records, submits and presents the frame flush wrote. RESIZE: the swapchain is out of date.
@(private)
frame_run :: proc(self: ^Renderer, framebuffer_size: [2]u32) -> (submitted: bool, status: rhi.FrameStatus) {
  if !dev.ready(&self.gpu) do return false, .OK
  // the frame slot's previous submissions are done: its per-frame buffers may be rewritten
  if !dev.frame_wait(&self.gpu) do return false, .ERROR
  f := current_frame(self)
  capture_collect(self)
  if !buffers_reserve(self, f) do return false, .ERROR
  tables_sync(self, f)
  overlay_upload(self, f)
  if !shadow_atlas_reserve(self, f, self.shadow_view_count) do return false, .ERROR
  frame_declare(self)
  graph_compile(&self.frame_graph)
  if !transients_realize(self) do return false, .ERROR
  if begun := dev.frame_begin(&self.gpu, framebuffer_size); begun != .OK do return false, begun

  // The staged uploads land first, on a list of their own, at the head of the submission.
  uploads := dev.cmd_begin(&self.gpu, .GRAPHICS, 0)
  {
    scope(self, uploads, "uploads")
    dev.cmd_flush_uploads(&self.gpu, uploads)
  }
  dev.cmd_end(&self.gpu, uploads)
  cmd := dev.cmd_begin(&self.gpu, .GRAPHICS, 0)
  frame_record(self, cmd, f)
  dev.cmd_end(&self.gpu, cmd)
  cmds := [2]rhi.CommandList{uploads, cmd}
  dev.submit(&self.gpu, {queue = .GRAPHICS, cmds = cmds[:], present = true})
  return true, dev.frame_present(&self.gpu)
}
