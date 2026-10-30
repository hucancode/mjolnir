package wgpu_backend

import rhi "../rhi"

import "base:runtime"
import "core:log"
import wgpu "vendor:wgpu"

// FRAMES_IN_FLIGHT is the copies render keeps of per-frame resources: one, since queue order
// serializes every frame and WriteBuffer copies at once.
FRAMES_IN_FLIGHT :: 1
// RETIRE_GRACE is the frames a freed resource or pool slot waits before it is destroyed or
// reused: WebGPU keeps destroyed objects alive for submitted work and orders uploads after it.
RETIRE_GRACE :: 1
// Textures reach shaders through bind groups, not global arrays, and a pass renders into one
// layer.
BINDLESS :: false




// Backend is every WebGPU object the renderer draws with. render keeps it opaque and goes
// through the procs below; textures are indexed by render's TextureHandle.
Backend :: struct {
  instance:                   wgpu.Instance,
  adapter:                    wgpu.Adapter,
  device:                     wgpu.Device,
  queue:                      wgpu.Queue,
  surface:                    wgpu.Surface,
  // the surface's format, and the sRGB view of it every pass presents through
  surface_format:             wgpu.TextureFormat,
  // the surface is a copy source (rhi.Caps.backbuffer_copy)
  surface_copy:               bool,
  surface_view_format:        wgpu.TextureFormat,
  surface_extent:             [2]u32,
  frame_serial:               u64,
  // the device took indirect-first-instance (rhi.Caps.indirect_first_instance)
  indirect_first_instance:    bool,
  // the window init was given
  window:                     WindowHandle,
  // the device is up and every resource made; failed: it never will be
  up, failed:                 bool,
  context_:                   runtime.Context,
  textures:                   []Texture,
  samplers:                   [rhi.SamplerType]wgpu.Sampler,
  // the push group (pipeline.odin): its layout, group and the uniform ring
  frame_layout:               wgpu.BindGroupLayout,
  frame_group:                wgpu.BindGroup,
  uniform_buffer:             wgpu.Buffer,
  // the ring's entries so far this frame (rhi_cmd_push), written to uniform_buffer on submission
  uniforms:                   []u8,
  uniform_cursor:             int,
  mipgen_layout:              wgpu.BindGroupLayout,
  mipgen_pipelines:           [dynamic]MipgenPipeline,
  // what rhi handles name (rhi.Pool: index 0 is none, released slots are reused)
  buffers:                    rhi.Pool(wgpu.Buffer),
  layouts:                    rhi.Pool(wgpu.BindGroupLayout),
  groups:                     rhi.Pool(Group),
  pipelines:                  rhi.Pool(Pipeline),
  // the frame frame_begin acquired
  surface_texture:            wgpu.Texture,
  surface_output:             wgpu.TextureView,
  // bytes of the uniform ring already written to the queue this frame
  flushed:                    int,
  // READBACK buffers by handle
  readbacks:                  map[rhi.Buffer]Readback,
  // the command lists being recorded or awaiting submission; an encoder marks one taken
  cmds:                       [MAX_CMDS]Cmd,
}

// init brings WebGPU up on window, which has no bindless arrays: instance, surface, then adapter and device, which the web
// hands over asynchronously; once they are there it makes the samplers and the push group
// (ready). Paired with shutdown.
init :: proc(b: ^Backend, window: WindowHandle, _: [rhi.BindlessArray]u32) -> bool {
  b.context_ = context
  b.window = window
  b.instance = wgpu.CreateInstance(nil)
  if b.instance == nil {
    log.errorf("WebGPU: no instance")
    return false
  }
  b.surface = surface_create(b.instance, window)
  wgpu.InstanceRequestAdapter(
    b.instance,
    &{compatibleSurface = b.surface, powerPreference = .HighPerformance},
    {mode = .AllowProcessEvents, callback = on_adapter, userdata1 = b},
  )
  // natively the device arrives while we pump; on the web after init returns
  device_wait(b)
  return !b.failed
}

@(private = "file")
on_adapter :: proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: wgpu.StringView, userdata1, userdata2: rawptr) {
  b := cast(^Backend)userdata1
  context = b.context_
  if status != .Success {
    log.errorf("WebGPU adapter request failed: %v %s", status, message)
    b.failed = true
    return
  }
  b.adapter = adapter
  // core WebGPU's default limits fit: the largest storage binding (the vertex buffer) is the
  // default 128 MiB, and a stage binds at most the default 8 storage buffers. Indirect first
  // instance lets batches of a material share one instance stream binding.
  features: [1]wgpu.FeatureName
  feature_count := 0
  if wgpu.AdapterHasFeature(adapter, .IndirectFirstInstance) {
    features[0] = .IndirectFirstInstance
    feature_count = 1
  }
  wgpu.AdapterRequestDevice(
    adapter,
    &{
      requiredFeatureCount = uint(feature_count),
      requiredFeatures = raw_data(features[:]),
      uncapturedErrorCallbackInfo = {callback = on_error, userdata1 = b},
      deviceLostCallbackInfo = {mode = .AllowProcessEvents, callback = on_lost, userdata1 = b},
    },
    {mode = .AllowProcessEvents, callback = on_device, userdata1 = b},
  )
}

@(private = "file")
on_device :: proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: wgpu.StringView, userdata1, userdata2: rawptr) {
  b := cast(^Backend)userdata1
  context = b.context_
  if status != .Success {
    log.errorf("WebGPU device request failed: %v %s", status, message)
    b.failed = true
    return
  }
  b.device = device
  b.queue = wgpu.DeviceGetQueue(device)
  b.indirect_first_instance = bool(wgpu.DeviceHasFeature(device, .IndirectFirstInstance))
  log.infof("WebGPU indirect first instance: %v", b.indirect_first_instance)
  resources_init(b)
  b.up = true
}

@(private = "file")
on_error :: proc "c" (device: ^wgpu.Device, type: wgpu.ErrorType, message: wgpu.StringView, userdata1, userdata2: rawptr) {
  b := cast(^Backend)userdata1
  context = b.context_
  log.errorf("WebGPU %v error: %s", type, message)
}

@(private = "file")
on_lost :: proc "c" (device: ^wgpu.Device, reason: wgpu.DeviceLostReason, message: wgpu.StringView, userdata1, userdata2: rawptr) {
  b := cast(^Backend)userdata1
  context = b.context_
  if reason != .Destroyed && reason != .CallbackCancelled do log.errorf("WebGPU device lost: %v %s", reason, message)
}

// Everything but the device: made once it arrives.
@(private = "file")
resources_init :: proc(b: ^Backend) {
  size, _ := window_size(b)
  surface_configure(b, size)
  b.textures = make([]Texture, rhi.MAX_TEXTURES)
  samplers_init(b)
  frame_group_init(b)
}

// ready reports whether the device is up and init has finished.
ready :: proc(b: ^Backend) -> bool {
  return b.up
}

// Picks the surface's format with an sRGB view of it, as on the web, and configures it at size.
@(private)
surface_configure :: proc(b: ^Backend, size: [2]u32) {
  caps, _ := wgpu.SurfaceGetCapabilities(b.surface, b.adapter)
  defer wgpu.SurfaceCapabilitiesFreeMembers(caps)
  b.surface_format = .BGRA8Unorm
  for format in caps.formats[:caps.formatCount] {
    if format == .BGRA8Unorm || format == .RGBA8Unorm {
      b.surface_format = format
      break
    }
  }
  b.surface_view_format = .BGRA8UnormSrgb if b.surface_format == .BGRA8Unorm else .RGBA8UnormSrgb
  b.surface_extent = {max(size.x, 1), max(size.y, 1)}
  b.surface_copy = .CopySrc in caps.usages
  wgpu.SurfaceConfigure(
    b.surface,
    &{
      device = b.device,
      format = b.surface_format,
      usage = {.RenderAttachment, .CopySrc} if b.surface_copy else {.RenderAttachment},
      width = b.surface_extent.x,
      height = b.surface_extent.y,
      viewFormatCount = 1,
      viewFormats = &b.surface_view_format,
      alphaMode = .Opaque,
      presentMode = .Fifo,
    },
  )
}

// shutdown releases every WebGPU object, textures included.
shutdown :: proc(b: ^Backend) {
  if b.up {
    for &t in b.textures do texture_release(&t)
    rhi_shutdown(b)
    for p in b.mipgen_pipelines do wgpu.RenderPipelineRelease(p.pipeline)
    wgpu.BindGroupRelease(b.frame_group)
    wgpu.BufferRelease(b.uniform_buffer)
    layouts := [?]wgpu.BindGroupLayout{b.frame_layout, b.mipgen_layout}
    for l in layouts do if l != nil do wgpu.BindGroupLayoutRelease(l)
    for s in b.samplers do wgpu.SamplerRelease(s)
    wgpu.SurfaceUnconfigure(b.surface)
    wgpu.QueueRelease(b.queue)
    wgpu.DeviceRelease(b.device)
  }
  delete(b.textures)
  delete(b.mipgen_pipelines)
  delete(b.uniforms)
  if b.adapter != nil do wgpu.AdapterRelease(b.adapter)
  if b.surface != nil do wgpu.SurfaceRelease(b.surface)
  if b.instance != nil do wgpu.InstanceRelease(b.instance)
}

// wait_idle waits for submitted work and fires its callbacks, so READBACK buffers hold the last
// frame (natively; the browser cannot block).
wait_idle :: proc(b: ^Backend) {
  if b.up do device_idle(b)
}

// tick does nothing: WebGPU retires what is freed on its own.
tick :: proc(b: ^Backend) {}

// frame_serial is the number of frames submitted so far.
frame_serial :: proc(b: ^Backend) -> u64 {
  return b.frame_serial
}

// extent is the surface size in pixels.
extent :: proc(b: ^Backend) -> [2]u32 {
  return b.surface_extent
}

// resize reconfigures the surface at framebuffer_size.
resize :: proc(b: ^Backend, framebuffer_size: [2]u32) -> bool {
  surface_configure(b, framebuffer_size)
  return true
}

