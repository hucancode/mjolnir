package mjolnir

import "core:fmt"
import "core:math"
import linalg "core:math/linalg"
import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 2

MAX_LIGHTS :: 10
SHADOW_MAP_SIZE :: 512
MAX_SHADOW_MAPS :: MAX_LIGHTS
MAX_SCENE_UNIFORMS :: 16

Mat4 :: linalg.Matrix4f32
Vec4 :: linalg.Vector4f32

SingleLightUniform :: struct {
  view_proj:  Mat4,
  color:      Vec4,
  position:   Vec4,
  direction:  Vec4,
  kind:       enum u32 {
    POINT       = 0,
    DIRECTIONAL = 1,
    SPOT        = 2,
  },
  angle:      f32, // For spotlight: cone angle
  radius:     f32, // For point/spot: attenuation radius
  has_shadow: b32,
}

SceneUniform :: struct {
  view:       Mat4,
  projection: Mat4,
  time:       f32,
}

SceneLightUniform :: struct {
  lights:      [MAX_LIGHTS]SingleLightUniform,
  light_count: u32,
}

push_light :: proc(self: ^SceneLightUniform, light: SingleLightUniform) {
  if self.light_count < MAX_LIGHTS {
    self.lights[self.light_count] = light
    self.light_count += 1
  }
}

clear_lights :: proc(self: ^SceneLightUniform) {
  self.light_count = 0
}

Frame :: struct {
  ctx:                            ^VulkanContext,
  image_available_semaphore:      vk.Semaphore,
  render_finished_semaphore:      vk.Semaphore,
  fence:                          vk.Fence,
  command_buffer:                 vk.CommandBuffer,
  camera_uniform:                 DataBuffer,
  light_uniform:                  DataBuffer,
  shadow_maps:                    [MAX_SHADOW_MAPS]DepthTexture,
  cube_shadow_maps:               [MAX_SHADOW_MAPS]CubeDepthTexture,
  camera_descriptor_set:          vk.DescriptorSet,
  shadow_map_descriptor_set:      vk.DescriptorSet,
  cube_shadow_map_descriptor_set: vk.DescriptorSet,
}

frame_init :: proc(self: ^Frame, ctx: ^VulkanContext) -> (res: vk.Result) {
  self.ctx = ctx
  min_alignment :=
    ctx.physical_device_properties.limits.minUniformBufferOffsetAlignment
  aligned_scene_uniform_size := align_up(size_of(SceneUniform), min_alignment)
  self.camera_uniform = create_host_visible_buffer(
    ctx,
    (1 + 6 * MAX_SCENE_UNIFORMS) * aligned_scene_uniform_size,
    {.UNIFORM_BUFFER},
  ) or_return
  self.light_uniform = create_host_visible_buffer(
    ctx,
    size_of(SceneLightUniform),
    {.UNIFORM_BUFFER},
  ) or_return

  for i in 0 ..< MAX_SHADOW_MAPS {
    depth_texture_init(
      &self.shadow_maps[i],
      ctx,
      SHADOW_MAP_SIZE,
      SHADOW_MAP_SIZE,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
    cube_depth_texture_init(
      &self.cube_shadow_maps[i],
      ctx,
      SHADOW_MAP_SIZE,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
  }

  alloc_info_main := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = ctx.descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &camera_descriptor_set_layout,
  }
  vk.AllocateDescriptorSets(
    ctx.vkd,
    &alloc_info_main,
    &self.camera_descriptor_set,
  ) or_return

  scene_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.camera_uniform.buffer,
    offset = 0,
    range  = vk.DeviceSize(size_of(SceneUniform)),
  }
  light_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.light_uniform.buffer,
    offset = 0,
    range  = vk.DeviceSize(size_of(SceneLightUniform)),
  }
  shadow_map_image_infos: [MAX_SHADOW_MAPS]vk.DescriptorImageInfo
  for i in 0 ..< MAX_SHADOW_MAPS {
    shadow_map_image_infos[i] = vk.DescriptorImageInfo {
      sampler     = self.shadow_maps[i].sampler,
      imageView   = self.shadow_maps[i].buffer.view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }
  }
  cube_shadow_map_image_infos: [MAX_SHADOW_MAPS]vk.DescriptorImageInfo
  for i in 0 ..< MAX_SHADOW_MAPS {
    cube_shadow_map_image_infos[i] = vk.DescriptorImageInfo {
      sampler     = self.cube_shadow_maps[i].sampler,
      imageView   = self.cube_shadow_maps[i].view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }
  }
  writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.camera_descriptor_set,
      dstBinding = 0,
      descriptorType = .UNIFORM_BUFFER_DYNAMIC,
      descriptorCount = 1,
      pBufferInfo = &scene_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.camera_descriptor_set,
      dstBinding = 1,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &light_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.camera_descriptor_set,
      dstBinding = 2,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = MAX_SHADOW_MAPS,
      pImageInfo = raw_data(shadow_map_image_infos[:]),
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.camera_descriptor_set,
      dstBinding = 3,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = MAX_SHADOW_MAPS,
      pImageInfo = raw_data(cube_shadow_map_image_infos[:]),
    },
  }
  vk.UpdateDescriptorSets(ctx.vkd, len(writes), raw_data(writes[:]), 0, nil)

  return .SUCCESS
}

frame_deinit :: proc(self: ^Frame) {
  if self.ctx == nil {return}

  vkd := self.ctx.vkd
  command_pool := self.ctx.command_pool

  vk.DestroySemaphore(vkd, self.image_available_semaphore, nil)
  vk.DestroySemaphore(vkd, self.render_finished_semaphore, nil)
  vk.DestroyFence(vkd, self.fence, nil)
  vk.FreeCommandBuffers(vkd, command_pool, 1, &self.command_buffer)

  data_buffer_deinit(&self.camera_uniform, self.ctx)
  data_buffer_deinit(&self.light_uniform, self.ctx)
  for i in 0 ..< MAX_SHADOW_MAPS {
    depth_texture_deinit(&self.shadow_maps[i])
    cube_depth_texture_deinit(&self.cube_shadow_maps[i])
  }
  self.ctx = nil
}

Renderer :: struct {
  ctx:                        ^VulkanContext,
  swapchain:                  vk.SwapchainKHR,
  format:                     vk.SurfaceFormatKHR,
  extent:                     vk.Extent2D,
  images:                     []vk.Image, // Owned by swapchain, slice managed by renderer
  views:                      []vk.ImageView, // Owned by renderer, one per image
  frames:                     [MAX_FRAMES_IN_FLIGHT]Frame,
  depth_buffer:               ImageBuffer,
  environment_map:            ^Texture,
  environment_map_handle:     Handle,
  environment_descriptor_set: vk.DescriptorSet,
  current_frame_index:        u32,
}

renderer_init :: proc(self: ^Renderer, ctx: ^VulkanContext) -> vk.Result {
  self.ctx = ctx
  self.current_frame_index = 0
  for &frame in self.frames {
    frame_init(&frame, ctx) or_return
  }
  return .SUCCESS
}

renderer_deinit :: proc(self: ^Renderer) {
  if self.ctx == nil {return}
  vkd := self.ctx.vkd
  vk.DeviceWaitIdle(vkd)
  renderer_destroy_swapchain_resources(self)
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    frame_deinit(&self.frames[i])
  }
  vk.DestroyDescriptorSetLayout(vkd, camera_descriptor_set_layout, nil)
  self.ctx = nil
}

renderer_build_command_buffers :: proc(self: ^Renderer) -> vk.Result {
  alloc_info := vk.CommandBufferAllocateInfo {
    sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool        = self.ctx.command_pool,
    level              = .PRIMARY,
    commandBufferCount = 1,
  }
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    vk.AllocateCommandBuffers(
      self.ctx.vkd,
      &alloc_info,
      &self.frames[i].command_buffer,
    ) or_return
  }
  return .SUCCESS
}

renderer_build_synchronizers :: proc(self: ^Renderer) -> vk.Result {
  semaphore_info := vk.SemaphoreCreateInfo {
    sType = .SEMAPHORE_CREATE_INFO,
  }
  fence_info := vk.FenceCreateInfo {
    sType = .FENCE_CREATE_INFO,
    flags = {.SIGNALED},
  }

  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    frame := &self.frames[i]
    vk.CreateSemaphore(
      self.ctx.vkd,
      &semaphore_info,
      nil,
      &frame.image_available_semaphore,
    ) or_return
    vk.CreateSemaphore(
      self.ctx.vkd,
      &semaphore_info,
      nil,
      &frame.render_finished_semaphore,
    ) or_return
    vk.CreateFence(self.ctx.vkd, &fence_info, nil, &frame.fence) or_return
  }
  return .SUCCESS
}

renderer_pick_swap_present_mode :: proc(
  present_modes: []vk.PresentModeKHR,
) -> vk.PresentModeKHR {
  for mode in present_modes {
    if mode == .MAILBOX {
      return .MAILBOX
    }
  }
  return .FIFO
}

renderer_build_swapchain_surface_format :: proc(
  self: ^Renderer,
  formats: []vk.SurfaceFormatKHR,
) {
  for fmt in formats {
    if fmt.format == .B8G8R8A8_SRGB {
      self.format = fmt
      return
    }
  }
  // Fallback to the first available format if preferred not found
  if len(formats) > 0 {
    self.format = formats[0]
  } else {
    // This should not happen if the physical device supports the surface
    fmt.printfln("No surface formats available for swapchain.")
    // Set a default, though this state is problematic
    self.format = vk.SurfaceFormatKHR {
      format     = .B8G8R8A8_SRGB,
      colorSpace = .SRGB_NONLINEAR,
    }
  }
}

renderer_build_swapchain_extent :: proc(
  self: ^Renderer,
  capabilities: vk.SurfaceCapabilitiesKHR,
  actual_width, actual_height: u32,
) {
  if capabilities.currentExtent.width != math.max(u32) {
    self.extent = capabilities.currentExtent
  } else {
    self.extent.width = math.clamp(
      actual_width,
      capabilities.minImageExtent.width,
      capabilities.maxImageExtent.width,
    )
    self.extent.height = math.clamp(
      actual_height,
      capabilities.minImageExtent.height,
      capabilities.maxImageExtent.height,
    )
  }
}


renderer_recreate_swapchain :: proc(
  self: ^Renderer,
  width: u32,
  height: u32,
) -> vk.Result {
  vk.DeviceWaitIdle(self.ctx.vkd)
  renderer_destroy_swapchain_resources(self) // Destroy old swapchain and related resources
  // Re-query surface capabilities as they might have changed (e.g. window resize)
  capabilities: vk.SurfaceCapabilitiesKHR
  vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
    self.ctx.physical_device,
    self.ctx.surface,
    &capabilities,
  ) or_return
  // Re-query surface formats (usually don't change, but good practice)
  format_count: u32
  vk.GetPhysicalDeviceSurfaceFormatsKHR(
    self.ctx.physical_device,
    self.ctx.surface,
    &format_count,
    nil,
  )
  available_formats := make([]vk.SurfaceFormatKHR, format_count)
  defer delete(available_formats)
  vk.GetPhysicalDeviceSurfaceFormatsKHR(
    self.ctx.physical_device,
    self.ctx.surface,
    &format_count,
    raw_data(available_formats),
  )
  // Re-query present modes
  present_mode_count: u32
  vk.GetPhysicalDeviceSurfacePresentModesKHR(
    self.ctx.physical_device,
    self.ctx.surface,
    &present_mode_count,
    nil,
  )
  available_present_modes := make([]vk.PresentModeKHR, present_mode_count)
  defer delete(available_present_modes)
  vk.GetPhysicalDeviceSurfacePresentModesKHR(
    self.ctx.physical_device,
    self.ctx.surface,
    &present_mode_count,
    raw_data(available_present_modes),
  )

  return renderer_create_swapchain_and_resources(
    self,
    capabilities,
    available_formats,
    available_present_modes,
    width,
    height,
  )
}

renderer_create_swapchain_and_resources :: proc(
  self: ^Renderer,
  capabilities: vk.SurfaceCapabilitiesKHR,
  formats: []vk.SurfaceFormatKHR,
  present_modes: []vk.PresentModeKHR,
  window_width: u32,
  window_height: u32,
) -> vk.Result {
  ctx := self.ctx
  renderer_build_swapchain_surface_format(self, formats)
  renderer_build_swapchain_extent(
    self,
    capabilities,
    window_width,
    window_height,
  )

  image_count := capabilities.minImageCount + 1
  if capabilities.maxImageCount > 0 &&
     image_count > capabilities.maxImageCount {
    image_count = capabilities.maxImageCount
  }

  create_info := vk.SwapchainCreateInfoKHR {
    sType            = .SWAPCHAIN_CREATE_INFO_KHR,
    surface          = ctx.surface,
    minImageCount    = image_count,
    imageFormat      = self.format.format,
    imageColorSpace  = self.format.colorSpace,
    imageExtent      = self.extent,
    imageArrayLayers = 1,
    imageUsage       = {.COLOR_ATTACHMENT},
    preTransform     = capabilities.currentTransform,
    compositeAlpha   = {.OPAQUE},
    presentMode      = renderer_pick_swap_present_mode(present_modes),
    clipped          = true,
  }

  queue_family_indices := [2]u32{ctx.graphics_family, ctx.present_family}
  if ctx.graphics_family != ctx.present_family {
    create_info.imageSharingMode = .CONCURRENT
    create_info.queueFamilyIndexCount = 2
    create_info.pQueueFamilyIndices = raw_data(queue_family_indices[:])
  } else {
    create_info.imageSharingMode = .EXCLUSIVE
  }

  vk.CreateSwapchainKHR(ctx.vkd, &create_info, nil, &self.swapchain) or_return
  swapchain_image_count: u32
  vk.GetSwapchainImagesKHR(
    ctx.vkd,
    self.swapchain,
    &swapchain_image_count,
    nil,
  )
  self.images = make([]vk.Image, swapchain_image_count)
  vk.GetSwapchainImagesKHR(
    ctx.vkd,
    self.swapchain,
    &swapchain_image_count,
    raw_data(self.images),
  )
  self.views = make([]vk.ImageView, swapchain_image_count)
  for i in 0 ..< swapchain_image_count {
    self.views[i] = create_image_view(
      ctx.vkd,
      self.images[i],
      self.format.format,
      {.COLOR},
    ) or_return
  }
  depth_format := vk.Format.D32_SFLOAT
  self.depth_buffer = malloc_image_buffer(
    ctx,
    self.extent.width,
    self.extent.height,
    depth_format,
    .OPTIMAL,
    {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    {.DEVICE_LOCAL},
  ) or_return

  self.depth_buffer.view = create_image_view(
    ctx.vkd,
    self.depth_buffer.image,
    self.depth_buffer.format,
    {.DEPTH},
  ) or_return

  return .SUCCESS
}

renderer_destroy_swapchain_resources :: proc(self: ^Renderer) {
  if self.ctx == nil {return}
  vkd := self.ctx.vkd
  image_buffer_deinit(vkd, &self.depth_buffer)
  if self.views != nil {
    for view in self.views {
      if view != 0 {
        vk.DestroyImageView(vkd, view, nil)
      }
    }
    delete(self.views)
    self.views = nil
  }

  if self.images != nil {
    delete(self.images)
    self.images = nil
  }
  if self.swapchain != 0 {
    vk.DestroySwapchainKHR(vkd, self.swapchain, nil)
    self.swapchain = 0
  }
}

renderer_get_in_flight_fence :: proc(self: ^Renderer) -> vk.Fence {
  return self.frames[self.current_frame_index].fence
}
renderer_get_image_available_semaphore :: proc(
  self: ^Renderer,
) -> vk.Semaphore {
  return self.frames[self.current_frame_index].image_available_semaphore
}
renderer_get_render_finished_semaphore :: proc(
  self: ^Renderer,
) -> vk.Semaphore {
  return self.frames[self.current_frame_index].render_finished_semaphore
}
renderer_get_command_buffer :: proc(self: ^Renderer) -> vk.CommandBuffer {
  if self == nil {
    fmt.eprintln("Error: Renderer is nil in get_command_buffer_renderer")
    return vk.CommandBuffer{}
  }

  if self.current_frame_index >= len(self.frames) {
    fmt.eprintln(
      "Error: Invalid frame index",
      self.current_frame_index,
      "vs",
      len(self.frames),
    )
    return vk.CommandBuffer{}
  }

  cmd_buffer := self.frames[self.current_frame_index].command_buffer
  if cmd_buffer == nil {
    fmt.eprintln(
      "Error: Command buffer is nil for frame",
      self.current_frame_index,
    )
    return vk.CommandBuffer{}
  }

  return cmd_buffer
}

renderer_get_camera_uniform :: proc(self: ^Renderer) -> ^DataBuffer {
  return &self.frames[self.current_frame_index].camera_uniform
}
renderer_get_light_uniform :: proc(self: ^Renderer) -> ^DataBuffer {
  return &self.frames[self.current_frame_index].light_uniform
}
renderer_get_shadow_map :: proc(
  self: ^Renderer,
  light_idx: int,
) -> ^DepthTexture {
  return &self.frames[self.current_frame_index].shadow_maps[light_idx]
}
renderer_get_cube_shadow_map :: proc(
  self: ^Renderer,
  light_idx: int,
) -> ^CubeDepthTexture {
  return &self.frames[self.current_frame_index].cube_shadow_maps[light_idx]
}
renderer_get_camera_descriptor_set :: proc(
  self: ^Renderer,
) -> vk.DescriptorSet {
  return self.frames[self.current_frame_index].camera_descriptor_set
}
renderer_get_shadow_map_descriptor_set :: proc(
  self: ^Renderer,
) -> vk.DescriptorSet {
  return self.frames[self.current_frame_index].shadow_map_descriptor_set
}
renderer_get_cube_shadow_map_descriptor_set :: proc(
  self: ^Renderer,
) -> vk.DescriptorSet {
  return self.frames[self.current_frame_index].cube_shadow_map_descriptor_set
}

renderer_build_swapchain :: proc(
  self: ^Renderer,
  capabilities: vk.SurfaceCapabilitiesKHR,
  formats: []vk.SurfaceFormatKHR,
  present_modes: []vk.PresentModeKHR,
  graphics_family: u32,
  present_family: u32,
  actual_width: u32,
  actual_height: u32,
) -> vk.Result {
  chosen_format := formats[0]
  for fmt in formats {
    if fmt.format == .B8G8R8A8_SRGB && fmt.colorSpace == .SRGB_NONLINEAR {
      chosen_format = fmt
      break
    }
  }
  self.format = chosen_format
  chosen_present_mode: vk.PresentModeKHR = .FIFO
  for mode in present_modes {
    if mode == .MAILBOX {
      chosen_present_mode = .MAILBOX
      break
    }
  }
  renderer_build_swapchain_extent(
    self,
    capabilities,
    actual_width,
    actual_height,
  )
  image_count := capabilities.minImageCount + 1
  if capabilities.maxImageCount > 0 &&
     image_count > capabilities.maxImageCount {
    image_count = capabilities.maxImageCount
  }
  create_info := vk.SwapchainCreateInfoKHR {
    sType            = .SWAPCHAIN_CREATE_INFO_KHR,
    surface          = self.ctx.surface,
    minImageCount    = image_count,
    imageFormat      = self.format.format,
    imageColorSpace  = self.format.colorSpace,
    imageExtent      = self.extent,
    imageArrayLayers = 1,
    imageUsage       = {.COLOR_ATTACHMENT},
    preTransform     = capabilities.currentTransform,
    compositeAlpha   = {.OPAQUE},
    presentMode      = chosen_present_mode,
    clipped          = true,
    oldSwapchain     = 0,
  }
  queue_family_indices := [?]u32{graphics_family, present_family}
  if graphics_family != present_family {
    create_info.imageSharingMode = .CONCURRENT
    create_info.queueFamilyIndexCount = len(queue_family_indices)
    create_info.pQueueFamilyIndices = raw_data(queue_family_indices[:])
  } else {
    create_info.imageSharingMode = .EXCLUSIVE
  }
  vk.CreateSwapchainKHR(
    self.ctx.vkd,
    &create_info,
    nil,
    &self.swapchain,
  ) or_return
  swapchain_image_count: u32
  vk.GetSwapchainImagesKHR(
    self.ctx.vkd,
    self.swapchain,
    &swapchain_image_count,
    nil,
  )
  self.images = make([]vk.Image, swapchain_image_count)
  vk.GetSwapchainImagesKHR(
    self.ctx.vkd,
    self.swapchain,
    &swapchain_image_count,
    raw_data(self.images),
  )
  self.views = make([]vk.ImageView, swapchain_image_count)
  for i in 0 ..< swapchain_image_count {
    self.views[i], _ = create_image_view(
      self.ctx.vkd,
      self.images[i],
      self.format.format,
      {.COLOR},
    )
  }
  fmt.printfln("Swapchain created with format:", self.format.format)
  return .SUCCESS
}
