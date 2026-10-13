package render

import cont "../containers"
import "core:log"
import "core:sync"
import "gpu"
import vk "vendor:vulkan"

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
    draw_lists_clear(&cam.draws, cmd, next_frame_index)
    if self.gctx.frame_serial < cam.ready_serial do continue
    occlusion_build_pyramid(
      self,
      cmd,
      &cam.depth_pyramid[frame_index],
      u32(cam.attachments[.DEPTH][prev_frame_index]),
    )
  }
  gpu.memory_barrier(
    cmd,
    {.SHADER_WRITE, .TRANSFER_WRITE},
    {.SHADER_READ, .SHADER_WRITE},
    {.COMPUTE_SHADER, .TRANSFER},
    {.COMPUTE_SHADER},
  )
  // camera slot 0 is never handed out
  occlusion_cull(self, cmd, CAMERA_VIEW_BASE + 1, self.camera_slots.high_water - 1)
}

// Phase by phase across cameras (G-buffer, lighting, forward) so one barrier
// serves every camera; render scopes cannot hold barriers.
@(private)
record_camera_passes :: proc(self: ^Renderer, frame_index: u32) {
  cmd := self.command_buffers[frame_index]
  discards := make([dynamic]gpu.ImageDiscard, context.temp_allocator)
  c: u32
  for i in cont.slots_next(&self.camera_slots, &c) {
    cam := &self.cameras[i]
    for a in AttachmentType do append(&discards, gpu.attachment_discard(texture_image(self, cam.attachments[a][frame_index])))
  }
  if len(discards) == 0 do return
  indirect_barrier(cmd)
  // render-to-texture: a material may sample last frame's lit image
  gpu.memory_barrier(cmd, {.COLOR_ATTACHMENT_WRITE}, {.SHADER_READ}, {.COLOR_ATTACHMENT_OUTPUT}, {.FRAGMENT_SHADER})
  gpu.image_discard_barrier(cmd, ..discards[:])
  c = 0
  for i in cont.slots_next(&self.camera_slots, &c) do material_pass_record(self, frame_index, i, &self.cameras[i], .GBUFFER)
  gpu.memory_barrier(
    cmd,
    {.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ, .DEPTH_STENCIL_ATTACHMENT_READ},
    {.COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
  )
  c = 0
  for i in cont.slots_next(&self.camera_slots, &c) do lighting_record(self, frame_index, i, &self.cameras[i])
  gpu.memory_barrier(
    cmd,
    {.SHADER_WRITE, .COLOR_ATTACHMENT_WRITE},
    {
      .INDIRECT_COMMAND_READ,
      .SHADER_READ,
      .DEPTH_STENCIL_ATTACHMENT_READ,
      .DEPTH_STENCIL_ATTACHMENT_WRITE,
      .COLOR_ATTACHMENT_READ,
      .COLOR_ATTACHMENT_WRITE,
    },
    {.FRAGMENT_SHADER, .COMPUTE_SHADER, .COLOR_ATTACHMENT_OUTPUT},
    {.DRAW_INDIRECT, .VERTEX_SHADER, .EARLY_FRAGMENT_TESTS, .COLOR_ATTACHMENT_OUTPUT},
  )
  c = 0
  for i in cont.slots_next(&self.camera_slots, &c) do material_pass_record(self, frame_index, i, &self.cameras[i], .FORWARD)
  gpu.memory_barrier(
    cmd,
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.LATE_FRAGMENT_TESTS},
    {.COMPUTE_SHADER, .FRAGMENT_SHADER},
  )
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
    draw_lists_copy_counts(&main_cam.draws, cmd, frame_index, &self.draw_count_readback[frame_index])
    gpu.memory_barrier(cmd, {.COLOR_ATTACHMENT_WRITE}, {.SHADER_READ}, {.COLOR_ATTACHMENT_OUTPUT}, {.FRAGMENT_SHADER})
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

  present_barrier := vk.ImageMemoryBarrier2 {
    sType = .IMAGE_MEMORY_BARRIER_2,
    srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
    srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
    dstStageMask = {.BOTTOM_OF_PIPE},
    oldLayout = .GENERAL,
    newLayout = .PRESENT_SRC_KHR,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = swapchain_image,
    subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
  }
  present_dep := vk.DependencyInfo {
    sType                   = .DEPENDENCY_INFO,
    imageMemoryBarrierCount = 1,
    pImageMemoryBarriers    = &present_barrier,
  }
  vk.CmdPipelineBarrier2(cmd, &present_dep)
  vk.EndCommandBuffer(cmd) or_return
  return .SUCCESS
}

// frame renders and presents one frame, closing the debug UI opened by debug_ui
// (plus a stats panel when show_stats). An out-of-date swapchain is rebuilt at
// framebuffer_size. It renders nothing while no level is set up, and returns
// false on a GPU error.
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
  if !self.level_ready do return true
  // until hand_off the GPU may read this frame's tables
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  tick_resource_pools(self)
  res := flush(self, frame_index)
  sc := &self.swapchain
  if res == .SUCCESS do res = gpu.acquire_next_image(gctx.device, sc, frame_index)
  if res == .SUCCESS do res = post_process_ensure_images(self, sc.extent, frame_index)
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
