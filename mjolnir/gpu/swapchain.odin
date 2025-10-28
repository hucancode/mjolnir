package gpu

import "core:log"
import "core:math"
import "core:slice"
import "vendor:glfw"
import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 2

Swapchain :: struct {
  handle:                      vk.SwapchainKHR,
  format:                      vk.SurfaceFormatKHR,
  extent:                      vk.Extent2D,
  images:                      []vk.Image,
  views:                       []vk.ImageView,
  image_index:                 u32,
  in_flight_fences:            [MAX_FRAMES_IN_FLIGHT]vk.Fence,
  image_available_semaphores:  [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
  render_finished_semaphores:  [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
  compute_finished_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
}

swapchain_init :: proc(
  self: ^Swapchain,
  gctx: ^GPUContext,
  window: glfw.WindowHandle,
) -> vk.Result {
  pick_swap_present_mode :: proc(
    present_modes: []vk.PresentModeKHR,
  ) -> vk.PresentModeKHR {
    if slice.contains(present_modes, vk.PresentModeKHR.MAILBOX) {
      return .MAILBOX
    }
    if slice.contains(present_modes, vk.PresentModeKHR.IMMEDIATE) {
      return .IMMEDIATE
    }
    return .FIFO
  }
  pick_swapchain_format :: proc(
    formats: []vk.SurfaceFormatKHR,
  ) -> vk.SurfaceFormatKHR {
    ret := vk.SurfaceFormatKHR{.B8G8R8A8_SRGB, .SRGB_NONLINEAR}
    if len(formats) == 0 {
      log.infof("No surface formats available for swapchain.")
      return ret
    }
    return ret if slice.contains(formats, ret) else formats[0]
  }
  pick_swapchain_extent :: proc(
    capabilities: vk.SurfaceCapabilitiesKHR,
    actual_width, actual_height: u32,
  ) -> vk.Extent2D {
    if capabilities.currentExtent.width != math.max(u32) {
      return capabilities.currentExtent
    }
    return {
      clamp(
        actual_width,
        capabilities.minImageExtent.width,
        capabilities.maxImageExtent.width,
      ),
      clamp(
        actual_height,
        capabilities.minImageExtent.height,
        capabilities.maxImageExtent.height,
      ),
    }
  }
  width, height := glfw.GetFramebufferSize(window)
  support := query_swapchain_support(
    gctx.physical_device,
    gctx.surface,
  ) or_return
  defer swapchain_support_destroy(&support) // Clean up since we're not transferring ownership
  self.format = pick_swapchain_format(support.formats)
  self.extent = pick_swapchain_extent(
    support.capabilities,
    u32(width),
    u32(height),
  )
  log.infof("Swapchain format: %v, extent: %v", self.format, self.extent)
  image_count := support.capabilities.minImageCount + 1
  if support.capabilities.maxImageCount > 0 &&
     image_count > support.capabilities.maxImageCount {
    image_count = support.capabilities.maxImageCount
  }
  create_info := vk.SwapchainCreateInfoKHR {
    sType            = .SWAPCHAIN_CREATE_INFO_KHR,
    surface          = gctx.surface,
    minImageCount    = image_count,
    imageFormat      = self.format.format,
    imageColorSpace  = self.format.colorSpace,
    imageExtent      = self.extent,
    imageArrayLayers = 1,
    imageUsage       = {.COLOR_ATTACHMENT},
    preTransform     = support.capabilities.currentTransform,
    compositeAlpha   = {.OPAQUE},
    presentMode      = pick_swap_present_mode(support.present_modes),
    clipped          = true,
  }
  queue_family_indices := [?]u32{gctx.graphics_family, gctx.present_family}
  if gctx.graphics_family != gctx.present_family {
    create_info.imageSharingMode = .CONCURRENT
    create_info.queueFamilyIndexCount = 2
    create_info.pQueueFamilyIndices = raw_data(queue_family_indices[:])
  } else {
    create_info.imageSharingMode = .EXCLUSIVE
  }
  vk.CreateSwapchainKHR(gctx.device, &create_info, nil, &self.handle) or_return
  swapchain_image_count: u32
  vk.GetSwapchainImagesKHR(
    gctx.device,
    self.handle,
    &swapchain_image_count,
    nil,
  )
  self.images = make([]vk.Image, swapchain_image_count)
  vk.GetSwapchainImagesKHR(
    gctx.device,
    self.handle,
    &swapchain_image_count,
    raw_data(self.images),
  )
  self.views = make([]vk.ImageView, swapchain_image_count)
  for i in 0 ..< swapchain_image_count {
    self.views[i] = create_image_view(
      gctx.device,
      self.images[i],
      self.format.format,
      {.COLOR},
    ) or_return
  }
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    semaphore_info := vk.SemaphoreCreateInfo {
      sType = .SEMAPHORE_CREATE_INFO,
    }
    vk.CreateSemaphore(
      gctx.device,
      &semaphore_info,
      nil,
      &self.image_available_semaphores[i],
    ) or_return
    vk.CreateSemaphore(
      gctx.device,
      &semaphore_info,
      nil,
      &self.render_finished_semaphores[i],
    ) or_return
    vk.CreateSemaphore(
      gctx.device,
      &semaphore_info,
      nil,
      &self.compute_finished_semaphores[i],
    ) or_return
    fence_info := vk.FenceCreateInfo {
      sType = .FENCE_CREATE_INFO,
      flags = {.SIGNALED},
    }
    vk.CreateFence(
      gctx.device,
      &fence_info,
      nil,
      &self.in_flight_fences[i],
    ) or_return
  }
  return .SUCCESS
}

swapchain_destroy :: proc(self: ^Swapchain, device: vk.Device) {
  for view in self.views do vk.DestroyImageView(device, view, nil)
  delete(self.views)
  self.views = nil
  // TODO: destroying image will make app crash
  // for image in self.images do vk.DestroyImage(gctx.device, image, nil)
  delete(self.images)
  self.images = nil
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    vk.DestroySemaphore(device, self.image_available_semaphores[i], nil)
    vk.DestroySemaphore(device, self.render_finished_semaphores[i], nil)
    vk.DestroySemaphore(device, self.compute_finished_semaphores[i], nil)
    vk.DestroyFence(device, self.in_flight_fences[i], nil)
  }
  vk.DestroySwapchainKHR(device, self.handle, nil)
  self.handle = 0
}

swapchain_recreate :: proc(
  gctx: ^GPUContext,
  self: ^Swapchain,
  window: glfw.WindowHandle,
) -> vk.Result {
  vk.DeviceWaitIdle(gctx.device)
  swapchain_destroy(self, gctx.device)
  swapchain_init(self, gctx, window) or_return
  return .SUCCESS
}

acquire_next_image :: proc(
  device: vk.Device,
  self: ^Swapchain,
  frame_index: u32,
) -> (
  result: vk.Result,
) {
  // log.debug("waiting for fence...")
  vk.WaitForFences(
    device,
    1,
    &self.in_flight_fences[frame_index],
    true,
    math.max(u64),
  ) or_return
  vk.AcquireNextImageKHR(
    device,
    self.handle,
    math.max(u64),
    self.image_available_semaphores[frame_index],
    0,
    &self.image_index,
  ) or_return
  vk.ResetFences(device, 1, &self.in_flight_fences[frame_index]) or_return
  result = .SUCCESS
  return
}

submit_queue_and_present :: proc(
  gctx: ^GPUContext,
  self: ^Swapchain,
  command_buffer: ^vk.CommandBuffer,
  frame_index: u32,
  compute_command_buffer: Maybe(vk.CommandBuffer) = nil,
) -> vk.Result {
  wait_semaphores: [dynamic]vk.Semaphore
  wait_stages: [dynamic]vk.PipelineStageFlags
  defer delete(wait_semaphores)
  defer delete(wait_stages)
  append(&wait_semaphores, self.image_available_semaphores[frame_index])
  append(&wait_stages, vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT})
  if compute_cmd, has_compute := compute_command_buffer.?; has_compute {
    if compute_queue, ok := gctx.compute_queue.?; ok {
      append(&wait_semaphores, self.compute_finished_semaphores[frame_index])
      append(&wait_stages, vk.PipelineStageFlags{.VERTEX_INPUT, .COMPUTE_SHADER})
      compute_submit := vk.SubmitInfo {
        sType                = .SUBMIT_INFO,
        commandBufferCount   = 1,
        pCommandBuffers      = &compute_cmd,
        signalSemaphoreCount = 1,
        pSignalSemaphores    = &self.compute_finished_semaphores[frame_index],
      }
      vk.QueueSubmit(compute_queue, 1, &compute_submit, 0) or_return
    }
  }
  graphics_submit := vk.SubmitInfo {
    sType                = .SUBMIT_INFO,
    waitSemaphoreCount   = u32(len(wait_semaphores)),
    pWaitSemaphores      = raw_data(wait_semaphores),
    pWaitDstStageMask    = raw_data(wait_stages),
    commandBufferCount   = 1,
    pCommandBuffers      = command_buffer,
    signalSemaphoreCount = 1,
    pSignalSemaphores    = &self.render_finished_semaphores[frame_index],
  }
  vk.QueueSubmit(
    gctx.graphics_queue,
    1,
    &graphics_submit,
    self.in_flight_fences[frame_index],
  ) or_return
  image_indices := [?]u32{self.image_index}
  present_info := vk.PresentInfoKHR {
    sType              = .PRESENT_INFO_KHR,
    waitSemaphoreCount = 1,
    pWaitSemaphores    = &self.render_finished_semaphores[frame_index],
    swapchainCount     = 1,
    pSwapchains        = &self.handle,
    pImageIndices      = raw_data(image_indices[:]),
  }
  return vk.QueuePresentKHR(gctx.present_queue, &present_info)
}
