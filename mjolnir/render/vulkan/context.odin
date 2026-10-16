package vulkan_backend

import "base:runtime"
import "core:log"
import "core:slice"
import "core:strings"
import vk "vendor:vulkan"

when ODIN_OS == .Darwin {
  // Dummy import carrying the rpath to /usr/local/lib so Vulkan loads without LD_LIBRARY_PATH.
  // https://gist.github.com/laytan/ba57af3e5a59ab5cb2fca9e25bcfe262
  // Odin appends the next flag (-lm) with no space; the trailing comma makes it its own ld argument.
  @(require, extra_linker_flags = "-Wl,-rpath,/usr/local/lib,")
  foreign import __ "system:System.framework"
}
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

// ENABLE_VALIDATION_LAYERS turns on the Khronos validation layer; on by default in debug builds.
@(private = "file")
ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, ODIN_DEBUG)

when ENABLE_VALIDATION_LAYERS {
  @(private = "file")
  VALIDATION_LAYERS :: []cstring{"VK_LAYER_KHRONOS_validation"}
} else {
  @(private = "file")
  VALIDATION_LAYERS :: []cstring{}
}

// GPUContext owns the Vulkan instance, device, queues, pools and per-frame sync state.
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
  // one-off command buffers (begin_single_time_command); rhi's lists have pools of their own
  command_pool:         vk.CommandPool,
  // every pipeline is created through it
  pipeline_cache:       vk.PipelineCache,
  // the memory blocks buffers and images take ranges of
  allocator:            Allocator,
  device_properties:    vk.PhysicalDeviceProperties,
  trash:                [dynamic]TrashItem, // loose vk resources awaiting deferred destruction
  uploads:              Uploads, // staged writes for the next command buffer
  // signalled with frame serial + 1 when that frame's submission completes
  graphics_timeline:    vk.Semaphore,
  compute_timeline:     vk.Semaphore,
  frame_serial:         u64, // frames submitted so far
  // optional features the device may lack; set by physical_device_init, enabled when present
  depth_clamp:         b32, // shadow casters behind the light's near plane
  draw_indirect_count: bool,
  fill_mode_non_solid: bool,
  geometry_shader:     bool, // gl_PrimitiveID in fragment shaders (random_color)
  host_query_reset:    bool, // timestamp queries reset from the CPU (rhi's frame timings)
  // VK_EXT_debug_utils is on: command buffer labels for debuggers
  debug_labels:        bool,
  // valid bits of a timestamp per queue family (graphics, compute); 0: none
  timestamp_bits:      [2]u32,
}

// only a dedicated compute queue family submits compute separately
@(private)
has_async_compute :: proc(self: ^GPUContext) -> bool {
  return self.compute_family != self.graphics_family
}

// CONCURRENT sharing across the families avoids ownership transfers.
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

@(private = "file")
g_context: runtime.Context

// instance_init loads Vulkan through get_instance_proc_addr and creates the instance with the
// windowing layer's extensions. Create self.surface from self.instance next, then call device_init.
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

// device_init picks a device that can present to self.surface and creates queues and command pools.
device_init :: proc(self: ^GPUContext) -> vk.Result {
  physical_device_init(self) or_return
  allocator_init(self)
  logical_device_init(self) or_return
  command_pool_init(self) or_return
  timelines_init(self) or_return
  vk.CreatePipelineCache(self.device, &{sType = .PIPELINE_CACHE_CREATE_INFO}, nil, &self.pipeline_cache) or_return
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

// shutdown_context destroys every object the context owns, including the device, surface and
// instance. After vkDeviceWaitIdle and deferred_flush (shutdown).
shutdown_context :: proc(self: ^GPUContext) {
  delete(self.trash)
  uploads_destroy(self)
  allocator_destroy(self)
  vk.DestroyDescriptorPool(self.device, self.descriptor_pool, nil)
  vk.DestroyCommandPool(self.device, self.command_pool, nil)
  vk.DestroyPipelineCache(self.device, self.pipeline_cache, nil)
  vk.DestroySemaphore(self.device, self.graphics_timeline, nil)
  vk.DestroySemaphore(self.device, self.compute_timeline, nil)
  vk.DestroyDevice(self.device, nil)
  vk.DestroySurfaceKHR(self.instance, self.surface, nil)
  if self.debug_messenger != 0 do vk.DestroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, nil)
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
  // labels for debuggers whenever the loader has debug utils (RenderDoc adds them)
  self.debug_labels = instance_extension_present(vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
  if self.debug_labels do append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
  when ENABLE_VALIDATION_LAYERS {
    dbg_create_info: vk.DebugUtilsMessengerCreateInfoEXT
    create_info.enabledLayerCount = u32(len(VALIDATION_LAYERS))
    create_info.ppEnabledLayerNames = raw_data(VALIDATION_LAYERS)
    if !self.debug_labels do append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
    self.debug_labels = true
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

@(private = "file")
instance_extension_present :: proc(name: cstring) -> bool {
  count: u32
  vk.EnumerateInstanceExtensionProperties(nil, &count, nil)
  properties := make([]vk.ExtensionProperties, count, context.temp_allocator)
  vk.EnumerateInstanceExtensionProperties(nil, &count, raw_data(properties))
  for &p in properties do if cstring(&p.extensionName[0]) == name do return true
  return false
}

// the slices are in the temp allocator
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
  supported_12 := vk.PhysicalDeviceVulkan12Features{sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES}
  supported := vk.PhysicalDeviceFeatures2 {
    sType = .PHYSICAL_DEVICE_FEATURES_2,
    pNext = &supported_12,
  }
  vk.GetPhysicalDeviceFeatures2(self.physical_device, &supported)
  self.draw_indirect_count = bool(supported_12.drawIndirectCount)
  self.fill_mode_non_solid = bool(supported.features.fillModeNonSolid)
  self.geometry_shader = bool(supported.features.geometryShader)
  self.depth_clamp = supported.features.depthClamp
  self.host_query_reset = bool(supported_12.hostQueryReset)
  log.infof(
    "Optional features: drawIndirectCount=%v fillModeNonSolid=%v geometryShader=%v depthClamp=%v",
    self.draw_indirect_count,
    self.fill_mode_non_solid,
    self.geometry_shader,
    self.depth_clamp,
  )
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
    // prefer a dedicated compute queue
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
    fillModeNonSolid          = b32(self.fill_mode_non_solid), // VK_POLYGON_MODE_LINE wireframe rendering
    depthClamp                = self.depth_clamp,
    geometryShader            = b32(self.geometry_shader),
    // depth pyramid mips indexed by loop counter
    shaderStorageImageArrayDynamicIndexing = true,
    // draw list buffers indexed by view
    shaderStorageBufferArrayDynamicIndexing = true,
  }
  vulkan_12_features := vk.PhysicalDeviceVulkan12Features {
    sType                                     = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
    drawIndirectCount                         = b32(self.draw_indirect_count), // vk.CmdDrawIndexedIndirectCount
    shaderSampledImageArrayNonUniformIndexing = true,
    runtimeDescriptorArray                    = true,
    descriptorBindingPartiallyBound           = true,
    descriptorBindingVariableDescriptorCount  = true,
    // bindless slots are written while other slots are in use
    descriptorBindingUpdateUnusedWhilePending = true,
    timelineSemaphore                         = true, // async compute sync
    shaderOutputLayer                         = true, // layered shadow rendering
    hostQueryReset                            = b32(self.host_query_reset),
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
  vk.CreateDevice(
    self.physical_device,
    &device_create_info,
    nil,
    &self.device,
  ) or_return
  vk.GetDeviceQueue(self.device, self.graphics_family, 0, &self.graphics_queue)
  vk.GetDeviceQueue(self.device, self.present_family, 0, &self.present_queue)
  vk.GetDeviceQueue(self.device, self.compute_family, 0, &self.compute_queue)
  family_count: u32
  vk.GetPhysicalDeviceQueueFamilyProperties(self.physical_device, &family_count, nil)
  family_properties := make([]vk.QueueFamilyProperties, family_count, context.temp_allocator)
  vk.GetPhysicalDeviceQueueFamilyProperties(self.physical_device, &family_count, raw_data(family_properties))
  self.timestamp_bits = {family_properties[self.graphics_family].timestampValidBits, family_properties[self.compute_family].timestampValidBits}
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

// descriptor_pool_init creates the shared pool allocate_descriptor_set draws from, sized by the
// caller. Sets live as long as the pool.
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
    flags            = {.TRANSIENT},
    queueFamilyIndex = self.graphics_family,
  }
  return vk.CreateCommandPool(self.device, &pool_info, nil, &self.command_pool)
}

@(private)
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

// begin_single_time_command returns a one-off command buffer, submitted and waited for by
// end_single_time_command. It starts with every queued upload.
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

// end_single_time_command submits a command buffer from begin_single_time_command and waits for it.
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

// The first memory type of type_filter with `properties`, from the properties allocator_init read.
@(private)
find_memory_type_index :: proc(
  gctx: ^GPUContext,
  type_filter: u32,
  properties: vk.MemoryPropertyFlags,
) -> (
  index: u32,
  ok: bool,
) #optional_ok {
  mem_properties := &gctx.allocator.properties
  for i in 0 ..< mem_properties.memoryTypeCount {
    if type_filter & (1 << i) == 0 do continue
    if mem_properties.memoryTypes[i].propertyFlags & properties != properties do continue
    return u32(i), true
  }
  return 0, false
}
