package mjolnir

import "core:log"
import "core:slice"
import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"

when ODIN_OS == .Darwin {
  // NOTE: just a bogus import of the system library,
  // needed so we can add a linker flag to point to /usr/local/lib (where vulkan is installed by default)
  // when trying to load vulkan.
  // Otherwise we will have to `export LD_LIBRARY_PATH=/usr/local/lib/` everytime we run the app
  // Credit goes to : https://gist.github.com/laytan/ba57af3e5a59ab5cb2fca9e25bcfe262
  @(require, extra_linker_flags = "-rpath /usr/local/lib")
  foreign import __ "system:System.framework"
}

ENGINE_NAME :: "Mjolnir"
TITLE :: "Mjolnir"

DEVICE_EXTENSIONS :: []cstring {
  vk.KHR_SWAPCHAIN_EXTENSION_NAME,
  vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
  vk.EXT_DESCRIPTOR_INDEXING_EXTENSION_NAME,
}

ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, ODIN_DEBUG)

when ENABLE_VALIDATION_LAYERS {
  VALIDATION_LAYERS :: []cstring{"VK_LAYER_KHRONOS_validation"}
} else {
  VALIDATION_LAYERS :: []cstring{}
}

ACTIVE_MATERIAL_COUNT :: 1000
MAX_SAMPLER_PER_MATERIAL :: 3
MAX_SAMPLER_COUNT :: ACTIVE_MATERIAL_COUNT * MAX_SAMPLER_PER_MATERIAL
SCENE_CAMERA_COUNT :: 3

MAX_SAMPLERS :: 4
SAMPLER_NEAREST_CLAMP :: 0
SAMPLER_LINEAR_CLAMP :: 1
SAMPLER_NEAREST_REPEAT :: 2
SAMPLER_LINEAR_REPEAT :: 3

SwapchainSupport :: struct {
  capabilities:  vk.SurfaceCapabilitiesKHR,
  formats:       []vk.SurfaceFormatKHR, // Owned by this struct if allocated by it
  present_modes: []vk.PresentModeKHR, // Owned by this struct if allocated by it
}

FoundQueueFamilyIndices :: struct {
  graphics_family: u32,
  present_family:  u32,
}

g_window: glfw.WindowHandle
g_instance: vk.Instance
g_device: vk.Device
g_surface: vk.SurfaceKHR
g_surface_capabilities: vk.SurfaceCapabilitiesKHR
g_surface_formats: []vk.SurfaceFormatKHR
g_present_modes: []vk.PresentModeKHR
g_debug_messenger: vk.DebugUtilsMessengerEXT
g_physical_device: vk.PhysicalDevice
g_graphics_family: u32
g_graphics_queue: vk.Queue
g_present_family: u32
g_present_queue: vk.Queue
g_descriptor_pool: vk.DescriptorPool
g_command_pool: vk.CommandPool
g_device_properties: vk.PhysicalDeviceProperties

vulkan_context_init :: proc(window: glfw.WindowHandle) -> vk.Result {
  g_window = window
  vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
  vulkan_instance_init() or_return
  surface_init() or_return
  physical_device_init() or_return
  logical_device_init() or_return
  command_pool_init() or_return
  descriptor_pool_init() or_return
  return .SUCCESS
}

vulkan_context_deinit :: proc() {
  vk.DeviceWaitIdle(g_device)
  vk.DestroyDescriptorPool(g_device, g_descriptor_pool, nil)
  vk.DestroyCommandPool(g_device, g_command_pool, nil)
  vk.DestroyDevice(g_device, nil)
  vk.DestroySurfaceKHR(g_instance, g_surface, nil)
  when ENABLE_VALIDATION_LAYERS {
    vk.DestroyDebugUtilsMessengerEXT(g_instance, g_debug_messenger, nil)
  }
  vk.DestroyInstance(g_instance, nil)
  delete(g_surface_formats)
  delete(g_present_modes)
  g_surface_formats = nil
  g_present_modes = nil
}

debug_callback :: proc "system" (
  message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
  message_type: vk.DebugUtilsMessageTypeFlagsEXT,
  p_callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
  p_user_data: rawptr,
) -> b32 {
  context = g_context
  message := string(p_callback_data.pMessage)
  switch {
  case .ERROR in message_severity:
    log.errorf("Validation: %s", message)
  case .WARNING in message_severity:
    log.warnf("Validation: %s", message)
  case .INFO in message_severity:
    log.infof("Validation: %s", message)
  case .VERBOSE in message_severity:
    log.debugf("Validation: %s", message)
  case:
    log.infof("Validation: %s", message)
  }
  return false
}

vulkan_instance_init :: proc() -> vk.Result {
  extensions := slice.clone_to_dynamic(glfw.GetRequiredInstanceExtensions())
  defer delete(extensions)
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
  when ENABLE_VALIDATION_LAYERS {
    dbg_create_info: vk.DebugUtilsMessengerCreateInfoEXT
    create_info.enabledLayerCount = u32(len(VALIDATION_LAYERS))
    create_info.ppEnabledLayerNames = raw_data(VALIDATION_LAYERS)
    append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
    dbg_create_info = {
      sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
      messageSeverity = {
        .WARNING,
        .ERROR,
        .INFO,
        //.VERBOSE
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
  vk.CreateInstance(&create_info, nil, &g_instance) or_return
  vk.load_proc_addresses_instance(g_instance)
  when ENABLE_VALIDATION_LAYERS {
    vk.CreateDebugUtilsMessengerEXT(
      g_instance,
      &dbg_create_info,
      nil,
      &g_debug_messenger,
    ) or_return
  }
  log.infof("Vulkan instance created: %s", app_info.pApplicationName)
  return .SUCCESS
}

surface_init :: proc() -> vk.Result {
  glfw.CreateWindowSurface(g_instance, g_window, nil, &g_surface) or_return
  log.infof("Vulkan surface created")
  return .SUCCESS
}

query_swapchain_support :: proc(
  physical_device: vk.PhysicalDevice,
  surface: vk.SurfaceKHR,
) -> (
  support: SwapchainSupport,
  res: vk.Result,
) {
  vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
    physical_device,
    surface,
    &support.capabilities,
  ) or_return
  count: u32
  vk.GetPhysicalDeviceSurfaceFormatsKHR(
    physical_device,
    surface,
    &count,
    nil,
  ) or_return
  if count > 0 {
    support.formats = make([]vk.SurfaceFormatKHR, count)
    vk.GetPhysicalDeviceSurfaceFormatsKHR(
      physical_device,
      surface,
      &count,
      raw_data(support.formats),
    ) or_return
  }
  vk.GetPhysicalDeviceSurfacePresentModesKHR(
    physical_device,
    surface,
    &count,
    nil,
  ) or_return
  if count > 0 {
    support.present_modes = make([]vk.PresentModeKHR, count)
    vk.GetPhysicalDeviceSurfacePresentModesKHR(
      physical_device,
      surface,
      &count,
      raw_data(support.present_modes),
    ) or_return
  }
  return support, .SUCCESS
}

swapchain_support_deinit :: proc(self: ^SwapchainSupport) {
  delete(self.formats)
  delete(self.present_modes)
  self.formats = nil
  self.present_modes = nil
}

score_physical_device :: proc(
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
  log.infof("Scoring device %s", device_name_cstring)
  when ODIN_OS != .Darwin {
    if !features.geometryShader {
      log.infof("Device %s: no geometry shader.", device_name_cstring)
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
  log.infof("vulkan: device supports %v extensions", len(available_extensions))
  required_loop: for required in DEVICE_EXTENSIONS {
    log.infof("vulkan: checking for required extension %q", required)
    for &extension in available_extensions {
      extension_name := strings.truncate_to_byte(
        string(extension.extensionName[:]),
        0,
      )
      if extension_name == string(required) {
        continue required_loop
      }
    }
    log.infof("vulkan: device does not support required extension", required)
    return 0, .NOT_READY
  }
  log.infof("vulkan: device supports all required extensions")
  support := query_swapchain_support(device, g_surface) or_return
  defer swapchain_support_deinit(&support)
  if len(support.formats) == 0 || len(support.present_modes) == 0 {
    log.infof("Device %s: inadequate swapchain support.", device_name_cstring)
    return 0, .SUCCESS
  }
  _, qf_res := find_queue_families(device, g_surface)
  if qf_res != .SUCCESS {
    log.infof("Device %s: no suitable queue families.", device_name_cstring)
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
  log.infof("Device %s scored %d", device_name_cstring, current_score)
  return current_score, .SUCCESS
}

physical_device_init :: proc() -> vk.Result {
  count: u32
  vk.EnumeratePhysicalDevices(g_instance, &count, nil) or_return
  if count == 0 {
    log.infof("Error: No physical devices found!")
    return .ERROR_INITIALIZATION_FAILED
  }
  log.infof("Found %d physical device(s)", count)
  devices_slice := make([]vk.PhysicalDevice, count)
  defer delete(devices_slice)
  vk.EnumeratePhysicalDevices(
    g_instance,
    &count,
    raw_data(devices_slice),
  ) or_return
  best_score: u32 = 0
  for device_handle in devices_slice {
    score_val := score_physical_device(device_handle) or_return
    log.infof(" - Device Score: %d", score_val)
    if score_val > best_score {
      g_physical_device = device_handle
      best_score = score_val
    }
  }
  if best_score == 0 {
    log.infof("Error: No suitable physical device found!")
    return .ERROR_INITIALIZATION_FAILED
  }
  vk.GetPhysicalDeviceProperties(g_physical_device, &g_device_properties)
  log.infof(
    "\nSelected physical device: %s (score %d)",
    cstring(&g_device_properties.deviceName[0]),
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

logical_device_init :: proc() -> vk.Result {
  indices := find_queue_families(g_physical_device, g_surface) or_return
  g_graphics_family = indices.graphics_family
  g_present_family = indices.present_family
  support_details := query_swapchain_support(
    g_physical_device,
    g_surface,
  ) or_return
  g_surface_capabilities = support_details.capabilities
  g_surface_formats = support_details.formats
  g_present_modes = support_details.present_modes
  queue_create_infos_list := make([dynamic]vk.DeviceQueueCreateInfo, 0, 2)
  defer delete(queue_create_infos_list)
  unique_queue_families := make(map[u32]struct {
    }, 2)
  defer delete(unique_queue_families)
  unique_queue_families[g_graphics_family] = {}
  unique_queue_families[g_present_family] = {}
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
  // Enable descriptor indexing features
  descriptor_indexing_features :=
    vk.PhysicalDeviceDescriptorIndexingFeaturesEXT {
      sType                                     = .PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES_EXT,
      shaderSampledImageArrayNonUniformIndexing = true,
      runtimeDescriptorArray                    = true,
      descriptorBindingPartiallyBound           = true,
      descriptorBindingVariableDescriptorCount  = true,
    }
  dynamic_rendering_feature := vk.PhysicalDeviceDynamicRenderingFeaturesKHR {
      sType            = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR,
      dynamicRendering = true,
      pNext            = &descriptor_indexing_features,
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
    g_physical_device,
    &device_create_info,
    nil,
    &g_device,
  ) or_return
  vk.GetDeviceQueue(g_device, g_graphics_family, 0, &g_graphics_queue)
  vk.GetDeviceQueue(g_device, g_present_family, 0, &g_present_queue)
  return .SUCCESS
}

descriptor_pool_init :: proc() -> vk.Result {
  // expand those limits as needed
  pool_sizes := [?]vk.DescriptorPoolSize {
    {.COMBINED_IMAGE_SAMPLER, MAX_SAMPLER_COUNT},
    {.SAMPLED_IMAGE, MAX_SAMPLER_COUNT},
    {.SAMPLER, MAX_SAMPLER_COUNT},
    {.UNIFORM_BUFFER, 128},
    {.UNIFORM_BUFFER_DYNAMIC, 128},
    {.STORAGE_BUFFER, ACTIVE_MATERIAL_COUNT},
  }
  log.infof("Descriptor pool allocation sizes:")
  log.infof(" - Combined Image Samplers: %d", MAX_SAMPLER_COUNT)
  log.infof(
    " - Uniform Buffers: %d",
    MAX_FRAMES_IN_FLIGHT * SCENE_CAMERA_COUNT,
  )
  log.infof(" - Storage Buffers: %d", ACTIVE_MATERIAL_COUNT)
  pool_info := vk.DescriptorPoolCreateInfo {
    sType         = .DESCRIPTOR_POOL_CREATE_INFO,
    poolSizeCount = len(pool_sizes),
    pPoolSizes    = raw_data(pool_sizes[:]),
    maxSets       = MAX_FRAMES_IN_FLIGHT + ACTIVE_MATERIAL_COUNT,
    // flags = {.FREE_DESCRIPTOR_SET} // If needed
  }
  log.infof("Creating descriptor pool with maxSets: %d", pool_info.maxSets)
  result := vk.CreateDescriptorPool(
    g_device,
    &pool_info,
    nil,
    &g_descriptor_pool,
  )
  if result != .SUCCESS {
    log.infof("Failed to create descriptor pool with error: %v", result)
    return result
  }
  log.infof("Vulkan descriptor pool created successfully")
  return .SUCCESS
}

command_pool_init :: proc() -> vk.Result {
  pool_info := vk.CommandPoolCreateInfo {
    sType            = .COMMAND_POOL_CREATE_INFO,
    flags            = {.RESET_COMMAND_BUFFER},
    queueFamilyIndex = g_graphics_family,
  }
  vk.CreateCommandPool(g_device, &pool_info, nil, &g_command_pool) or_return
  log.infof("Vulkan command pool created")
  return .SUCCESS
}

create_shader_module :: proc(
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
  vk.CreateShaderModule(g_device, &create_info, nil, &module) or_return
  res = .SUCCESS
  return
}

begin_single_time_command :: proc(
) -> (
  cmd_buffer: vk.CommandBuffer,
  res: vk.Result,
) {
  alloc_info := vk.CommandBufferAllocateInfo {
    sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
    level              = .PRIMARY,
    commandPool        = g_command_pool,
    commandBufferCount = 1,
  }
  vk.AllocateCommandBuffers(g_device, &alloc_info, &cmd_buffer) or_return
  begin_info := vk.CommandBufferBeginInfo {
    sType = .COMMAND_BUFFER_BEGIN_INFO,
    flags = {.ONE_TIME_SUBMIT},
  }
  vk.BeginCommandBuffer(cmd_buffer, &begin_info) or_return
  return cmd_buffer, .SUCCESS
}

end_single_time_command :: proc(cmd_buffer: ^vk.CommandBuffer) -> vk.Result {
  vk.EndCommandBuffer(cmd_buffer^) or_return
  submit_info := vk.SubmitInfo {
    sType              = .SUBMIT_INFO,
    commandBufferCount = 1,
    pCommandBuffers    = cmd_buffer,
  }
  vk.QueueSubmit(g_graphics_queue, 1, &submit_info, 0) or_return
  vk.QueueWaitIdle(g_graphics_queue) or_return
  vk.FreeCommandBuffers(g_device, g_command_pool, 1, cmd_buffer)
  return .SUCCESS
}

find_memory_type_index :: proc(
  type_filter: u32,
  properties: vk.MemoryPropertyFlags,
) -> (
  u32,
  bool,
) {
  mem_properties: vk.PhysicalDeviceMemoryProperties
  vk.GetPhysicalDeviceMemoryProperties(g_physical_device, &mem_properties)
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
  mem_requirements: vk.MemoryRequirements,
  properties: vk.MemoryPropertyFlags,
) -> (
  memory: vk.DeviceMemory,
  ret: vk.Result,
) {
  memory_type_idx, found := find_memory_type_index(
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
  vk.AllocateMemory(g_device, &alloc_info, nil, &memory) or_return
  ret = .SUCCESS
  return
}

