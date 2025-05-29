package mjolnir

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"

when ODIN_OS == .Darwin {
  // NOTE: just a bogus import of the system library,
  // needed so we can add a linker flag to point to /usr/local/lib (where vulkan is installed by default)
  // when trying to load vulkan.
  // Credit goes to : https://gist.github.com/laytan/ba57af3e5a59ab5cb2fca9e25bcfe262
  @(require, extra_linker_flags = "-rpath /usr/local/lib")
  foreign import __ "system:System.framework"
}

ENGINE_NAME :: "Mjolnir"
TITLE :: "Mjolnir"

DEVICE_EXTENSIONS :: []cstring {
  vk.KHR_SWAPCHAIN_EXTENSION_NAME,
  vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
}

ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, ODIN_DEBUG) // Default to true in debug builds

when ENABLE_VALIDATION_LAYERS {
  VALIDATION_LAYERS :: []cstring{"VK_LAYER_KHRONOS_validation"}
} else {
  VALIDATION_LAYERS :: []cstring{}
}

ACTIVE_MATERIAL_COUNT :: 1000
MAX_SAMPLER_PER_MATERIAL :: 3
MAX_SAMPLER_COUNT :: ACTIVE_MATERIAL_COUNT * MAX_SAMPLER_PER_MATERIAL
SCENE_UNIFORM_COUNT :: 3

SwapchainSupport :: struct {
  capabilities:  vk.SurfaceCapabilitiesKHR,
  formats:       []vk.SurfaceFormatKHR, // Owned by this struct if allocated by it
  present_modes: []vk.PresentModeKHR, // Owned by this struct if allocated by it
}

swapchain_support_deinit :: proc(self: ^SwapchainSupport) {
  delete(self.formats)
  delete(self.present_modes)
  self.formats = nil
  self.present_modes = nil
}

FoundQueueFamilyIndices :: struct {
  graphics_family: u32,
  present_family:  u32,
}

VulkanContext :: struct {
  window:                     glfw.WindowHandle,
  vki:                        vk.Instance,
  vkd:                        vk.Device,
  surface:                    vk.SurfaceKHR,
  surface_capabilities:       vk.SurfaceCapabilitiesKHR,
  surface_formats:            []vk.SurfaceFormatKHR, // Owned by VulkanContext
  present_modes:              []vk.PresentModeKHR, // Owned by VulkanContext
  debug_messenger:            vk.DebugUtilsMessengerEXT,
  physical_device:            vk.PhysicalDevice,
  graphics_family:            u32,
  graphics_queue:             vk.Queue,
  present_family:             u32,
  present_queue:              vk.Queue,
  descriptor_pool:            vk.DescriptorPool,
  command_pool:               vk.CommandPool,
  physical_device_properties: vk.PhysicalDeviceProperties, // Added for device limits
}

vulkan_context_init :: proc(
  self: ^VulkanContext,
  window: glfw.WindowHandle,
) -> vk.Result {
  self.window = window
  vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
  vulkan_instance_init(self) or_return
  surface_init(self) or_return
  physical_device_init(self) or_return
  logical_device_init(self) or_return
  command_pool_init(self) or_return
  descriptor_pool_init(self) or_return
  return .SUCCESS
}

vulkan_context_deinit :: proc(self: ^VulkanContext) {
  vk.DeviceWaitIdle(self.vkd)
  vk.DestroyDescriptorPool(self.vkd, self.descriptor_pool, nil)
  vk.DestroyCommandPool(self.vkd, self.command_pool, nil)
  vk.DestroyDevice(self.vkd, nil)
  vk.DestroySurfaceKHR(self.vki, self.surface, nil)
  when ENABLE_VALIDATION_LAYERS {
    if self.debug_messenger != 0 {
      vk.DestroyDebugUtilsMessengerEXT(self.vki, self.debug_messenger, nil)
    }
  }
  vk.DestroyInstance(self.vki, nil)
  delete(self.surface_formats)
  delete(self.present_modes)
  self.surface_formats = nil
  self.present_modes = nil
}

debug_callback :: proc "system" (
  message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
  message_type: vk.DebugUtilsMessageTypeFlagsEXT,
  p_callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
  p_user_data: rawptr,
) -> b32 {
  context = runtime.default_context()
  message := string(p_callback_data.pMessage)
  switch {
  case .ERROR in message_severity:
    fmt.printfln("Validation: %s", message)
  case .WARNING in message_severity:
    fmt.printfln("Validation: %s", message)
  case .INFO in message_severity:
    fmt.printfln("Validation: %s", message)
  case .VERBOSE in message_severity:
    log.debugf("Validation: %s", message)
  case:
    fmt.printfln("Validation (unknown severity): %s", message)
  }
  return false
}

vulkan_instance_init :: proc(self: ^VulkanContext) -> vk.Result {
  glfw_exts_cstrings := glfw.GetRequiredInstanceExtensions()
  extensions := make([dynamic]cstring, 0, len(glfw_exts_cstrings) + 2)
  defer delete(extensions)

  for ext in glfw_exts_cstrings {
    append(&extensions, ext)
  }

  app_info := vk.ApplicationInfo {
    sType              = .APPLICATION_INFO,
    pApplicationName   = TITLE,
    applicationVersion = vk.MAKE_VERSION(1, 0, 0),
    pEngineName        = ENGINE_NAME,
    engineVersion      = vk.MAKE_VERSION(1, 0, 0),
    apiVersion         = vk.API_VERSION_1_2,
  }

  create_info := vk.InstanceCreateInfo {
    sType            = .INSTANCE_CREATE_INFO,
    pApplicationInfo = &app_info,
  }

  when ODIN_OS == .Darwin {
    create_info.flags |= {.ENUMERATE_PORTABILITY_KHR}
    append(&extensions, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
  }

  dbg_create_info: vk.DebugUtilsMessengerCreateInfoEXT
  when ENABLE_VALIDATION_LAYERS {
    create_info.enabledLayerCount = u32(len(VALIDATION_LAYERS))
    create_info.ppEnabledLayerNames = raw_data(VALIDATION_LAYERS)

    append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

    dbg_create_info = vk.DebugUtilsMessengerCreateInfoEXT {
      sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
      messageSeverity = {
        .WARNING,
        .ERROR,
        .INFO, /*, .VERBOSE */
      },
      messageType     = {
        .GENERAL,
        .VALIDATION,
        .PERFORMANCE,
        .DEVICE_ADDRESS_BINDING,
      },
      pfnUserCallback = debug_callback,
    }
    create_info.pNext = &dbg_create_info
  }

  create_info.enabledExtensionCount = u32(len(extensions))
  create_info.ppEnabledExtensionNames = raw_data(extensions)

  vk.CreateInstance(&create_info, nil, &self.vki) or_return
  vk.load_proc_addresses_instance(self.vki)

  when ENABLE_VALIDATION_LAYERS {
    vk.CreateDebugUtilsMessengerEXT(
      self.vki,
      &dbg_create_info,
      nil,
      &self.debug_messenger,
    ) or_return
  }
  fmt.printfln("Vulkan instance created: %s", app_info.pApplicationName)
  return .SUCCESS
}

surface_init :: proc(self: ^VulkanContext) -> vk.Result {
  glfw.CreateWindowSurface(self.vki, self.window, nil, &self.surface) or_return
  fmt.printfln("Vulkan surface created")
  return .SUCCESS
}

query_physical_device_swapchain_support :: proc(
  pdevice: vk.PhysicalDevice,
  surface: vk.SurfaceKHR,
) -> (
  support: SwapchainSupport,
  res: vk.Result,
) {
  vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
    pdevice,
    surface,
    &support.capabilities,
  ) or_return

  count: u32
  vk.GetPhysicalDeviceSurfaceFormatsKHR(
    pdevice,
    surface,
    &count,
    nil,
  ) or_return
  if count > 0 {
    support.formats = make([]vk.SurfaceFormatKHR, count)
    vk.GetPhysicalDeviceSurfaceFormatsKHR(
      pdevice,
      surface,
      &count,
      raw_data(support.formats),
    ) or_return
  }

  vk.GetPhysicalDeviceSurfacePresentModesKHR(
    pdevice,
    surface,
    &count,
    nil,
  ) or_return
  if count > 0 {
    support.present_modes = make([]vk.PresentModeKHR, count)
    vk.GetPhysicalDeviceSurfacePresentModesKHR(
      pdevice,
      surface,
      &count,
      raw_data(support.present_modes),
    ) or_return
  }
  return support, .SUCCESS
}

score_physical_device :: proc(
  self: ^VulkanContext,
  device: vk.PhysicalDevice,
) -> (
  score: u32,
  res: vk.Result,
) {
  props: vk.PhysicalDeviceProperties
  features: vk.PhysicalDeviceFeatures
  vk.GetPhysicalDeviceProperties(device, &props)
  vk.GetPhysicalDeviceFeatures(device, &features)

  device_name_cstring := cstring(&props.deviceName[0])
  fmt.printfln("Scoring device %s", device_name_cstring)

  when ODIN_OS != .Darwin {
    if !features.geometryShader {
      fmt.printfln("Device %s: no geometry shader.", device_name_cstring)
      return 0, .SUCCESS
    }
  }

  ext_count: u32
  vk.EnumerateDeviceExtensionProperties(device, nil, &ext_count, nil) or_return
  available_extensions := make([]vk.ExtensionProperties, ext_count)
  defer delete(available_extensions)
  vk.EnumerateDeviceExtensionProperties(
    device,
    nil,
    &ext_count,
    raw_data(available_extensions),
  ) or_return

  fmt.printfln(
    "vulkan: device supports %v extensions",
    len(available_extensions),
  )
  required_loop: for required in DEVICE_EXTENSIONS {
    fmt.printfln("vulkan: checking for required extension %q", required)
    for &extension in available_extensions {
      extension_name := strings.truncate_to_byte(
        string(extension.extensionName[:]),
        0,
      )
      if extension_name == string(required) {
        continue required_loop
      }
    }
    fmt.printfln(
      "vulkan: device does not support required extension",
      required,
    )
    return 0, .NOT_READY
  }
  fmt.printfln("vulkan: device supports all required extensions")

  support, s_res := query_physical_device_swapchain_support(
    device,
    self.surface,
  )
  if s_res != .SUCCESS {return 0, s_res}
  defer swapchain_support_deinit(&support)

  if len(support.formats) == 0 || len(support.present_modes) == 0 {
    fmt.printfln(
      "Device %s: inadequate swapchain support.",
      device_name_cstring,
    )
    return 0, .SUCCESS
  }

  _, qf_res := find_queue_families(device, self.surface)
  if qf_res != .SUCCESS {
    fmt.printfln("Device %s: no suitable queue families.", device_name_cstring)
    return 0, .SUCCESS
  }

  current_score: u32 = 0
  switch props.deviceType {
  case .DISCRETE_GPU:
    current_score += 400_000
  case .INTEGRATED_GPU:
    current_score += 300_000
  case .VIRTUAL_GPU:
    current_score += 200_000
  case .CPU, .OTHER:
    current_score += 100_000
  }
  current_score += props.limits.maxImageDimension2D

  fmt.printfln("Device %s scored %d", device_name_cstring, current_score)
  return current_score, .SUCCESS
}

physical_device_init :: proc(self: ^VulkanContext) -> vk.Result {
  count: u32
  vk.EnumeratePhysicalDevices(self.vki, &count, nil) or_return
  if count == 0 {
    fmt.printfln("Error: No physical devices found!")
    return .ERROR_INITIALIZATION_FAILED
  }
  fmt.printfln("Found %d physical device(s)", count)

  devices_slice := make([]vk.PhysicalDevice, count)
  defer delete(devices_slice)
  vk.EnumeratePhysicalDevices(
    self.vki,
    &count,
    raw_data(devices_slice),
  ) or_return

  best_score: u32 = 0
  for device_handle in devices_slice {
    score_val := score_physical_device(self, device_handle) or_return
    fmt.printfln(" - Device Score: %d", score_val)

    if score_val > best_score {
      self.physical_device = device_handle
      best_score = score_val
    }
  }

  if self.physical_device == nil {
    fmt.printfln("Error: No suitable physical device found!")
    return .ERROR_INITIALIZATION_FAILED
  }

  vk.GetPhysicalDeviceProperties(
    self.physical_device,
    &self.physical_device_properties,
  )
  fmt.printfln(
    "\nSelected physical device: %s (score %d)",
    cstring(&self.physical_device_properties.deviceName[0]),
    best_score,
  )
  return .SUCCESS
}

find_queue_families :: proc(
  physical_device: vk.PhysicalDevice,
  surface: vk.SurfaceKHR,
) -> (
  indices: FoundQueueFamilyIndices,
  res: vk.Result,
) {
  count: u32
  vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &count, nil)
  queue_families_slice := make([]vk.QueueFamilyProperties, count)
  defer delete(queue_families_slice)
  vk.GetPhysicalDeviceQueueFamilyProperties(
    physical_device,
    &count,
    raw_data(queue_families_slice),
  )

  maybe_graphics_family: Maybe(u32)
  maybe_present_family: Maybe(u32)

  for family, i in queue_families_slice {
    idx := u32(i)
    if .GRAPHICS in family.queueFlags {
      maybe_graphics_family = idx
    }
    present_support: b32
    vk.GetPhysicalDeviceSurfaceSupportKHR(
      physical_device,
      idx,
      surface,
      &present_support,
    ) or_return
    if present_support {
      maybe_present_family = idx
    }
    if maybe_graphics_family != nil && maybe_present_family != nil {
      break
    }
  }

  if g_fam, ok_g := maybe_graphics_family.?; ok_g {
    if p_fam, ok_p := maybe_present_family.?; ok_p {
      return FoundQueueFamilyIndices{g_fam, p_fam}, .SUCCESS
    }
  }
  res = .ERROR_FEATURE_NOT_PRESENT
  return
}

logical_device_init :: proc(self: ^VulkanContext) -> vk.Result {
  indices := find_queue_families(self.physical_device, self.surface) or_return
  self.graphics_family = indices.graphics_family
  self.present_family = indices.present_family
  support_details := query_physical_device_swapchain_support(
    self.physical_device,
    self.surface,
  ) or_return
  self.surface_capabilities = support_details.capabilities
  self.surface_formats = support_details.formats
  self.present_modes = support_details.present_modes
  support_details.formats = nil
  support_details.present_modes = nil
  swapchain_support_deinit(&support_details)


  queue_create_infos_list := make([dynamic]vk.DeviceQueueCreateInfo, 0, 2)
  defer delete(queue_create_infos_list)
  unique_queue_families := make(map[u32]struct {
    }, 2)
  defer delete(unique_queue_families)

  unique_queue_families[self.graphics_family] = {}
  unique_queue_families[self.present_family] = {}
  queue_priority: f32 = 1.0
  for family_index in unique_queue_families {
    append(
      &queue_create_infos_list,
      vk.DeviceQueueCreateInfo {
        sType = .DEVICE_QUEUE_CREATE_INFO,
        queueFamilyIndex = family_index,
        queueCount = 1,
        pQueuePriorities = &queue_priority,
      },
    )
  }

  dynamic_rendering_feature := vk.PhysicalDeviceDynamicRenderingFeaturesKHR {
    sType            = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR,
    dynamicRendering = true,
  }

  device_create_info := vk.DeviceCreateInfo {
    sType                   = .DEVICE_CREATE_INFO,
    queueCreateInfoCount    = u32(len(queue_create_infos_list)),
    pQueueCreateInfos       = raw_data(queue_create_infos_list),
    ppEnabledExtensionNames = raw_data(DEVICE_EXTENSIONS),
    enabledExtensionCount   = u32(len(DEVICE_EXTENSIONS)),
    pNext                   = &dynamic_rendering_feature,
    // pEnabledFeatures = &vk.PhysicalDeviceFeatures{}, // Set if specific base features needed
  }

  when ENABLE_VALIDATION_LAYERS {
    device_create_info.enabledLayerCount = u32(len(VALIDATION_LAYERS))
    device_create_info.ppEnabledLayerNames = raw_data(VALIDATION_LAYERS)
  }

  vk.CreateDevice(
    self.physical_device,
    &device_create_info,
    nil,
    &self.vkd,
  ) or_return
  vk.GetDeviceQueue(self.vkd, self.graphics_family, 0, &self.graphics_queue)
  vk.GetDeviceQueue(self.vkd, self.present_family, 0, &self.present_queue)
  return .SUCCESS
}

descriptor_pool_init :: proc(self: ^VulkanContext) -> vk.Result {
  // expand those limits as needed
  pool_sizes := [4]vk.DescriptorPoolSize {
    {.COMBINED_IMAGE_SAMPLER, MAX_SAMPLER_COUNT},
    {.UNIFORM_BUFFER, 128},
    {.UNIFORM_BUFFER_DYNAMIC, 128},
    {.STORAGE_BUFFER, ACTIVE_MATERIAL_COUNT},
  }
  fmt.printfln("Descriptor pool allocation sizes:")
  fmt.printfln(" - Combined Image Samplers: %d", MAX_SAMPLER_COUNT)
  fmt.printfln(
    " - Uniform Buffers: %d",
    MAX_FRAMES_IN_FLIGHT * SCENE_UNIFORM_COUNT,
  )
  fmt.printfln(" - Storage Buffers: %d", ACTIVE_MATERIAL_COUNT)

  pool_info := vk.DescriptorPoolCreateInfo {
    sType         = .DESCRIPTOR_POOL_CREATE_INFO,
    poolSizeCount = len(pool_sizes),
    pPoolSizes    = raw_data(pool_sizes[:]),
    maxSets       = MAX_FRAMES_IN_FLIGHT + ACTIVE_MATERIAL_COUNT,
    // flags = {.FREE_DESCRIPTOR_SET} // If needed
  }
  fmt.printfln("Creating descriptor pool with maxSets: %d", pool_info.maxSets)

  result := vk.CreateDescriptorPool(
    self.vkd,
    &pool_info,
    nil,
    &self.descriptor_pool,
  )
  if result != .SUCCESS {
    fmt.printfln("Failed to create descriptor pool with error: %v", result)
    return result
  }
  fmt.printfln("Vulkan descriptor pool created successfully")
  return .SUCCESS
}

command_pool_init :: proc(self: ^VulkanContext) -> vk.Result {
  pool_info := vk.CommandPoolCreateInfo {
    sType            = .COMMAND_POOL_CREATE_INFO,
    flags            = {.RESET_COMMAND_BUFFER},
    queueFamilyIndex = self.graphics_family,
  }
  vk.CreateCommandPool(self.vkd, &pool_info, nil, &self.command_pool) or_return
  fmt.printfln("Vulkan command pool created")
  return .SUCCESS
}

create_shader_module :: proc(
  self: ^VulkanContext,
  code: []u8,
) -> (
  module: vk.ShaderModule,
  res: vk.Result,
) {
  if len(code) % 4 != 0 {
    res = .ERROR_INVALID_SHADER_NV
    return
  }
  create_info := vk.ShaderModuleCreateInfo {
    sType    = .SHADER_MODULE_CREATE_INFO,
    codeSize = len(code),
    pCode    = raw_data(slice.reinterpret([]u32, code)),
  }
  vk.CreateShaderModule(self.vkd, &create_info, nil, &module) or_return
  res = .SUCCESS
  return
}

begin_single_time_command :: proc(
  self: ^VulkanContext,
) -> (
  cmd_buffer: vk.CommandBuffer,
  res: vk.Result,
) {
  alloc_info := vk.CommandBufferAllocateInfo {
    sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
    level              = .PRIMARY,
    commandPool        = self.command_pool,
    commandBufferCount = 1,
  }
  vk.AllocateCommandBuffers(self.vkd, &alloc_info, &cmd_buffer) or_return
  begin_info := vk.CommandBufferBeginInfo {
    sType = .COMMAND_BUFFER_BEGIN_INFO,
    flags = {.ONE_TIME_SUBMIT},
  }
  vk.BeginCommandBuffer(cmd_buffer, &begin_info) or_return
  return cmd_buffer, .SUCCESS
}

end_single_time_command :: proc(
  self: ^VulkanContext,
  cmd_buffer: ^vk.CommandBuffer,
) -> vk.Result {
  vk.EndCommandBuffer(cmd_buffer^) or_return
  submit_info := vk.SubmitInfo {
    sType              = .SUBMIT_INFO,
    commandBufferCount = 1,
    pCommandBuffers    = cmd_buffer,
  }
  vk.QueueSubmit(self.graphics_queue, 1, &submit_info, 0) or_return
  vk.QueueWaitIdle(self.graphics_queue) or_return
  vk.FreeCommandBuffers(self.vkd, self.command_pool, 1, cmd_buffer)
  return .SUCCESS
}

find_memory_type_index :: proc(
  pdevice: vk.PhysicalDevice,
  type_filter: u32,
  properties: vk.MemoryPropertyFlags,
) -> (
  u32,
  bool,
) {
  mem_properties: vk.PhysicalDeviceMemoryProperties
  vk.GetPhysicalDeviceMemoryProperties(pdevice, &mem_properties)
  for i in 0 ..< mem_properties.memoryTypeCount {
    if type_filter & (1 << i) == 0 {
      continue
    }
    if mem_properties.memoryTypes[i].propertyFlags & properties != properties {
      continue
    }
    return u32(i), true
  }
  return 0, false
}

allocate_vulkan_memory :: proc(
  self: ^VulkanContext,
  mem_requirements: vk.MemoryRequirements,
  properties: vk.MemoryPropertyFlags,
) -> (
  memory: vk.DeviceMemory,
  ret: vk.Result,
) {
  memory_type_idx, found := find_memory_type_index(
    self.physical_device,
    mem_requirements.memoryTypeBits,
    properties,
  )
  if !found {
    ret = .ERROR_OUT_OF_DEVICE_MEMORY
    return
  }
  alloc_info := vk.MemoryAllocateInfo {
    sType           = .MEMORY_ALLOCATE_INFO,
    allocationSize  = mem_requirements.size,
    memoryTypeIndex = memory_type_idx,
  }
  vk.AllocateMemory(self.vkd, &alloc_info, nil, &memory) or_return
  ret = .SUCCESS
  return
}

malloc_image_buffer :: proc(
  self: ^VulkanContext,
  width: u32,
  height: u32,
  format: vk.Format,
  tiling: vk.ImageTiling,
  usage: vk.ImageUsageFlags,
  mem_properties: vk.MemoryPropertyFlags,
) -> (
  img_buffer: ImageBuffer,
  ret: vk.Result,
) {
  create_info := vk.ImageCreateInfo {
    sType         = .IMAGE_CREATE_INFO,
    imageType     = .D2,
    extent        = {width, height, 1},
    mipLevels     = 1,
    arrayLayers   = 1,
    format        = format,
    tiling        = tiling,
    initialLayout = .UNDEFINED,
    usage         = usage,
    sharingMode   = .EXCLUSIVE,
    samples       = {._1},
  }
  vk.CreateImage(self.vkd, &create_info, nil, &img_buffer.image) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(self.vkd, img_buffer.image, &mem_reqs)
  img_buffer.memory = allocate_vulkan_memory(
    self,
    mem_reqs,
    mem_properties,
  ) or_return
  vk.BindImageMemory(
    self.vkd,
    img_buffer.image,
    img_buffer.memory,
    0,
  ) or_return
  img_buffer.width = width
  img_buffer.height = height
  img_buffer.format = format
  return img_buffer, .SUCCESS
}

malloc_image_buffer_device_local :: proc(
  self: ^VulkanContext,
  format: vk.Format,
  width: u32,
  height: u32,
) -> (
  ImageBuffer,
  vk.Result,
) {
  return malloc_image_buffer(
    self,
    width,
    height,
    format,
    .OPTIMAL,
    {.TRANSFER_DST, .SAMPLED},
    {.DEVICE_LOCAL},
  )
}

malloc_data_buffer :: proc(
  self: ^VulkanContext,
  size: vk.DeviceSize,
  usage: vk.BufferUsageFlags,
  mem_properties: vk.MemoryPropertyFlags,
) -> (
  data_buf: DataBuffer,
  ret: vk.Result,
) {
  create_info := vk.BufferCreateInfo {
    sType       = .BUFFER_CREATE_INFO,
    size        = size,
    usage       = usage,
    sharingMode = .EXCLUSIVE,
  }
  vk.CreateBuffer(self.vkd, &create_info, nil, &data_buf.buffer) or_return

  mem_reqs: vk.MemoryRequirements
  vk.GetBufferMemoryRequirements(self.vkd, data_buf.buffer, &mem_reqs)

  data_buf.memory = allocate_vulkan_memory(
    self,
    mem_reqs,
    mem_properties,
  ) or_return
  vk.BindBufferMemory(self.vkd, data_buf.buffer, data_buf.memory, 0) or_return
  data_buf.size = size
  return data_buf, .SUCCESS
}

malloc_local_buffer :: proc(
  self: ^VulkanContext,
  size: vk.DeviceSize,
  usage: vk.BufferUsageFlags,
) -> (
  DataBuffer,
  vk.Result,
) {
  return malloc_data_buffer(self, size, usage, {.DEVICE_LOCAL})
}

malloc_host_visible_buffer :: proc(
  self: ^VulkanContext,
  size: vk.DeviceSize,
  usage: vk.BufferUsageFlags,
) -> (
  DataBuffer,
  vk.Result,
) {
  return malloc_data_buffer(self, size, usage, {.HOST_VISIBLE, .HOST_COHERENT})
}

align_up :: proc(
  value: vk.DeviceSize,
  alignment: vk.DeviceSize,
) -> vk.DeviceSize {
  return (value + alignment - 1) & ~(alignment - 1)
}

DataBuffer :: struct {
  buffer: vk.Buffer,
  memory: vk.DeviceMemory,
  mapped: rawptr,
  size:   vk.DeviceSize,
}

data_buffer_write_at :: proc(
  self: ^DataBuffer,
  data: rawptr,
  offset: vk.DeviceSize,
  len: vk.DeviceSize,
) -> vk.Result {
  if self.mapped == nil {
    return .ERROR_UNKNOWN
  }
  if offset + len > self.size {
    return .ERROR_UNKNOWN
  }
  destination_ptr := mem.ptr_offset(cast([^]u8)self.mapped, offset)
  mem.copy(destination_ptr, data, int(len))
  return .SUCCESS
}

data_buffer_write :: proc(
  self: ^DataBuffer,
  data: rawptr,
  len: vk.DeviceSize,
) -> vk.Result {
  return data_buffer_write_at(self, data, 0, len)
}

data_buffer_deinit :: proc(buffer: ^DataBuffer, ctx: ^VulkanContext) {
  if buffer == nil || ctx == nil {
    return
  }
  vkd := ctx.vkd
  if buffer.mapped != nil {
    vk.UnmapMemory(vkd, buffer.memory)
    buffer.mapped = nil
  }
  if buffer.buffer != 0 {
    vk.DestroyBuffer(vkd, buffer.buffer, nil)
    buffer.buffer = 0
  }
  if buffer.memory != 0 {
    vk.FreeMemory(vkd, buffer.memory, nil)
    buffer.memory = 0
  }
  buffer.size = 0
}

ImageBuffer :: struct {
  image:         vk.Image,
  memory:        vk.DeviceMemory,
  width, height: u32,
  format:        vk.Format,
  view:          vk.ImageView,
}

image_buffer_deinit :: proc(vkd: vk.Device, self: ^ImageBuffer) {
  if self.view != 0 {
    vk.DestroyImageView(vkd, self.view, nil)
    self.view = 0
  }
  if self.image != 0 {
    vk.DestroyImage(vkd, self.image, nil)
    self.image = 0
  }
  if self.memory != 0 {
    vk.FreeMemory(vkd, self.memory, nil)
    self.memory = 0
  }
  self.width = 0
  self.height = 0
  self.format = .UNDEFINED
}

create_image_view :: proc(
  vkd: vk.Device,
  image: vk.Image,
  format: vk.Format,
  aspect_mask: vk.ImageAspectFlags,
) -> (
  view: vk.ImageView,
  res: vk.Result,
) {
  create_info := vk.ImageViewCreateInfo {
    sType = .IMAGE_VIEW_CREATE_INFO,
    image = image,
    viewType = .D2,
    format = format,
    components = vk.ComponentMapping {
      r = .IDENTITY,
      g = .IDENTITY,
      b = .IDENTITY,
      a = .IDENTITY,
    },
    subresourceRange = vk.ImageSubresourceRange {
      aspectMask = aspect_mask,
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }
  res = vk.CreateImageView(vkd, &create_info, nil, &view)
  return
}

create_host_visible_buffer :: proc(
  ctx: ^VulkanContext,
  size: vk.DeviceSize,
  usage: vk.BufferUsageFlags,
  data: rawptr = nil,
) -> (
  buffer: DataBuffer,
  ret: vk.Result,
) {
  vkd := ctx.vkd
  buffer.size = size
  buffer = malloc_host_visible_buffer(ctx, size, usage) or_return
  vk.MapMemory(
    vkd,
    buffer.memory,
    0,
    buffer.size,
    {},
    &buffer.mapped,
  ) or_return
  fmt.printfln("Init host visible buffer, buffer mapped at %x", buffer.mapped)
  if data != nil {
    mem.copy(buffer.mapped, data, int(size))
  }
  ret = .SUCCESS
  return
}

create_local_buffer :: proc(
  ctx: ^VulkanContext,
  size: vk.DeviceSize,
  usage: vk.BufferUsageFlags,
  data: rawptr = nil,
) -> (
  buffer: DataBuffer,
  ret: vk.Result,
) {
  buffer = malloc_local_buffer(ctx, size, usage | {.TRANSFER_DST}) or_return
  if data != nil {
    staging := create_host_visible_buffer(
      ctx,
      size,
      {.TRANSFER_SRC},
      data,
    ) or_return
    defer data_buffer_deinit(&staging, ctx)
    copy_buffer(ctx, &buffer, &staging) or_return
  }
  ret = .SUCCESS
  return
}

copy_buffer :: proc(ctx: ^VulkanContext, dst, src: ^DataBuffer) -> vk.Result {
  cmd_buffer := begin_single_time_command(ctx) or_return
  region := vk.BufferCopy {
    srcOffset = 0,
    dstOffset = 0,
    size      = src.size,
  }
  vk.CmdCopyBuffer(cmd_buffer, src.buffer, dst.buffer, 1, &region)
  fmt.printfln(
    "Copying buffer %x mapped %x to %x",
    src.buffer,
    src.mapped,
    dst.buffer,
  )
  return end_single_time_command(ctx, &cmd_buffer)
}

transition_image_layout :: proc(
  ctx: ^VulkanContext,
  image: vk.Image,
  format: vk.Format,
  old_layout, new_layout: vk.ImageLayout,
) -> vk.Result {
  cmd_buffer := begin_single_time_command(ctx) or_return

  src_access_mask: vk.AccessFlags = {}
  dst_access_mask: vk.AccessFlags = {}
  src_stage: vk.PipelineStageFlags = {}
  dst_stage: vk.PipelineStageFlags = {}

  if old_layout == .UNDEFINED && new_layout == .TRANSFER_DST_OPTIMAL {
    src_access_mask = {}
    dst_access_mask = {.TRANSFER_WRITE}
    src_stage = {.TOP_OF_PIPE}
    dst_stage = {.TRANSFER}
  } else if old_layout == .TRANSFER_DST_OPTIMAL &&
     new_layout == .SHADER_READ_ONLY_OPTIMAL {
    src_access_mask = {.TRANSFER_WRITE}
    dst_access_mask = {.SHADER_READ}
    src_stage = {.TRANSFER}
    dst_stage = {.FRAGMENT_SHADER}
  } else {
    // Fallback: generic, but not optimal
    src_stage = {.TOP_OF_PIPE}
    dst_stage = {.TOP_OF_PIPE}
  }

  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = old_layout,
    newLayout = new_layout,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = image,
    subresourceRange = vk.ImageSubresourceRange {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    srcAccessMask = src_access_mask,
    dstAccessMask = dst_access_mask,
  }
  vk.CmdPipelineBarrier(
    cmd_buffer,
    src_stage,
    dst_stage,
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
  return end_single_time_command(ctx, &cmd_buffer)
}
copy_image :: proc(
  ctx: ^VulkanContext,
  dst: ^ImageBuffer,
  src: ^DataBuffer,
) -> vk.Result {
  transition_image_layout(
    ctx,
    dst.image,
    dst.format,
    .UNDEFINED,
    .TRANSFER_DST_OPTIMAL,
  ) or_return
  cmd_buffer := begin_single_time_command(ctx) or_return
  region := vk.BufferImageCopy {
    bufferOffset = 0,
    bufferRowLength = 0,
    bufferImageHeight = 0,
    imageSubresource = vk.ImageSubresourceLayers {
      aspectMask = {.COLOR},
      mipLevel = 0,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    imageOffset = vk.Offset3D{0, 0, 0},
    imageExtent = vk.Extent3D{dst.width, dst.height, 1},
  }
  vk.CmdCopyBufferToImage(
    cmd_buffer,
    src.buffer,
    dst.image,
    .TRANSFER_DST_OPTIMAL,
    1,
    &region,
  )
  end_single_time_command(ctx, &cmd_buffer) or_return
  transition_image_layout(
    ctx,
    dst.image,
    dst.format,
    .TRANSFER_DST_OPTIMAL,
    .SHADER_READ_ONLY_OPTIMAL,
  ) or_return
  return .SUCCESS
}

create_image_buffer :: proc(
  ctx: ^VulkanContext,
  data: rawptr,
  size: vk.DeviceSize,
  format: vk.Format,
  width, height: u32,
) -> (
  img: ImageBuffer,
  ret: vk.Result,
) {
  staging := create_host_visible_buffer(
    ctx,
    size,
    {.TRANSFER_SRC},
    data,
  ) or_return
  defer data_buffer_deinit(&staging, ctx)
  img = malloc_image_buffer(
    ctx,
    width,
    height,
    format,
    .OPTIMAL,
    {.TRANSFER_DST, .SAMPLED},
    {.DEVICE_LOCAL},
  ) or_return
  copy_image(ctx, &img, &staging) or_return
  aspect_mask := vk.ImageAspectFlags{.COLOR}
  img.view = create_image_view(
    ctx.vkd,
    img.image,
    format,
    aspect_mask,
  ) or_return
  ret = .SUCCESS
  return
}
