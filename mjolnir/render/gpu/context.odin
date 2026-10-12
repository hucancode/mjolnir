package gpu

import "base:runtime"
import "core:log"
import "core:slice"
import "core:strings"
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
FRAMES_IN_FLIGHT :: #config(FRAMES_IN_FLIGHT, 2)

// not yet in vendor bindings (needs vulkan header >= 315)
@(private)
PhysicalDeviceUnifiedImageLayoutsFeaturesKHR :: struct {
  sType:                                       vk.StructureType,
  pNext:                                       rawptr,
  unifiedImageLayouts, unifiedImageLayoutsVideo: b32,
}

@(private)
DEVICE_EXTENSIONS :: []cstring {
  vk.KHR_SWAPCHAIN_EXTENSION_NAME,
  "VK_KHR_unified_image_layouts",
}

ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, ODIN_DEBUG)

when ENABLE_VALIDATION_LAYERS {
  VALIDATION_LAYERS :: []cstring{"VK_LAYER_KHRONOS_validation"}
} else {
  VALIDATION_LAYERS :: []cstring{}
}

GPUContext :: struct {
  instance:             vk.Instance,
  device:               vk.Device,
  surface:              vk.SurfaceKHR,
  debug_messenger:      vk.DebugUtilsMessengerEXT,
  physical_device:      vk.PhysicalDevice,
  graphics_family:      u32,
  graphics_queue:       vk.Queue,
  present_family:       u32,
  present_queue:        vk.Queue,
  compute_family:       u32, // equals graphics_family without a dedicated compute queue
  compute_queue:        vk.Queue,
  descriptor_pool:      vk.DescriptorPool,
  command_pool:         vk.CommandPool,
  compute_command_pool: vk.CommandPool,
  device_properties:    vk.PhysicalDeviceProperties,
  trash:                [dynamic]TrashItem, // loose vk resources awaiting deferred destruction
  uploads:              Uploads, // staged writes for the next command buffer
  // Timeline semaphores signalled with the frame serial + 1 when that
  // frame's graphics / compute submission completes.
  graphics_timeline:    vk.Semaphore,
  compute_timeline:     vk.Semaphore,
  frame_serial:         u64, // frames submitted so far
}

// Compute work is recorded and submitted separately only when the device has
// a dedicated compute queue family.
has_async_compute :: proc(self: ^GPUContext) -> bool {
  return self.compute_family != self.graphics_family
}

// Fill a create info's sharing fields. With async compute, resources both
// queues access are CONCURRENT across the graphics and compute families, so
// they need no ownership transfers.
@(private)
set_sharing :: proc(self: ^GPUContext, info: ^$T, shared: bool, families: ^[2]u32) {
  families^ = {self.graphics_family, self.compute_family}
  if shared && has_async_compute(self) {
    info.sharingMode = .CONCURRENT
    info.queueFamilyIndexCount = 2
    info.pQueueFamilyIndices = raw_data(families[:])
  } else {
    info.sharingMode = .EXCLUSIVE
  }
}

// Global context for debug callback
g_context: runtime.Context

// First init phase: load Vulkan through `get_instance_proc_addr`
// (vkGetInstanceProcAddr) and create the instance with the extensions the
// windowing layer needs. Create `self.surface` from `self.instance` next, then
// call device_init.
instance_init :: proc(
  self: ^GPUContext,
  app_name: cstring,
  instance_extensions: []cstring,
  get_instance_proc_addr: rawptr,
) -> vk.Result {
  when ENABLE_VALIDATION_LAYERS {
    g_context = context
  }
  vk.load_proc_addresses_global(get_instance_proc_addr)
  return vulkan_instance_init(self, app_name, instance_extensions)
}

// Second init phase: pick a device that can present to `self.surface` and
// create queues and command pools.
device_init :: proc(self: ^GPUContext) -> vk.Result {
  physical_device_init(self) or_return
  logical_device_init(self) or_return
  command_pool_init(self) or_return
  timelines_init(self) or_return
  return .SUCCESS
}

@(private = "file")
timelines_init :: proc(self: ^GPUContext) -> vk.Result {
  type_info := vk.SemaphoreTypeCreateInfo {
    sType         = .SEMAPHORE_TYPE_CREATE_INFO,
    semaphoreType = .TIMELINE,
  }
  info := vk.SemaphoreCreateInfo {
    sType = .SEMAPHORE_CREATE_INFO,
    pNext = &type_info,
  }
  vk.CreateSemaphore(self.device, &info, nil, &self.graphics_timeline) or_return
  vk.CreateSemaphore(self.device, &info, nil, &self.compute_timeline) or_return
  return .SUCCESS
}

shutdown :: proc(self: ^GPUContext) {
  vk.DeviceWaitIdle(self.device)
  deferred_flush(self)
  delete(self.trash)
  uploads_destroy(self)
  vk.DestroyDescriptorPool(self.device, self.descriptor_pool, nil)
  vk.DestroyCommandPool(self.device, self.command_pool, nil)
  vk.DestroyCommandPool(self.device, self.compute_command_pool, nil)
  vk.DestroySemaphore(self.device, self.graphics_timeline, nil)
  vk.DestroySemaphore(self.device, self.compute_timeline, nil)
  vk.DestroyDevice(self.device, nil)
  vk.DestroySurfaceKHR(self.instance, self.surface, nil)
  when ENABLE_VALIDATION_LAYERS {
    vk.DestroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, nil)
  }
  vk.DestroyInstance(self.instance, nil)
}

@(private = "file")
debug_callback :: proc "system" (
  message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
  message_type: vk.DebugUtilsMessageTypeFlagsEXT,
  p_callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
  p_user_data: rawptr,
) -> b32 {
  context = g_context
  message := string(p_callback_data.pMessage)
  short_msg, verbose := strings.substring_to(
    message,
    strings.index(message, "\nThe Vulkan spec states:"),
  )
  level: log.Level = .Error if .ERROR in message_severity else .Warning if .WARNING in message_severity else .Info
  log.logf(level, "Validation: %s", short_msg if verbose else message)
  return false
}

@(private = "file")
vulkan_instance_init :: proc(
  self: ^GPUContext,
  app_name: cstring,
  instance_extensions: []cstring,
) -> vk.Result {
  extensions := slice.clone_to_dynamic(
    instance_extensions,
    context.temp_allocator,
  )
  app_info := vk.ApplicationInfo {
    sType              = .APPLICATION_INFO,
    pApplicationName   = app_name,
    applicationVersion = vk.MAKE_VERSION(1, 0, 0),
    pEngineName        = "Mjolnir",
    engineVersion      = vk.MAKE_VERSION(1, 0, 0),
    apiVersion         = vk.API_VERSION_1_3,
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
      messageSeverity = {.WARNING, .ERROR},
      messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
      pfnUserCallback = debug_callback,
    }
    create_info.pNext = &dbg_create_info
  }
  create_info.enabledExtensionCount = u32(len(extensions))
  create_info.ppEnabledExtensionNames = raw_data(extensions)
  vk.CreateInstance(&create_info, nil, &self.instance) or_return
  vk.load_proc_addresses_instance(self.instance)
  when ENABLE_VALIDATION_LAYERS {
    vk.CreateDebugUtilsMessengerEXT(
      self.instance,
      &dbg_create_info,
      nil,
      &self.debug_messenger,
    ) or_return
  }
  log.infof("Vulkan instance created: %s", app_info.pApplicationName)
  return .SUCCESS
}

// What `surface` supports on `physical_device`; the slices are in the temp
// allocator.
@(private)
query_swapchain_support :: proc(
  physical_device: vk.PhysicalDevice,
  surface: vk.SurfaceKHR,
) -> (
  capabilities: vk.SurfaceCapabilitiesKHR,
  formats: []vk.SurfaceFormatKHR,
  present_modes: []vk.PresentModeKHR,
  res: vk.Result,
) {
  vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &capabilities) or_return
  count: u32
  vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &count, nil) or_return
  formats = make([]vk.SurfaceFormatKHR, count, context.temp_allocator)
  vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &count, raw_data(formats)) or_return
  vk.GetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &count, nil) or_return
  present_modes = make([]vk.PresentModeKHR, count, context.temp_allocator)
  vk.GetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &count, raw_data(present_modes)) or_return
  return
}

@(private = "file")
score_physical_device :: proc(
  self: ^GPUContext,
  device: vk.PhysicalDevice,
) -> (
  score: u32,
  res: vk.Result,
) {
  props: vk.PhysicalDeviceProperties
  vk.GetPhysicalDeviceProperties(device, &props)
  device_name_cstring := cstring(&props.deviceName[0])
  log.infof("Scoring device %s", device_name_cstring)
  ext_count: u32
  vk.EnumerateDeviceExtensionProperties(device, nil, &ext_count, nil) or_return
  available_extensions := make(
    []vk.ExtensionProperties,
    ext_count,
    context.temp_allocator,
  )
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
    log.infof(
      "Device %s: missing required extension %q.",
      device_name_cstring,
      required,
    )
    return 0, .SUCCESS
  }
  log.infof("vulkan: device supports all required extensions")
  _, formats, present_modes := query_swapchain_support(device, self.surface) or_return
  if len(formats) == 0 || len(present_modes) == 0 {
    log.infof("Device %s: inadequate swapchain support.", device_name_cstring)
    return 0, .SUCCESS
  }
  _, _, _, qf_res := find_queue_families(device, self.surface)
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

@(private = "file")
physical_device_init :: proc(self: ^GPUContext) -> vk.Result {
  count: u32
  vk.EnumeratePhysicalDevices(self.instance, &count, nil) or_return
  if count == 0 {
    log.error("No physical devices found!")
    return .ERROR_INITIALIZATION_FAILED
  }
  log.infof("Found %d physical device(s)", count)
  devices_slice := make([]vk.PhysicalDevice, count, context.temp_allocator)
  vk.EnumeratePhysicalDevices(
    self.instance,
    &count,
    raw_data(devices_slice),
  ) or_return
  best_score: u32 = 0
  for device_handle in devices_slice {
    score_val := score_physical_device(self, device_handle) or_return
    log.infof(" - Device Score: %d", score_val)
    if score_val > best_score {
      self.physical_device = device_handle
      best_score = score_val
    }
  }
  if best_score == 0 {
    log.error("No suitable physical device found!")
    return .ERROR_INITIALIZATION_FAILED
  }
  vk.GetPhysicalDeviceProperties(self.physical_device, &self.device_properties)
  log.infof(
    "\nSelected physical device: %s (score %d)",
    cstring(&self.device_properties.deviceName[0]),
    best_score,
  )
  return .SUCCESS
}

@(private = "file")
find_queue_families :: proc(
  physical_device: vk.PhysicalDevice,
  surface: vk.SurfaceKHR,
) -> (
  graphics, present, compute: u32,
  res: vk.Result,
) {
  count: u32
  vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &count, nil)
  queue_families_slice := make(
    []vk.QueueFamilyProperties,
    count,
    context.temp_allocator,
  )
  vk.GetPhysicalDeviceQueueFamilyProperties(
    physical_device,
    &count,
    raw_data(queue_families_slice),
  )
  maybe_graphics_family: Maybe(u32)
  maybe_present_family: Maybe(u32)
  maybe_compute_family: Maybe(u32)
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
    // Prefer dedicated compute queue (COMPUTE but not GRAPHICS)
    if .COMPUTE in family.queueFlags && .GRAPHICS not_in family.queueFlags {
      maybe_compute_family = idx
    }
    if maybe_graphics_family != nil &&
       maybe_present_family != nil &&
       maybe_compute_family != nil {
      break
    }
  }
  if g_fam, ok_g := maybe_graphics_family.?; ok_g {
    if p_fam, ok_p := maybe_present_family.?; ok_p {
      // Without a dedicated queue, compute runs on the graphics queue.
      return g_fam, p_fam, maybe_compute_family.? or_else g_fam, .SUCCESS
    }
  }
  res = .ERROR_FEATURE_NOT_PRESENT
  return
}

@(private = "file")
logical_device_init :: proc(self: ^GPUContext) -> vk.Result {
  self.graphics_family, self.present_family, self.compute_family = find_queue_families(self.physical_device, self.surface) or_return
  // one queue of each distinct family
  queue_priority: f32 = 1.0
  queue_infos: [3]vk.DeviceQueueCreateInfo
  queue_count := 0
  families: for family in ([3]u32{self.graphics_family, self.present_family, self.compute_family}) {
    for info in queue_infos[:queue_count] do if info.queueFamilyIndex == family do continue families
    queue_infos[queue_count] = {
      sType            = .DEVICE_QUEUE_CREATE_INFO,
      queueFamilyIndex = family,
      queueCount       = 1,
      pQueuePriorities = &queue_priority,
    }
    queue_count += 1
  }
  unified_layouts_features := PhysicalDeviceUnifiedImageLayoutsFeaturesKHR {
    sType               = vk.StructureType(1000527000),
    unifiedImageLayouts = true,
  }
  // Enable descriptor indexing features
  vulkan_13_features := vk.PhysicalDeviceVulkan13Features {
    sType                          = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
    dynamicRendering               = true,
    synchronization2               = true,
    shaderDemoteToHelperInvocation = true,
    pNext                          = &unified_layouts_features,
  }
  basic_features := vk.PhysicalDeviceFeatures {
    multiDrawIndirect         = true, // Required for vk.CmdDrawIndexedIndirect with drawCount > 1
    drawIndirectFirstInstance = true, // Required for using firstInstance field in indirect commands
    fillModeNonSolid          = true, // Required for VK_POLYGON_MODE_LINE wireframe rendering
    // depth pyramid mips indexed by loop counter
    shaderStorageImageArrayDynamicIndexing = true,
    // draw list buffers indexed by view
    shaderStorageBufferArrayDynamicIndexing = true,
  }
  vulkan_12_features := vk.PhysicalDeviceVulkan12Features {
    sType                                     = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
    drawIndirectCount                         = true, // Required for vk.CmdDrawIndexedIndirectCount
    samplerFilterMinmax                       = true,
    shaderSampledImageArrayNonUniformIndexing = true,
    runtimeDescriptorArray                    = true,
    descriptorBindingPartiallyBound           = true,
    descriptorBindingVariableDescriptorCount  = true,
    // bindless slots are written while other slots are in use
    descriptorBindingUpdateUnusedWhilePending = true,
    timelineSemaphore                         = true, // async compute sync
    shaderOutputLayer                         = true, // layered shadow rendering
    pNext                                     = &vulkan_13_features,
  }
  device_create_info := vk.DeviceCreateInfo {
    sType                   = .DEVICE_CREATE_INFO,
    queueCreateInfoCount    = u32(queue_count),
    pQueueCreateInfos       = raw_data(queue_infos[:]),
    ppEnabledExtensionNames = raw_data(DEVICE_EXTENSIONS),
    enabledExtensionCount   = u32(len(DEVICE_EXTENSIONS)),
    pEnabledFeatures        = &basic_features,
    pNext                   = &vulkan_12_features,
  }
  when ENABLE_VALIDATION_LAYERS {
    device_create_info.enabledLayerCount = u32(len(VALIDATION_LAYERS))
    device_create_info.ppEnabledLayerNames = raw_data(VALIDATION_LAYERS)
  }
  vk.CreateDevice(
    self.physical_device,
    &device_create_info,
    nil,
    &self.device,
  ) or_return
  vk.GetDeviceQueue(self.device, self.graphics_family, 0, &self.graphics_queue)
  vk.GetDeviceQueue(self.device, self.present_family, 0, &self.present_queue)
  vk.GetDeviceQueue(self.device, self.compute_family, 0, &self.compute_queue)
  if has_async_compute(self) {
    log.infof(
      "Async compute enabled: dedicated compute queue family %d",
      self.compute_family,
    )
  } else {
    log.infof("Async compute disabled: using graphics queue for compute")
  }
  return .SUCCESS
}

// Create the shared descriptor pool that allocate_descriptor_set draws
// from, sized by the caller (the renderer knows its sets). Sets live as long
// as the pool.
descriptor_pool_init :: proc(
  self: ^GPUContext,
  pool_sizes: []vk.DescriptorPoolSize,
  max_sets: u32,
) -> vk.Result {
  pool_info := vk.DescriptorPoolCreateInfo {
    sType         = .DESCRIPTOR_POOL_CREATE_INFO,
    poolSizeCount = u32(len(pool_sizes)),
    pPoolSizes    = raw_data(pool_sizes),
    maxSets       = max_sets,
  }
  return vk.CreateDescriptorPool(self.device, &pool_info, nil, &self.descriptor_pool)
}

@(private = "file")
command_pool_init :: proc(self: ^GPUContext) -> vk.Result {
  pool_info := vk.CommandPoolCreateInfo {
    sType            = .COMMAND_POOL_CREATE_INFO,
    flags            = {.RESET_COMMAND_BUFFER},
    queueFamilyIndex = self.graphics_family,
  }
  vk.CreateCommandPool(
    self.device,
    &pool_info,
    nil,
    &self.command_pool,
  ) or_return
  log.infof("Vulkan graphics command pool created")
  pool_info.queueFamilyIndex = self.compute_family
  vk.CreateCommandPool(
    self.device,
    &pool_info,
    nil,
    &self.compute_command_pool,
  ) or_return
  log.infof("Vulkan compute command pool created")
  return .SUCCESS
}

create_shader_module :: proc(
  device: vk.Device,
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
  vk.CreateShaderModule(device, &create_info, nil, &module) or_return
  res = .SUCCESS
  return
}

// A one-off command buffer, submitted and waited for by
// end_single_time_command. It starts with every queued upload, so the
// recorded work sees them.
begin_single_time_command :: proc(
  self: ^GPUContext,
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
  vk.AllocateCommandBuffers(self.device, &alloc_info, &cmd_buffer) or_return
  begin_record(cmd_buffer) or_return
  record_uploads(self, cmd_buffer)
  return cmd_buffer, .SUCCESS
}

end_single_time_command :: proc(
  self: ^GPUContext,
  cmd_buffer: ^vk.CommandBuffer,
) -> vk.Result {
  vk.EndCommandBuffer(cmd_buffer^) or_return
  cmd_info := vk.CommandBufferSubmitInfo {
    sType         = .COMMAND_BUFFER_SUBMIT_INFO,
    commandBuffer = cmd_buffer^,
  }
  submit_info := vk.SubmitInfo2 {
    sType                  = .SUBMIT_INFO_2,
    commandBufferInfoCount = 1,
    pCommandBufferInfos    = &cmd_info,
  }
  vk.QueueSubmit2(self.graphics_queue, 1, &submit_info, 0) or_return
  vk.QueueWaitIdle(self.graphics_queue) or_return
  vk.FreeCommandBuffers(self.device, self.command_pool, 1, cmd_buffer)
  return .SUCCESS
}

@(private)
find_memory_type_index :: proc(
  physical_device: vk.PhysicalDevice,
  type_filter: u32,
  properties: vk.MemoryPropertyFlags,
) -> (
  index: u32,
  ok: bool,
) #optional_ok {
  mem_properties: vk.PhysicalDeviceMemoryProperties
  vk.GetPhysicalDeviceMemoryProperties(physical_device, &mem_properties)
  for i in 0 ..< mem_properties.memoryTypeCount {
    if type_filter & (1 << i) == 0 do continue
    if mem_properties.memoryTypes[i].propertyFlags & properties != properties do continue
    return u32(i), true
  }
  return 0, false
}

@(private)
allocate_memory :: proc(
  self: ^GPUContext,
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
  vk.AllocateMemory(self.device, &alloc_info, nil, &memory) or_return
  ret = .SUCCESS
  return
}
