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

// Backend is every Vulkan object the renderer draws with. render keeps it opaque and goes
// through PROCS (rhi.odin) and the procs below; textures are indexed by render's TextureHandle.
Backend :: struct {
  gctx:           GPUContext,
  swapchain:      Swapchain,
  textures:       []Image,
  samplers:       [SamplerType]vk.Sampler,
  // set 1 of every pipeline that asks: the global texture, sampler, storage image, draw list
  // and pyramid counter arrays (textures.odin)
  bindless_layout: vk.DescriptorSetLayout,
  bindless_set:   vk.DescriptorSet,
  // what rhi's handles name (rhi.odin)
  rhi:            RhiState,
}

// WindowHandle is the window render draws into.
WindowHandle :: glfw.WindowHandle

// init brings Vulkan up on window: instance, surface, device, swapchain and the bindless
// arrays. Paired with shutdown.
init :: proc(b: ^Backend, app_name: string, window: WindowHandle, framebuffer_size: [2]u32) -> bool {
  return check(init_vulkan(b, app_name, window, framebuffer_size), "Vulkan init")
}

// Logs a failed result; the bool is what render sees.
@(private)
check :: proc(res: vk.Result, what: string) -> bool {
  if res != .SUCCESS do log.errorf("%s failed: %v", what, res)
  return res == .SUCCESS
}

@(private = "file")
init_vulkan :: proc(b: ^Backend, app_name: string, window: glfw.WindowHandle, framebuffer_size: [2]u32) -> vk.Result {
  if !glfw.VulkanSupported() {
    log.errorf("GLFW: Vulkan Not Supported")
    return .ERROR_INITIALIZATION_FAILED
  }
  gctx := &b.gctx
  name := strings.clone_to_cstring(app_name, context.temp_allocator)
  instance_init(gctx, name, glfw.GetRequiredInstanceExtensions(), rawptr(glfw.GetInstanceProcAddress)) or_return
  glfw.CreateWindowSurface(gctx.instance, window, nil, &gctx.surface) or_return
  device_init(gctx) or_return
  swapchain_init(&b.swapchain, gctx, framebuffer_size) or_return
  b.textures = make([]Image, rhi.MAX_TEXTURES)
  init_descriptor_pool(gctx) or_return
  bindless_init(b) or_return
  return .SUCCESS
}

// The pool of the one set the backend itself makes, the bindless arrays; rhi's bind groups
// have a pool of their own.
@(private = "file")
init_descriptor_pool :: proc(gctx: ^GPUContext) -> vk.Result {
  sizes := make([dynamic]vk.DescriptorPoolSize, context.temp_allocator)
  for binding in BINDLESS_BINDINGS {
    found := false
    for &s in sizes do if s.type == binding.type {
      s.descriptorCount += binding.count
      found = true
    }
    if !found do append(&sizes, vk.DescriptorPoolSize{binding.type, binding.count})
  }
  return descriptor_pool_init(gctx, sizes[:], 1)
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
  for &img in b.textures do image_destroy(gctx.device, &img)
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
