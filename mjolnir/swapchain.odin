package mjolnir

import "core:log"
import "core:math"
import "core:slice"
import glfw "vendor:glfw"
import vk "vendor:vulkan"

Swapchain :: struct {
  handle: vk.SwapchainKHR,
  format: vk.SurfaceFormatKHR,
  extent: vk.Extent2D,
  images: []vk.Image,
  views:  []vk.ImageView,
}

swapchain_init :: proc(
  self: ^Swapchain,
  window: glfw.WindowHandle,
) -> vk.Result {
  pick_swap_present_mode :: proc(
    present_modes: []vk.PresentModeKHR,
  ) -> vk.PresentModeKHR {
    return(
      .MAILBOX if slice.contains(present_modes, vk.PresentModeKHR.MAILBOX) else .FIFO \
    )
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
      math.clamp(
        actual_width,
        capabilities.minImageExtent.width,
        capabilities.maxImageExtent.width,
      ),
      math.clamp(
        actual_height,
        capabilities.minImageExtent.height,
        capabilities.maxImageExtent.height,
      ),
    }
  }

  width, height := glfw.GetFramebufferSize(window)
  support := query_swapchain_support(g_physical_device, g_surface) or_return
  defer swapchain_support_deinit(&support)
  self.format = pick_swapchain_format(support.formats)
  self.extent = pick_swapchain_extent(
    support.capabilities,
    u32(width),
    u32(height),
  )
  image_count := support.capabilities.minImageCount + 1
  if support.capabilities.maxImageCount > 0 &&
     image_count > support.capabilities.maxImageCount {
    image_count = support.capabilities.maxImageCount
  }
  create_info := vk.SwapchainCreateInfoKHR {
    sType            = .SWAPCHAIN_CREATE_INFO_KHR,
    surface          = g_surface,
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
  queue_family_indices := [2]u32{g_graphics_family, g_present_family}
  if g_graphics_family != g_present_family {
    create_info.imageSharingMode = .CONCURRENT
    create_info.queueFamilyIndexCount = 2
    create_info.pQueueFamilyIndices = raw_data(queue_family_indices[:])
  } else {
    create_info.imageSharingMode = .EXCLUSIVE
  }
  vk.CreateSwapchainKHR(g_device, &create_info, nil, &self.handle) or_return
  swapchain_image_count: u32
  vk.GetSwapchainImagesKHR(g_device, self.handle, &swapchain_image_count, nil)
  self.images = make([]vk.Image, swapchain_image_count)
  vk.GetSwapchainImagesKHR(
    g_device,
    self.handle,
    &swapchain_image_count,
    raw_data(self.images),
  )
  self.views = make([]vk.ImageView, swapchain_image_count)
  for i in 0 ..< swapchain_image_count {
    self.views[i] = create_image_view(
      self.images[i],
      self.format.format,
      {.COLOR},
    ) or_return
  }
  return .SUCCESS
}

swapchain_deinit :: proc(self: ^Swapchain) {
  for view in self.views do vk.DestroyImageView(g_device, view, nil)
  delete(self.views)
  self.views = nil
  delete(self.images)
  self.images = nil
  vk.DestroySwapchainKHR(g_device, self.handle, nil)
  self.handle = 0
}

swapchain_recreate :: proc(
  self: ^Swapchain,
  window: glfw.WindowHandle,
) -> vk.Result {
  vk.DeviceWaitIdle(g_device)
  swapchain_deinit(self)
  swapchain_init(self, window) or_return
  return .SUCCESS
}

swapchain_acquire_next_image :: proc(
  self: ^Swapchain,
  semaphore: vk.Semaphore,
) -> (
  image_index: u32,
  result: vk.Result,
) {
  result = vk.AcquireNextImageKHR(
    g_device,
    self.handle,
    math.max(u64),
    semaphore,
    0,
    &image_index,
  )
  return
}

swapchain_present :: proc(
  self: ^Swapchain,
  semaphores: [^]vk.Semaphore,
  image_index: u32,
) -> vk.Result {
  image_indices := [?]u32{image_index}
  present_info := vk.PresentInfoKHR {
    sType              = .PRESENT_INFO_KHR,
    waitSemaphoreCount = 1,
    pWaitSemaphores    = semaphores,
    swapchainCount     = 1,
    pSwapchains        = &self.handle,
    pImageIndices      = raw_data(image_indices[:]),
  }
  return vk.QueuePresentKHR(g_present_queue, &present_info)
}
