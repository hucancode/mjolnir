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





// Single-variant pipelines; the others are indexed by MaterialType, LightType and effect.
@(private)
PipelineId :: enum {
  CULL,
  DEPTH_REDUCE,
  SHADOW_DEPTH,
  PARTICLE_EMIT,
  PARTICLE_SIMULATE,
  PARTICLE_DRAW,
  DEBUG_LINE,
  OVERLAY,
}

// Backend is every Vulkan object the renderer draws with. render keeps it opaque and goes
// through the procs below; textures are indexed by render's TextureHandle.
Backend :: struct {
  gctx:                    GPUContext,
  swapchain:               Swapchain,
  command_buffers:         [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  compute_command_buffers: [FRAMES_IN_FLIGHT]vk.CommandBuffer,
  scene:                   SceneDescriptors,
  pipelines:               [PipelineId]vk.Pipeline,
  material_pipelines:      [rhi.MaterialType]vk.Pipeline,
  light_pipelines:         [rhi.LightType]vk.Pipeline,
  // [is_last][tag]: every pass writes an HDR ring image but the last, which writes the
  // swapchain format
  post_process_pipelines:  [2][len(EFFECTS)]vk.Pipeline,
  textures:                []Image,
  samplers:                [SamplerType]vk.Sampler,
  mesh_buffers:            [rhi.MeshStream]Buffer,
  // one copy of every table render writes per frame in flight, at table_offset of its
  // binding; the other bindings have no table (size 0)
  frame_arena:             [FRAMES_IN_FLIGHT]Buffer,
  table_offset:            [SceneBinding]int,
  table_size:              [SceneBinding]int,
  // per table, per copy: regions render wrote since the copy was last brought up to date
  table_stale:             [rhi.Table][FRAMES_IN_FLIGHT]u64,
  draw_count_readback:     [FRAMES_IN_FLIGHT]Buffer,
  // per pyramid slot: groups done this dispatch; the last one resets it
  pyramid_counters:        Buffer,
  // alive list: an indirect draw header followed by one particle index per vertex
  particle_buffer:         Buffer,
  particle_alive_buffer:   Buffer,
  shadow_atlas:            [FRAMES_IN_FLIGHT]Image,
  // indirect draw lists per bindless draw-list slot (pass_occlusion_culling.odin), each of
  // draws per list
  draw_lists:              [MAX_DRAW_LIST_SLOTS]Buffer,
  draw_list_capacity:      [MAX_DRAW_LIST_SLOTS]u32,
  // per pyramid slot: the storage view per mip and whether they are in the storage image array yet
  pyramid_views:           [MAX_PYRAMID_SLOTS][MAX_DEPTH_MIPS_LEVEL]vk.ImageView,
  pyramid_bound:           [MAX_PYRAMID_SLOTS]bool,
  ui_vertex_buffers:       [FRAMES_IN_FLIGHT]Buffer,
  ui_index_buffers:        [FRAMES_IN_FLIGHT]Buffer,
  // what rhi's handles name (rhi.odin)
  rhi:                     RhiState,
}

// WindowHandle is the window render draws into.
WindowHandle :: glfw.WindowHandle

// init brings Vulkan up on window: instance, surface, device, swapchain, the frame arena
// holding `table_size` bytes per table, the mesh buffers of `mesh_size` bytes per
// stream, and every pipeline. Paired with shutdown.
init :: proc(
  b: ^Backend,
  app_name: string,
  window: WindowHandle,
  framebuffer_size: [2]u32,
  table_size: [rhi.Table]int,
  mesh_size: [rhi.MeshStream]int,
) -> bool {
  return check(init_vulkan(b, app_name, window, framebuffer_size, table_size, mesh_size), "Vulkan init")
}

// Logs a failed result; the bool is what render sees.
@(private)
check :: proc(res: vk.Result, what: string) -> bool {
  if res != .SUCCESS do log.errorf("%s failed: %v", what, res)
  return res == .SUCCESS
}

@(private = "file")
init_vulkan :: proc(
  b: ^Backend,
  app_name: string,
  window: glfw.WindowHandle,
  framebuffer_size: [2]u32,
  table_size: [rhi.Table]int,
  mesh_size: [rhi.MeshStream]int,
) -> vk.Result {
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
  init_descriptor_pool(gctx) or_return
  b.textures = make([]Image, rhi.MAX_TEXTURES)
  allocate_command_buffer(gctx, b.command_buffers[:]) or_return
  allocate_command_buffer(gctx, b.compute_command_buffers[:], gctx.compute_command_pool) or_return
  for &buffer, s in b.mesh_buffers {
    buffer = buffer_create(gctx, vk.DeviceSize(mesh_size[s]), MESH_STREAM_USAGE[s], host_visible = false) or_return
  }
  init_scene_buffers(b, table_size) or_return
  bindless_init(b) or_return
  scene_descriptors_init(b) or_return
  occlusion_init(b) or_return
  shadow_init(b) or_return
  direct_light_init(b) or_return
  material_pipelines_init(b) or_return
  particles_init(b) or_return
  post_process_init(b) or_return
  debug_line_init(b) or_return
  overlay_init(b) or_return
  return .SUCCESS
}

@(private = "file")
MESH_STREAM_USAGE := [rhi.MeshStream]vk.BufferUsageFlags {
  .VERTEX   = {.VERTEX_BUFFER},
  .INDEX    = {.INDEX_BUFFER},
  .SKINNING = {.STORAGE_BUFFER},
}

@(private = "file")
init_descriptor_pool :: proc(gctx: ^GPUContext) -> vk.Result {
  sizes := make([dynamic]vk.DescriptorPoolSize, context.temp_allocator)
  add :: proc(sizes: ^[dynamic]vk.DescriptorPoolSize, type: vk.DescriptorType, count: u32) {
    for &s in sizes do if s.type == type {s.descriptorCount += count; return}
    append(sizes, vk.DescriptorPoolSize{type, count})
  }
  for type in SCENE_BINDING_TYPES do add(&sizes, type, FRAMES_IN_FLIGHT)
  for b in BINDLESS_BINDINGS do add(&sizes, b.type, b.count)
  return descriptor_pool_init(gctx, sizes[:], FRAMES_IN_FLIGHT + 1)
}

// Every table is aligned to the device's storage buffer offset alignment.
@(private = "file")
init_scene_buffers :: proc(b: ^Backend, table_size: [rhi.Table]int) -> vk.Result {
  gctx := &b.gctx
  alignment := int(gctx.device_properties.limits.minStorageBufferOffsetAlignment)
  arena_size: int
  for size, t in table_size {
    arena_size = mem.align_forward_int(arena_size, alignment)
    b.table_offset[TABLE_BINDING[t]] = arena_size
    b.table_size[TABLE_BINDING[t]] = size
    arena_size += size
  }
  for &arena in b.frame_arena {
    arena = buffer_create(gctx, vk.DeviceSize(arena_size), {.STORAGE_BUFFER}, host_cached = true) or_return
    mem.zero(arena.mapped, int(arena.size))
  }
  for &readback in b.draw_count_readback {
    readback = buffer_create(gctx, DRAW_LIST_HEADER * size_of(u32), {.TRANSFER_DST}) or_return
  }
  b.pyramid_counters = buffer_create(gctx, MAX_PYRAMID_SLOTS * size_of(u32), {.STORAGE_BUFFER}, host_visible = false) or_return
  queue_buffer_fill(gctx, &b.pyramid_counters)
  particles_init_buffers(b) or_return
  for &atlas in b.shadow_atlas do atlas = shadow_atlas_create(gctx, 1) or_return
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
  for &img in b.textures do image_destroy(gctx.device, &img)
  delete(b.textures)
  for &buf in b.draw_lists do buffer_destroy(gctx.device, &buf)
  for views in b.pyramid_views do for v in views do vk.DestroyImageView(gctx.device, v, nil)
  for p in b.pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  for p in b.material_pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  for p in b.light_pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  for pipelines in b.post_process_pipelines do for p in pipelines do vk.DestroyPipeline(gctx.device, p, nil)
  for i in 0 ..< FRAMES_IN_FLIGHT {
    buffer_destroy(gctx.device, &b.ui_vertex_buffers[i])
    buffer_destroy(gctx.device, &b.ui_index_buffers[i])
  }
  scene_descriptors_shutdown(&b.scene, gctx)
  bindless_shutdown(b)
  for &arena in b.frame_arena do buffer_destroy(gctx.device, &arena)
  for &readback in b.draw_count_readback do buffer_destroy(gctx.device, &readback)
  for &atlas in b.shadow_atlas do image_destroy(gctx.device, &atlas)
  buffer_destroy(gctx.device, &b.pyramid_counters)
  buffer_destroy(gctx.device, &b.particle_buffer)
  buffer_destroy(gctx.device, &b.particle_alive_buffer)
  for &buf in b.mesh_buffers do buffer_destroy(gctx.device, &buf)
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

// mesh_write uploads data at element `first` of stream's buffer before the next frame.
mesh_write :: proc(b: ^Backend, stream: rhi.MeshStream, data: []$T, first: u32) -> bool {
  return check(queue_buffer_write(&b.gctx, &b.mesh_buffers[stream], data, int(first)), "Mesh upload")
}

// draw_count is the PBR draws the main camera's cull of frame_index wrote.
draw_count :: proc(b: ^Backend, frame_index: u32) -> u32 {
  return mapped(&b.draw_count_readback[frame_index], u32)[rhi.MaterialType.PBR]
}

// frame records, submits and presents the frame render described. Once submitted it waits
// until the next frame's copy of the tables is free. RESIZE: the swapchain is out of date.
frame :: proc(b: ^Backend, desc: ^rhi.FrameDesc) -> (submitted: bool, status: rhi.FrameStatus) {
  gctx := &b.gctx
  frame_index := u32(gctx.frame_serial % FRAMES_IN_FLIGHT)
  tables_sync(b, desc, frame_index)
  copy(mapped(&b.ui_vertex_buffers[frame_index], rhi.Vertex2D), desc.ui_vertices)
  copy(mapped(&b.ui_index_buffers[frame_index], u32), desc.ui_indices)
  for &cam in desc.live_cameras do occlusion_bind_pyramid(b, cam.slot)
  sc := &b.swapchain
  res := shadow_atlas_reserve(b, frame_index, desc.shadow_view_count)
  if res == .SUCCESS do res = acquire_next_image(gctx.device, sc, frame_index)
  if res == .SUCCESS do res = record_frame(b, desc, frame_index)
  if res == .SUCCESS {
    serial := gctx.frame_serial
    res = submit_queue_and_present(gctx, sc, b.command_buffers[frame_index], b.compute_command_buffers[frame_index])
    // submitted, even when presenting failed
    submitted = gctx.frame_serial != serial
    if submitted {
      if waited := wait_frame(gctx); waited != .SUCCESS do res = waited
    }
  }
  if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR do return submitted, .RESIZE
  if res != .SUCCESS {
    log.errorf("Error during rendering %v", res)
    return submitted, .ERROR
  }
  return submitted, .OK
}
