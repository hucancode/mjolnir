package render

import cont "../containers"
import "core:log"
import "core:sync"
import "gpu"
import vk "vendor:vulkan"

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
}

@(private)
BARRIERS := [Barrier]struct {
  src_access, dst_access: vk.AccessFlags2,
  src_stage, dst_stage:   vk.PipelineStageFlags2,
} {
  .FILL_TO_COMPUTE = {{.SHADER_WRITE, .TRANSFER_WRITE}, {.SHADER_READ, .SHADER_WRITE}, {.COMPUTE_SHADER, .TRANSFER}, {.COMPUTE_SHADER}},
  .COLOR_TO_SAMPLE = {{.COLOR_ATTACHMENT_WRITE}, {.SHADER_READ}, {.COLOR_ATTACHMENT_OUTPUT}, {.FRAGMENT_SHADER}},
  .GBUFFER_TO_LIGHTING = {
    {.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ, .DEPTH_STENCIL_ATTACHMENT_READ},
    {.COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
  },
  .LIGHTING_TO_FORWARD = {
    {.SHADER_WRITE, .COLOR_ATTACHMENT_WRITE},
    {.INDIRECT_COMMAND_READ, .SHADER_READ, .DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE, .COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
    {.FRAGMENT_SHADER, .COMPUTE_SHADER, .COLOR_ATTACHMENT_OUTPUT},
    {.DRAW_INDIRECT, .VERTEX_SHADER, .EARLY_FRAGMENT_TESTS, .COLOR_ATTACHMENT_OUTPUT},
  },
  .FORWARD_TO_COMPUTE = {{.DEPTH_STENCIL_ATTACHMENT_WRITE}, {.SHADER_READ}, {.LATE_FRAGMENT_TESTS}, {.COMPUTE_SHADER, .FRAGMENT_SHADER}},
  .SHADOW_TO_LIGHTING = {{.DEPTH_STENCIL_ATTACHMENT_WRITE}, {.SHADER_READ}, {.LATE_FRAGMENT_TESTS}, {.FRAGMENT_SHADER}},
  .CULL_TO_INDIRECT = {{.SHADER_WRITE}, {.INDIRECT_COMMAND_READ}, {.COMPUTE_SHADER}, {.DRAW_INDIRECT}},
  .CULL_TO_COPY = {{.SHADER_WRITE}, {.TRANSFER_READ}, {.COMPUTE_SHADER, .DRAW_INDIRECT}, {.TRANSFER}},
  .INDIRECT_TO_FILL = {{}, {}, {.DRAW_INDIRECT}, {.TRANSFER}},
  .FILL_TO_CULL = {{.TRANSFER_WRITE}, {.SHADER_READ, .SHADER_WRITE}, {.TRANSFER}, {.COMPUTE_SHADER}},
  .PARTICLES_TO_FILL = {
    {.SHADER_WRITE},
    {.SHADER_READ, .SHADER_WRITE, .TRANSFER_WRITE},
    {.DRAW_INDIRECT, .VERTEX_SHADER, .COMPUTE_SHADER},
    {.COMPUTE_SHADER, .TRANSFER},
  },
  .POST_PASS = {
    {.COLOR_ATTACHMENT_WRITE},
    {.SHADER_READ, .COLOR_ATTACHMENT_WRITE},
    {.COLOR_ATTACHMENT_OUTPUT, .FRAGMENT_SHADER},
    {.FRAGMENT_SHADER, .COLOR_ATTACHMENT_OUTPUT},
  },
}

@(private)
barrier :: proc(cmd: vk.CommandBuffer, b: Barrier) {
  t := &BARRIERS[b]
  gpu.memory_barrier(cmd, t.src_access, t.dst_access, t.src_stage, t.dst_stage)
}

@(private)
record_compute_commands :: proc(
  self: ^Renderer,
  frame_index: u32,
  cmd: vk.CommandBuffer,
) {
  // frame N builds pyramid[N] from N-1's depth and writes N+1's draw lists
  next_frame_index := (frame_index + 1) % gpu.FRAMES_IN_FLIGHT
  prev_frame_index := (frame_index + gpu.FRAMES_IN_FLIGHT - 1) % gpu.FRAMES_IN_FLIGHT
  // ordering against graphics N-1 is in gpu.submit_queue_and_present
  vk.CmdBindPipeline(cmd, .COMPUTE, self.pipelines[.DEPTH_REDUCE])
  c: u32
  for i in cont.slots_next(&self.camera_slots, &c) {
    cam := &self.cameras[i]
    draw_lists_clear(self, cmd, CAMERA_DRAW_SLOT_BASE + camera_slot(i) + next_frame_index)
    if self.gctx.frame_serial < cam.ready_serial do continue
    occlusion_build_pyramid(self, cmd, camera_slot(i) + frame_index, u32(cam.attachments[.DEPTH][prev_frame_index]))
  }
  barrier(cmd, .FILL_TO_COMPUTE)
  // camera slot 0 is never handed out
  occlusion_cull(self, cmd, CAMERA_VIEW_BASE + 1, self.camera_slots.high_water - 1)
}

// Phase by phase across cameras (G-buffer, lighting, forward) so one barrier
// serves every camera; render scopes cannot hold barriers.
@(private)
record_camera_passes :: proc(self: ^Renderer, frame_index: u32) {
  cmd := self.command_buffers[frame_index]
  cams := make([dynamic]u32, context.temp_allocator)
  c: u32
  for i in cont.slots_next(&self.camera_slots, &c) do append(&cams, i)
  if len(cams) == 0 do return
  discards := make([dynamic]gpu.ImageDiscard, context.temp_allocator)
  for i in cams {
    for a in AttachmentType do append(&discards, gpu.attachment_discard(texture_image(self, self.cameras[i].attachments[a][frame_index])))
  }
  barrier(cmd, .CULL_TO_INDIRECT)
  // render-to-texture: a material may sample last frame's lit image
  barrier(cmd, .COLOR_TO_SAMPLE)
  gpu.image_discard_barrier(cmd, ..discards[:])
  for i in cams do material_pass_record(self, frame_index, i, .GBUFFER)
  barrier(cmd, .GBUFFER_TO_LIGHTING)
  for i in cams do lighting_record(self, frame_index, i)
  barrier(cmd, .LIGHTING_TO_FORWARD)
  for i in cams do material_pass_record(self, frame_index, i, .FORWARD)
  barrier(cmd, .FORWARD_TO_COMPUTE)
}

// PRESENT_SRC is the one layout transition unified image layouts do not cover.
@(private)
record_frame :: proc(self: ^Renderer, frame_index: u32, debug_ui_enabled: bool) -> vk.Result {
  cmd := self.command_buffers[frame_index]
  sc := &self.swapchain
  swapchain_image, swapchain_view := sc.images[sc.image_index], sc.views[sc.image_index]
  gpu.begin_record(cmd) or_return
  bind_scene_sets(self, cmd, .GRAPHICS, frame_index)
  bind_scene_sets(self, cmd, .COMPUTE, frame_index)
  gpu.record_uploads(&self.gctx, cmd)
  shadow_record(self, frame_index)

  record_camera_passes(self, frame_index)

  main_cam, has_main := main_camera(self)
  if has_main {
    draw_lists_copy_counts(
      self,
      cmd,
      CAMERA_DRAW_SLOT_BASE + camera_slot(u32(self.main_camera)) + frame_index,
      &self.draw_count_readback[frame_index],
    )
    barrier(cmd, .COLOR_TO_SAMPLE)
    gpu.image_discard_barrier(
      cmd,
      {swapchain_image, {.COLOR}, {.COLOR_ATTACHMENT_WRITE}, {.COLOR_ATTACHMENT_OUTPUT}},
    )
    post_process_record(self, frame_index, sc.extent, swapchain_view, main_cam)
    debug_line_record(
      self,
      frame_index,
      u32(self.main_camera),
      swapchain_view,
      sc.extent,
      texture_image(self, main_cam.attachments[.DEPTH][frame_index]),
    )
  }
  overlay_record(self, cmd, swapchain_view, sc.extent, frame_index, has_main, debug_ui_enabled)
  // staged commands point into caller memory valid for this frame only
  self.ui.commands = nil

  // after drawing: the next frame draws what this simulates
  particles_simulate(self, cmd)
  // separate submission, on the async compute queue when there is one
  compute_cmd := self.compute_command_buffers[frame_index]
  gpu.begin_record(compute_cmd) or_return
  bind_scene_sets(self, compute_cmd, .COMPUTE, frame_index)
  record_compute_commands(self, frame_index, compute_cmd)
  vk.EndCommandBuffer(compute_cmd) or_return

  gpu.present_barrier(cmd, swapchain_image)
  vk.EndCommandBuffer(cmd) or_return
  return .SUCCESS
}

// frame renders and presents one frame, closing the debug UI opened by debug_ui
// (plus a stats panel when show_stats). An out-of-date swapchain is rebuilt at
// framebuffer_size. It returns false on a GPU error.
frame :: proc(
  self: ^Renderer,
  framebuffer_size: [2]u32,
  dpi_scale: f32,
  show_stats := false,
) -> bool {
  gctx := &self.gctx
  frame_index := write_frame(self)
  if show_stats do stats_panel(self)
  debug_ui_drawn := debug_ui_close(self)
  // until hand_off the GPU may read this frame's tables
  guard(self)
  tick_resource_pools(self)
  res := flush(self, frame_index)
  sc := &self.swapchain
  if res == .SUCCESS do res = gpu.acquire_next_image(gctx.device, sc, frame_index)
  if res == .SUCCESS do res = record_frame(self, frame_index, debug_ui_drawn)
  if res == .SUCCESS {
    serial := gctx.frame_serial
    res = gpu.submit_queue_and_present(gctx, sc, self.command_buffers[frame_index], self.compute_command_buffers[frame_index])
    // submitted, even when presenting failed
    if gctx.frame_serial != serial {
      if handed := hand_off(self, frame_index); handed != .SUCCESS do res = handed
    }
  }
  if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR {
    res = recreate_swapchain(self, framebuffer_size, dpi_scale)
  }
  if res != .SUCCESS {
    log.errorf("Error during rendering %v", res)
    return false
  }
  return true
}
