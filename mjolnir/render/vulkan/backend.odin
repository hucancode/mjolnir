package vulkan_backend

import rhi "../rhi"

import "core:log"
import "core:mem"
import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"

// FRAMES_IN_FLIGHT is the number of frames the CPU may record ahead of the GPU.
FRAMES_IN_FLIGHT :: #config(FRAMES_IN_FLIGHT, 2)
// RETIRE_GRACE is the frames a freed resource or pool slot waits before it is
// destroyed or reused: frames in flight plus one for async compute.
RETIRE_GRACE :: FRAMES_IN_FLIGHT + 1
// Textures and storage images reach shaders through global arrays indexed by handle, and one
// pass renders into several layers of a texture (rhi.PassDesc.layer_count).
BINDLESS :: true

// Backend is every Vulkan object the renderer draws with. render keeps it opaque and goes
// through PROCS (rhi.odin) and the procs below; textures are indexed by render's TextureHandle.
Backend :: struct {
  window:           WindowHandle,
  gctx:             GPUContext,
  swapchain:        Swapchain,
  textures:         []Image,
  samplers:         [rhi.SamplerType]vk.Sampler,
  // set 1 of every pipeline that asks: the global texture, sampler, storage image, draw list
  // and pyramid counter arrays (textures.odin)
  bindless_layout:  vk.DescriptorSetLayout,
  bindless_set:     vk.DescriptorSet,
  // what rhi's handles name (rhi.Pool: index 0 is none, released slots are reused)
  buffers:          rhi.Pool(Buffer),
  layouts:          rhi.Pool(Layout),
  groups:           rhi.Pool(Group),
  pipelines:        rhi.Pool(Pipeline),
  // kept until shutdown: there are a handful
  pipeline_layouts: map[PipelineLayoutKey]vk.PipelineLayout,
  // the views bindless_write made for the storage image array, by index
  storage_views:    []vk.ImageView,
  // init's sizes of the bindless arrays
  bindless_sizes:   [rhi.BindlessArray]u32,
  set_pool:         vk.DescriptorPool,
  // per recording thread, queue and frame slot: the lists' pool, reset whole by frame_wait
  cmd_pools:        [rhi.MAX_RECORD_THREADS][rhi.Queue][FRAMES_IN_FLIGHT]CmdPool,
  // per frame slot: its timed scopes and their timestamps
  timing:           [FRAMES_IN_FLIGHT]TimingSlot,
  // the scopes of the slot frame_wait last waited for
  timings:          [dynamic]rhi.Timing,
  frame_index:      u32,
  // an image is acquired and not yet presented
  acquired:         bool,
  // the backbuffer left UNDEFINED this frame
  backbuffer_in:    bool,
  // per queue: the value the next submission signals, and per frame slot the last one signalled
  next_value:       [rhi.Queue]u64,
  slot_value:       [FRAMES_IN_FLIGHT][rhi.Queue]u64,
}

// WindowHandle is the window render draws into.
WindowHandle :: glfw.WindowHandle

// init brings Vulkan up on window: instance, surface, device, swapchain and the bindless
// arrays. Paired with shutdown.
init :: proc(b: ^Backend, window: WindowHandle, bindless: [rhi.BindlessArray]u32) -> bool {
  b.window = window
  b.bindless_sizes = bindless
  return check(init_vulkan(b), "Vulkan init")
}

// window_size measures the window: its framebuffer in pixels and the pixels per window
// coordinate (the cursor's unit). GLFW answers on the main thread only.
window_size :: proc(b: ^Backend) -> (framebuffer_size: [2]u32, dpi_scale: f32) {
  w, h := glfw.GetFramebufferSize(b.window)
  ww, _ := glfw.GetWindowSize(b.window)
  return {u32(w), u32(h)}, f32(w) / f32(max(ww, 1)) if w > 0 else 1
}

// Logs a failed result; the bool is what render sees.
@(private)
check :: proc(res: vk.Result, what: string) -> bool {
  if res != .SUCCESS do log.errorf("%s failed: %v", what, res)
  return res == .SUCCESS
}

@(private = "file")
init_vulkan :: proc(b: ^Backend) -> vk.Result {
  if !glfw.VulkanSupported() {
    log.errorf("GLFW: Vulkan Not Supported")
    return .ERROR_INITIALIZATION_FAILED
  }
  gctx := &b.gctx
  instance_init(gctx, "mjolnir", glfw.GetRequiredInstanceExtensions(), rawptr(glfw.GetInstanceProcAddress)) or_return
  glfw.CreateWindowSurface(gctx.instance, b.window, nil, &gctx.surface) or_return
  device_init(gctx) or_return
  size, _ := window_size(b)
  swapchain_init(&b.swapchain, gctx, size) or_return
  b.textures = make([]Image, rhi.MAX_TEXTURES)
  // the pool of the one set the backend itself makes, the bindless arrays (a type may repeat);
  // rhi's bind groups have a pool of their own
  b.storage_views = make([]vk.ImageView, bindless_sizes(b)[.STORAGE_IMAGES])
  bindings := bindless_bindings(b)
  sizes: [len(bindings)]vk.DescriptorPoolSize
  for binding, i in bindings do sizes[i] = {binding.type, binding.count}
  pool_info := vk.DescriptorPoolCreateInfo {
    sType         = .DESCRIPTOR_POOL_CREATE_INFO,
    poolSizeCount = len(sizes),
    pPoolSizes    = &sizes[0],
    maxSets       = 1,
  }
  vk.CreateDescriptorPool(gctx.device, &pool_info, nil, &gctx.descriptor_pool) or_return
  bindless_init(b) or_return
  rhi_init(b) or_return
  return .SUCCESS
}

// ready reports whether init has finished: Vulkan is up when init returns.
ready :: proc(b: ^Backend) -> bool {
  return true
}

// shutdown destroys every Vulkan object, textures included.
shutdown :: proc(b: ^Backend) {
  gctx := &b.gctx
  vk.DeviceWaitIdle(gctx.device)
  deferred_flush(gctx)
  rhi_shutdown(b)
  for &img in b.textures do image_destroy(gctx, &img)
  delete(b.textures)
  bindless_shutdown(b)
  swapchain_destroy(&b.swapchain, gctx.device)
  shutdown_context(gctx)
}

// wait_idle lands every queued upload and waits for the GPU; then every resource freed so
// far is destroyed.
wait_idle :: proc(b: ^Backend) {
  if res := submit_uploads(&b.gctx); res != .SUCCESS do log.errorf("Upload submission failed: %v", res)
  vk.DeviceWaitIdle(b.gctx.device)
  deferred_flush(&b.gctx)
}

// tick destroys what was freed RETIRE_GRACE frames ago. Once per frame.
tick :: proc(b: ^Backend) {
  deferred_tick(&b.gctx)
}

// frame_serial is the number of frames submitted so far.
frame_serial :: proc(b: ^Backend) -> u64 {
  return b.gctx.frame_serial
}

// extent is the swapchain size in pixels.
extent :: proc(b: ^Backend) -> [2]u32 {
  return {b.swapchain.extent.width, b.swapchain.extent.height}
}

// resize rebuilds the swapchain at framebuffer_size.
resize :: proc(b: ^Backend, framebuffer_size: [2]u32) -> bool {
  vk.DeviceWaitIdle(b.gctx.device)
  swapchain_destroy(&b.swapchain, b.gctx.device)
  return check(swapchain_init(&b.swapchain, &b.gctx, framebuffer_size), "Swapchain rebuild")
}
