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
  surface_view_format:        wgpu.TextureFormat,
  surface_extent:             [2]u32,
  frame_serial:               u64,
  // what init was given, for finishing once the device arrives
  pending:                    struct {
    table_size:       [rhi.Table]int,
    mesh_size:        [rhi.MeshStream]int,
    framebuffer_size: [2]u32,
  },
  // the device is up and every resource made; failed: it never will be
  up, failed:                 bool,
  context_:                   runtime.Context,
  table_buffers:              [rhi.Table]wgpu.Buffer,
  mesh_buffers:               [rhi.MeshStream]wgpu.Buffer,
  textures:                   []Texture,
  white, black_cube:          Texture,
  samplers:                   [SamplerType]wgpu.Sampler,
  scene_layouts:              [ScenePass]wgpu.BindGroupLayout,
  scene_groups:               [ScenePass]wgpu.BindGroup,
  group_layouts:              [GroupLayout]wgpu.BindGroupLayout,
  groups:                     map[GroupKey]wgpu.BindGroup,
  // bind groups made for this frame, released once it is submitted
  frame_groups:               [dynamic]wgpu.BindGroup,
  frame_layout:               wgpu.BindGroupLayout,
  frame_group:                wgpu.BindGroup,
  uniform_buffer:             wgpu.Buffer,
  // this frame's uniforms so far (uniform), written to uniform_buffer before submission
  uniforms:                   []u8,
  uniform_cursor:             int,
  mipgen_layout:              wgpu.BindGroupLayout,
  mipgen_pipelines:           [dynamic]MipgenPipeline,
  // by MaterialType
  material_pipelines:         [len(rhi.MaterialType)]wgpu.RenderPipeline,
  light_pipelines:            [rhi.LightType]wgpu.RenderPipeline,
  // [is_last][tag]: every pass writes an HDR texture but the last, which presents
  post_pipelines:             [2][EFFECT_COUNT]wgpu.RenderPipeline,
  shadow_pipeline:            wgpu.RenderPipeline,
  overlay_pipeline:           wgpu.RenderPipeline,
  debug_line_pipelines:       [2]wgpu.RenderPipeline,
  particle_emit_pipeline:     wgpu.ComputePipeline,
  particle_simulate_pipeline: wgpu.ComputePipeline,
  particle_draw_pipeline:     wgpu.RenderPipeline,
  cull_layout:                wgpu.BindGroupLayout,
  cull_pipeline:              wgpu.ComputePipeline,
  // [from_depth]: mip 0 reduces the depth image, the others the mip above
  reduce_layouts:             [2]wgpu.BindGroupLayout,
  reduce_pipelines:           [2]wgpu.ComputePipeline,
  finalize_pipeline:          wgpu.ComputePipeline,
  draw_lists:                 [MAX_DRAW_LIST_SLOTS]DrawList,
  // cull and pyramid bind groups, kept until a texture or draw list they name changes
  cull_groups:                map[CullKey]wgpu.BindGroup,
  reduce_groups:              map[ReduceKey]wgpu.BindGroup,
  draw_count_readback:        [3]DrawCountReadback,
  draw_count_value:           u32,
  // per pyramid slot: a view per mip
  pyramid_views:              [MAX_PYRAMID_SLOTS][MAX_DEPTH_MIPS]wgpu.TextureView,
  shadow_atlas:               ShadowAtlas,
  // alive list: an indirect draw header followed by one particle index per instance
  particle_buffer:            wgpu.Buffer,
  particle_alive_buffer:      wgpu.Buffer,
  ui_vertex_buffer:           wgpu.Buffer,
  ui_index_buffer:            wgpu.Buffer,
  // what rhi's handles name (rhi.odin)
  rhi:                        RhiState,
}

// init brings WebGPU up on window: instance, surface, then adapter and device, which the web
// hands over asynchronously; once they are there it makes the table buffers of `table_size`
// bytes, the mesh buffers of `mesh_size` bytes per stream, and every pipeline (ready). Paired
// with shutdown.
init :: proc(
  b: ^Backend,
  app_name: string,
  window: WindowHandle,
  framebuffer_size: [2]u32,
  table_size: [rhi.Table]int,
  mesh_size: [rhi.MeshStream]int,
) -> bool {
  b.context_ = context
  b.pending = {table_size, mesh_size, framebuffer_size}
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
  // default 128 MiB, and a stage binds at most the default 8 storage buffers
  wgpu.AdapterRequestDevice(
    adapter,
    &{
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
  surface_configure(b, b.pending.framebuffer_size)
  b.textures = make([]Texture, rhi.MAX_TEXTURES)
  tables_init(b, b.pending.table_size, b.pending.mesh_size)
  particles_init_buffers(b)
  samplers_init(b)
  layouts_init(b)
  cull_init(b)
  scene_groups_init(b)
  defaults_init(b)
  material_pipelines_init(b)
  lighting_init(b)
  shadow_init(b)
  particles_init(b)
  post_process_init(b)
  debug_line_init(b)
  overlay_init(b)
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
  wgpu.SurfaceConfigure(
    b.surface,
    &{
      device = b.device,
      format = b.surface_format,
      usage = {.RenderAttachment},
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
    texture_release(&b.white)
    texture_release(&b.black_cube)
    groups_clear(b)
    shadow_atlas_release(&b.shadow_atlas)
    for slot in 0 ..< u32(MAX_DRAW_LIST_SLOTS) do draw_list_destroy(b, slot)
    for slot in 0 ..< u32(MAX_PYRAMID_SLOTS) do pyramid_destroy(b, slot)
    for buffer in b.table_buffers do wgpu.BufferRelease(buffer)
    for buffer in b.mesh_buffers do wgpu.BufferRelease(buffer)
    buffers := [?]wgpu.Buffer {
      b.particle_buffer, b.particle_alive_buffer,
      b.ui_vertex_buffer, b.ui_index_buffer, b.uniform_buffer,
    }
    for buffer in buffers do wgpu.BufferRelease(buffer)
    for r in b.draw_count_readback do wgpu.BufferRelease(r.buffer)
    for p in b.material_pipelines do wgpu.RenderPipelineRelease(p)
    for p in b.light_pipelines do wgpu.RenderPipelineRelease(p)
    for pipelines in b.post_pipelines do for p in pipelines do wgpu.RenderPipelineRelease(p)
    for p in b.debug_line_pipelines do wgpu.RenderPipelineRelease(p)
    for p in b.mipgen_pipelines do wgpu.RenderPipelineRelease(p.pipeline)
    for p in b.reduce_pipelines do wgpu.ComputePipelineRelease(p)
    render_pipelines := [?]wgpu.RenderPipeline{b.shadow_pipeline, b.overlay_pipeline, b.particle_draw_pipeline}
    for p in render_pipelines do wgpu.RenderPipelineRelease(p)
    compute_pipelines := [?]wgpu.ComputePipeline{b.cull_pipeline, b.finalize_pipeline, b.particle_emit_pipeline, b.particle_simulate_pipeline}
    for p in compute_pipelines do wgpu.ComputePipelineRelease(p)
    for g in b.scene_groups do wgpu.BindGroupRelease(g)
    wgpu.BindGroupRelease(b.frame_group)
    for l in b.scene_layouts do wgpu.BindGroupLayoutRelease(l)
    for l in b.group_layouts do wgpu.BindGroupLayoutRelease(l)
    for l in b.reduce_layouts do wgpu.BindGroupLayoutRelease(l)
    layouts := [?]wgpu.BindGroupLayout{b.frame_layout, b.cull_layout, b.mipgen_layout}
    for l in layouts do if l != nil do wgpu.BindGroupLayoutRelease(l)
    for s in b.samplers do wgpu.SamplerRelease(s)
    wgpu.SurfaceUnconfigure(b.surface)
    wgpu.QueueRelease(b.queue)
    wgpu.DeviceRelease(b.device)
  }
  delete(b.textures)
  delete(b.groups)
  delete(b.frame_groups)
  delete(b.mipgen_pipelines)
  delete(b.cull_groups)
  delete(b.reduce_groups)
  delete(b.uniforms)
  if b.adapter != nil do wgpu.AdapterRelease(b.adapter)
  if b.surface != nil do wgpu.SurfaceRelease(b.surface)
  if b.instance != nil do wgpu.InstanceRelease(b.instance)
}

// wait_idle does nothing: WebGPU destroys nothing submitted work still uses.
wait_idle :: proc(b: ^Backend) {}

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

// Writes this frame's uniforms and starts the next frame's at the front.
@(private)
uniforms_flush :: proc(b: ^Backend) {
  if b.uniform_cursor == 0 do return
  wgpu.QueueWriteBuffer(b.queue, b.uniform_buffer, 0, raw_data(b.uniforms), uint(b.uniform_cursor))
  b.uniform_cursor = 0
}
