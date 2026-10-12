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
  // Compute for frame N builds pyramid[N] from frame N-1's depth and writes
  // the draw lists of frame N+1, culled against pyramid[N].
  next_frame_index := (frame_index + 1) % gpu.FRAMES_IN_FLIGHT
  prev_frame_index := (frame_index + gpu.FRAMES_IN_FLIGHT - 1) % gpu.FRAMES_IN_FLIGHT
  // Same queue: frame N-1's depth writes land before the pyramids read them,
  // and the draws of the lists finish before they are cleared. The async
  // queue gets this from its semaphore wait.
  if !gpu.has_async_compute(&self.gctx) {
    gpu.memory_barrier(
      cmd,
      {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      {.SHADER_READ},
      {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS, .DRAW_INDIRECT},
      {.COMPUTE_SHADER, .TRANSFER},
    )
  }
  // Every camera's pyramid and list clear, then one cull over every camera
  // slot; an empty slot's view draws nothing.
  vk.CmdBindPipeline(cmd, .COMPUTE, self.internal.visibility.reduce_pipeline)
  it := cont.iterator(&self.cameras)
  for cam in cont.next(&it, CameraHandle) {
    draw_lists_clear(&cam.draws, cmd, next_frame_index)
    if self.gctx.frame_serial < cam.ready_serial do continue
    occlusion_build_pyramid(
      self,
      cmd,
      &cam.depth_pyramid[frame_index],
      cam.attachments[.DEPTH][prev_frame_index].index,
    )
  }
  gpu.memory_barrier(
    cmd,
    {.SHADER_WRITE, .TRANSFER_WRITE},
    {.SHADER_READ, .SHADER_WRITE},
    {.COMPUTE_SHADER, .TRANSFER},
    {.COMPUTE_SHADER},
  )
  occlusion_cull(self, cmd, CAMERA_VIEW_BASE, u32(len(self.cameras.entries)))
}

// Record every camera's passes phase by phase, so one barrier orders each
// phase after the previous one for every camera: G-buffer, lighting, then
// forward (particles and transparency). Render scopes cannot hold barriers,
// so the passes record only their scopes.
@(private)
record_camera_passes :: proc(self: ^Manager, frame_index: u32) {
  cmd := self.internal.command_buffers[frame_index]
  discards := make([dynamic]gpu.ImageDiscard, context.temp_allocator)
  it := cont.iterator(&self.cameras)
  for cam in cont.next(&it, CameraHandle) {
    for a in AttachmentType do append(&discards, gpu.attachment_discard(camera_image(self, cam, a, frame_index)))
  }
  if len(discards) == 0 do return
  // The draw lists written by culling become indirect arguments.
  indirect_barrier(cmd)
  gpu.image_discard_barrier(cmd, ..discards[:])
  it = cont.iterator(&self.cameras)
  for cam, handle in cont.next(&it, CameraHandle) do material_pass_record(self, frame_index, handle.index, cam, .GBUFFER)
  // G-buffer and depth writes reach the lighting shaders and depth tests.
  gpu.memory_barrier(
    cmd,
    {.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ, .DEPTH_STENCIL_ATTACHMENT_READ},
    {.COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
  )
  it = cont.iterator(&self.cameras)
  for cam, handle in cont.next(&it, CameraHandle) do lighting_record(self, frame_index, handle.index, cam)
  // The lit color reaches the forward blend; the previous frame's
  // simulation wrote the particles the forward pass draws.
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
  it = cont.iterator(&self.cameras)
  for cam, handle in cont.next(&it, CameraHandle) do material_pass_record(self, frame_index, handle.index, cam, .FORWARD)
  // Depth reaches the depth pyramid build of the next compute work.
  gpu.memory_barrier(
    cmd,
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.LATE_FRAGMENT_TESTS},
    {.COMPUTE_SHADER, .FRAGMENT_SHADER},
  )
}

// record_frame drives the entire per-frame command sequence: shadow maps,
// per-camera passes (geometry, lighting, forward: particles and transparency), debug,
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
  bind_scene_sets(self, cmd, .GRAPHICS, frame_index)
  bind_scene_sets(self, cmd, .COMPUTE, frame_index)
  gpu.record_uploads(&self.gctx, cmd)
  shadow_record(self, frame_index)

  record_camera_passes(self, frame_index)

  main_cam, has_main := cont.get(self.cameras, self.main_camera)
  if has_main {
    draw_lists_copy_counts(&main_cam.draws, cmd, frame_index, &self.internal.draw_count_readback[frame_index])
    // The lit image reaches post-processing, which writes the swapchain image.
    gpu.memory_barrier(cmd, {.COLOR_ATTACHMENT_WRITE}, {.SHADER_READ}, {.COLOR_ATTACHMENT_OUTPUT}, {.FRAGMENT_SHADER})
    gpu.image_discard_barrier(
      cmd,
      {swapchain_image, {.COLOR}, {.COLOR_ATTACHMENT_WRITE}, {.COLOR_ATTACHMENT_OUTPUT}},
    )
    post_process_record(
      &self.post_process,
      cmd,
      frame_index,
      swapchain_extent,
      swapchain_view,
      main_cam,
      &self.texture_manager,
      self.internal.scene.layout,
    )
    debug_line_record(
      &self.internal.debug_line_renderer,
      cmd,
      frame_index,
      self.internal.scene.layout,
      self.main_camera.index,
      swapchain_view,
      swapchain_extent,
      camera_image(self, main_cam, .DEPTH, frame_index),
    )
  }
  overlay_record(
    &self.internal.ui,
    self.internal.scene.layout,
    cmd,
    swapchain_view,
    swapchain_extent,
    frame_index,
    has_main,
    debug_ui_enabled,
  )
  // Staged commands point into caller memory valid for this frame only.
  self.internal.ui.commands = nil

  // Simulate after drawing: the next frame draws this frame's particles.
  particles_simulate(self, cmd)
  // Culling and the depth pyramid, on the async compute queue when there is
  // one (ordering in gpu.submit_queue_and_present).
  compute_cmd := cmd
  if gpu.has_async_compute(&self.gctx) {
    compute_cmd = self.internal.compute_command_buffers[frame_index]
    gpu.begin_record(compute_cmd) or_return
    bind_scene_sets(self, compute_cmd, .COMPUTE, frame_index)
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
  gctx := &self.gctx
  // Wait before flushing: flush rewrites this frame slot's per-frame buffers,
  // and the stats panel reads its draw count readback.
  res := gpu.wait_frame(gctx) if self.internal.level_ready else .SUCCESS
  if show_stats do stats_panel(self)
  debug_ui_drawn := debug_ui_close(self)
  if !self.internal.level_ready do return true
  if res == .SUCCESS {
    tick_resource_pools(self)
    res = flush(self, gctx, self.frame_index)
  }
  if res == .SUCCESS do res = present(self, debug_ui_drawn)
  // the slot of the next submission, whether or not presenting succeeded
  self.frame_index = u32(gctx.frame_serial % gpu.FRAMES_IN_FLIGHT)
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
  return .SUCCESS
}
