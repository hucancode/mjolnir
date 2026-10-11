package render

import cont "../containers"
import "core:log"
import "gpu"
import vk "vendor:vulkan"

@(private)
record_compute_commands :: proc(
  self: ^Manager,
  frame_index: u32,
  cmd: vk.CommandBuffer,
) {
  // Compute for frame N builds pyramid[N] and writes the draw lists of
  // frame N+1, culled against pyramid[N].
  next_frame_index := (frame_index + 1) % gpu.FRAMES_IN_FLIGHT
  it := cont.iterator(&self.cameras)
  for cam, handle in cont.next(&it, CameraHandle) {
    occlusion_build_pyramid(
      &self.internal.visibility,
      cmd,
      &self.texture_manager,
      &cam.depth_pyramid[frame_index],
      cam.depth_reduce_descriptor_sets[frame_index][:],
    )
    occlusion_perform_culling(
      &self.internal.visibility,
      cmd,
      handle.index,
      next_frame_index,
      self.node_count,
      &cam.draws,
      cam.descriptor_set[next_frame_index],
    )
  }
  particles_simulate(
    &self.internal.particles,
    cmd,
    self.internal.emitter_buffer.descriptor_sets[frame_index],
    self.internal.forcefield_buffer.descriptor_sets[frame_index],
    self.internal.node_data_buffer.descriptor_sets[frame_index],
  )
}

@(private)
record_debug_line_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam_index: u32,
  cam: ^Camera,
  swapchain_view: vk.ImageView,
  swapchain_extent: vk.Extent2D,
) {
  depth := get_texture_2d(
    &self.texture_manager,
    cam.attachments[.DEPTH][frame_index],
  )
  if depth == nil do return
  debug_line_record(
    &self.internal.debug_line_renderer,
    self.internal.command_buffers[frame_index],
    frame_index,
    self.internal.camera_buffer.descriptor_sets[frame_index],
    cam_index,
    swapchain_view,
    swapchain_extent,
    depth,
  )
}

@(private)
record_post_process_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam: ^Camera,
  swapchain_extent: vk.Extent2D,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
) {
  cmd := self.internal.command_buffers[frame_index]
  if final_image := get_texture_2d(
    &self.texture_manager,
    cam.attachments[.FINAL_IMAGE][frame_index],
  ); final_image != nil {
    gpu.memory_barrier(
      cmd,
      {.COLOR_ATTACHMENT_WRITE},
      {.SHADER_READ},
      {.COLOR_ATTACHMENT_OUTPUT},
      {.FRAGMENT_SHADER},
    )
  }
  gpu.image_discard_barrier(
    cmd,
    swapchain_image,
    {.COLOR_ATTACHMENT_WRITE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.COLOR},
  )
  post_process_record(
    &self.post_process,
    cmd,
    frame_index,
    swapchain_extent,
    swapchain_view,
    cam.attachments[.FINAL_IMAGE][frame_index].index,
    camera_gbuffer(cam, frame_index),
    cam.near,
    cam.far,
    &self.texture_manager,
  )
}

// record_frame drives the entire per-frame command sequence: shadow maps,
// per-camera passes (geometry, lighting, particles, transparency), debug,
// post-process, the 2D overlay (UI + debug UI), async compute, and the
// final swapchain transition to PRESENT_SRC — the one layout transition
// unified image layouts doesn't cover (the compositor is outside Vulkan).
@(private)
record_frame :: proc(
  self: ^Manager,
  frame_index: u32,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
  swapchain_extent: vk.Extent2D,
  debug_ui_enabled: bool,
) -> vk.Result {
  cmd := self.internal.command_buffers[frame_index]
  gpu.begin_record(cmd) or_return
  gpu.record_uploads(&self.gctx, cmd)
  for &fl in self.internal.frame_lights do shadow_record(self, frame_index, &fl)

  it := cont.iterator(&self.cameras)
  for cam, handle in cont.next(&it, CameraHandle) {
    gbuffer_record(self, frame_index, handle.index, cam)
    lighting_record(self, frame_index, handle.index, cam)
    particles_record(self, frame_index, handle.index, cam)
    forward_record(self, frame_index, handle.index, cam)
  }

  main_cam, has_main := cont.get(self.cameras, self.main_camera)
  if has_main {
    record_post_process_pass(
      self,
      frame_index,
      main_cam,
      swapchain_extent,
      swapchain_image,
      swapchain_view,
    )
    record_debug_line_pass(
      self,
      frame_index,
      self.main_camera.index,
      main_cam,
      swapchain_view,
      swapchain_extent,
    )
  }
  overlay_record(
    &self.internal.ui,
    &self.texture_manager,
    cmd,
    swapchain_view,
    swapchain_extent,
    frame_index,
    has_main,
    debug_ui_enabled,
  )
  // Staged commands point into caller memory valid for this frame only.
  self.internal.ui.commands = nil

  // Compute (potentially on a separate async queue command buffer).
  compute_cmd := cmd
  if gpu.has_async_compute(&self.gctx) {
    compute_cmd = self.internal.compute_command_buffers[frame_index]
    gpu.begin_record(compute_cmd) or_return
  }
  record_compute_commands(self, frame_index, compute_cmd)
  if gpu.has_async_compute(&self.gctx) {
    gpu.end_record(compute_cmd) or_return
  }


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
  gpu.end_record(cmd) or_return
  return .SUCCESS
}

// Render and present one frame: close the debug UI opened by debug_ui (plus
// the stats panel when `show_stats`), wait for this frame slot's previous
// submission, advance deferred destruction, upload staged changes, acquire a
// swapchain image, record, submit and present. An out-of-date swapchain is rebuilt at `framebuffer_size`.
// Renders nothing while no level is set up. Returns false on a GPU error.
frame :: proc(
  self: ^Manager,
  framebuffer_size: [2]u32,
  dpi_scale: f32,
  show_stats := false,
) -> bool {
  if show_stats do stats_panel(self)
  debug_ui_drawn := debug_ui_close(self)
  if !self.internal.level_ready do return true
  gctx := &self.gctx
  // Wait before flushing: flush rewrites this frame slot's per-frame buffers.
  res := gpu.wait_frame(gctx.device, &self.swapchain, self.frame_index)
  if res == .SUCCESS {
    tick_resource_pools(self)
    res = flush(self, gctx, self.frame_index)
  }
  if res == .SUCCESS do res = present(self, debug_ui_drawn)
  if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR {
    res = recreate_swapchain(self, framebuffer_size, dpi_scale)
  }
  if res != .SUCCESS {
    log.errorf("Error during rendering %v", res)
    return false
  }
  return true
}

@(private)
present :: proc(self: ^Manager, debug_ui_enabled: bool) -> vk.Result {
  gctx := &self.gctx
  sc := &self.swapchain
  gpu.acquire_next_image(gctx.device, sc, self.frame_index) or_return
  post_process_ensure_images(&self.post_process, gctx, &self.texture_manager, sc.extent, self.frame_index) or_return
  record_frame(
    self,
    self.frame_index,
    sc.images[sc.image_index],
    sc.views[sc.image_index],
    sc.extent,
    debug_ui_enabled,
  ) or_return
  graphics_cmd := self.internal.command_buffers[self.frame_index]
  compute_cmd := self.internal.compute_command_buffers[self.frame_index]
  gpu.submit_queue_and_present(gctx, sc, &graphics_cmd, &compute_cmd, self.frame_index) or_return
  self.frame_index = (self.frame_index + 1) % gpu.FRAMES_IN_FLIGHT
  return .SUCCESS
}
