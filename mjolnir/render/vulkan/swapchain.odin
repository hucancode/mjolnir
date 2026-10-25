package vulkan_backend

import "core:log"
import "core:math"
import "core:slice"
import vk "vendor:vulkan"

// Swapchain holds the presentation images and their per-frame semaphores.
Swapchain :: struct {
  handle:                      vk.SwapchainKHR,
  format:                      vk.SurfaceFormatKHR,
  extent:                      vk.Extent2D,
  images:                      []vk.Image,
  views:                       []vk.ImageView,
  image_index:                 u32,
  image_available_semaphores:  [FRAMES_IN_FLIGHT]vk.Semaphore, // Per frame-in-flight
  render_finished_semaphores:  []vk.Semaphore, // Per swapchain image (for presentation sync)
}

// swapchain_init creates the swapchain, image views and semaphores for framebuffer_size.
swapchain_init :: proc(
  self: ^Swapchain,
  gctx: ^GPUContext,
  framebuffer_size: [2]u32,
) -> (
  ret: vk.Result,
) {
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
  capabilities, formats, present_modes := query_swapchain_support(gctx.physical_device, gctx.surface) or_return
  self.format = pick_swapchain_format(formats)
  self.extent = pick_swapchain_extent(
    capabilities,
    framebuffer_size.x,
    framebuffer_size.y,
  )
  log.infof("Swapchain format: %v, extent: %v", self.format, self.extent)
  image_count := capabilities.minImageCount + 1
  if capabilities.maxImageCount > 0 do image_count = min(image_count, capabilities.maxImageCount)
  create_info := vk.SwapchainCreateInfoKHR {
    sType            = .SWAPCHAIN_CREATE_INFO_KHR,
    surface          = gctx.surface,
    minImageCount    = image_count,
    imageFormat      = self.format.format,
    imageColorSpace  = self.format.colorSpace,
    imageExtent      = self.extent,
    imageArrayLayers = 1,
    imageUsage       = {.COLOR_ATTACHMENT, .TRANSFER_SRC},
    preTransform     = capabilities.currentTransform,
    compositeAlpha   = {.OPAQUE},
    presentMode      = pick_swap_present_mode(present_modes),
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
  defer if ret != .SUCCESS do delete(self.images)
  vk.GetSwapchainImagesKHR(
    gctx.device,
    self.handle,
    &swapchain_image_count,
    raw_data(self.images),
  )
  self.views = make([]vk.ImageView, swapchain_image_count)
  defer if ret != .SUCCESS do delete(self.views)
  for i in 0 ..< swapchain_image_count {
    vk.CreateImageView(
      gctx.device,
      &vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = self.images[i],
        viewType = .D2,
        format = self.format.format,
        components = {
          r = .IDENTITY,
          g = .IDENTITY,
          b = .IDENTITY,
          a = .IDENTITY,
        },
        subresourceRange = {
          aspectMask = {.COLOR},
          levelCount = 1,
          layerCount = 1,
        },
      },
      nil,
      &self.views[i],
    ) or_return
  }
  self.render_finished_semaphores = make([]vk.Semaphore, swapchain_image_count)
  defer if ret != .SUCCESS do delete(self.render_finished_semaphores)
  semaphore_info := vk.SemaphoreCreateInfo {
    sType = .SEMAPHORE_CREATE_INFO,
  }
  for i in 0 ..< swapchain_image_count {
    vk.CreateSemaphore(
      gctx.device,
      &semaphore_info,
      nil,
      &self.render_finished_semaphores[i],
    ) or_return
  }
  for i in 0 ..< FRAMES_IN_FLIGHT {
    vk.CreateSemaphore(
      gctx.device,
      &semaphore_info,
      nil,
      &self.image_available_semaphores[i],
    ) or_return
  }
  ret = .SUCCESS
  return
}

// swapchain_destroy destroys the swapchain views, semaphores and handle.
swapchain_destroy :: proc(self: ^Swapchain, device: vk.Device) {
  for view in self.views do vk.DestroyImageView(device, view, nil)
  delete(self.views)
  self.views = nil
  // the images belong to the swapchain: destroying them crashes
  delete(self.images)
  self.images = nil
  for semaphore in self.render_finished_semaphores {
    vk.DestroySemaphore(device, semaphore, nil)
  }
  delete(self.render_finished_semaphores)
  self.render_finished_semaphores = nil
  for semaphore in self.image_available_semaphores {
    vk.DestroySemaphore(device, semaphore, nil)
  }
  vk.DestroySwapchainKHR(device, self.handle, nil)
  self.handle = 0
}
