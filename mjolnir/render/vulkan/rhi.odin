package vulkan_backend

import rhi "../rhi"

import "base:intrinsics"
import "core:log"
import "core:math"
import "core:strings"
import vk "vendor:vulkan"

// The backend's half of rhi's explicit contract (rhi/device.odin): PROCS is the conformance
// check, every proc below is one of its fields. Nothing here decides: a barrier is the one the
// caller recorded, a submission waits on what the caller named, and bindless, push constants,
// indirect count and layered rendering are exposed through rhi.Caps as they are.

PROCS :: rhi.Procs(Backend, WindowHandle) {
  init                            = init,
  ready                           = ready,
  shutdown                        = shutdown,
  wait_idle                       = wait_idle,
  tick                            = tick,
  frame_serial                    = frame_serial,
  extent                          = extent,
  resize                          = resize,
  caps                            = rhi_caps,
  texture_create                  = texture_create,
  texture_destroy                 = texture_destroy,
  buffer_create                   = rhi_buffer_create,
  buffer_retire                   = rhi_buffer_retire,
  buffer_write                    = rhi_buffer_write,
  bindless_write                  = rhi_bindless_write,
  buffer_read                     = rhi_buffer_read,
  bind_layout_create              = rhi_bind_layout_create,
  bind_group_create               = rhi_bind_group_create,
  bind_group_retire               = rhi_bind_group_retire,
  compute_pipeline_create         = rhi_compute_pipeline_create,
  graphics_pipeline_create        = rhi_graphics_pipeline_create,
  pipeline_retire                 = rhi_pipeline_retire,
  frame_wait                      = rhi_frame_wait,
  frame_begin                     = rhi_frame_begin,
  submit                          = rhi_submit,
  frame_present                   = rhi_frame_present,
  frame_timings                   = rhi_frame_timings,
  cmd_begin                       = rhi_cmd_begin,
  cmd_end                         = rhi_cmd_end,
  cmd_flush_uploads               = rhi_cmd_flush_uploads,
  cmd_begin_pass                  = rhi_cmd_begin_pass,
  cmd_end_pass                    = rhi_cmd_end_pass,
  cmd_begin_compute               = rhi_cmd_begin_compute,
  cmd_end_compute                 = rhi_cmd_end_compute,
  cmd_label_begin                 = rhi_cmd_label_begin,
  cmd_label_end                   = rhi_cmd_label_end,
  cmd_bind_pipeline               = rhi_cmd_bind_pipeline,
  cmd_bind_group                  = rhi_cmd_bind_group,
  cmd_bind_bindless               = rhi_cmd_bind_bindless,
  cmd_push                        = rhi_cmd_push,
  cmd_set_scissor                 = rhi_cmd_set_scissor,
  cmd_bind_vertex                 = rhi_cmd_bind_vertex,
  cmd_bind_index                  = rhi_cmd_bind_index,
  cmd_draw                        = rhi_cmd_draw,
  cmd_draw_indexed                = rhi_cmd_draw_indexed,
  cmd_draw_indirect               = rhi_cmd_draw_indirect,
  cmd_draw_indexed_indirect       = rhi_cmd_draw_indexed_indirect,
  cmd_draw_indexed_indirect_count = rhi_cmd_draw_indexed_indirect_count,
  cmd_dispatch                    = rhi_cmd_dispatch,
  cmd_fill_buffer                 = rhi_cmd_fill_buffer,
  cmd_copy_buffer                 = rhi_cmd_copy_buffer,
  cmd_barrier                     = rhi_cmd_barrier,
}

// Sets for bind groups: rhi's own pool, apart from the scene pool.
@(private = "file")
RHI_MAX_SETS :: 4096

@(private = "file")
PUSH_STAGES :: vk.ShaderStageFlags{.VERTEX, .FRAGMENT, .COMPUTE}

// Sets a pipeline layout may have, the bindless arrays included.
@(private = "file")
MAX_PIPELINE_SETS :: 8

// A pipeline layout is what makes it: pipelines of the same interface share one, so the sets
// bound for one stay bound for the next.
@(private)
PipelineLayoutKey :: struct {
  sets:      [MAX_PIPELINE_SETS]vk.DescriptorSetLayout,
  count:     u32,
  push_size: u32,
}

// Timed label scopes per frame slot; two timestamps each.
@(private = "file")
MAX_TIMED_SCOPES :: 256

// Label scopes open at once in one list.
@(private = "file")
MAX_LABEL_DEPTH :: 16

// What rhi's handles name (rhi.Pool: index 0 is none, released slots are reused).
@(private)
RhiState :: struct {
  buffers:       rhi.Pool(Buffer),
  layouts:       rhi.Pool(RhiLayout),
  groups:        rhi.Pool(RhiGroup),
  pipelines:     rhi.Pool(RhiPipeline),
  // kept until shutdown: there are a handful
  pipeline_layouts: map[PipelineLayoutKey]vk.PipelineLayout,
  // the views bindless_write made for the storage image array, by index
  storage_views: [MAX_STORAGE_IMAGES]vk.ImageView,
  set_pool:      vk.DescriptorPool,
  // per recording thread, queue and frame slot: the lists' pool, reset whole by frame_wait
  cmd_pools:     [rhi.MAX_RECORD_THREADS][rhi.Queue][FRAMES_IN_FLIGHT]CmdPool,
  // per frame slot: its timed scopes and their timestamps
  timing:        [FRAMES_IN_FLIGHT]TimingSlot,
  // the scopes of the slot frame_wait last waited for
  timings:       [dynamic]rhi.Timing,
  frame_index:   u32,
  // an image is acquired and not yet presented
  acquired:      bool,
  // the backbuffer left UNDEFINED this frame
  backbuffer_in: bool,
  // per queue: the value the next submission signals, and per frame slot the last one signalled
  next_value:    [rhi.Queue]u64,
  slot_value:    [FRAMES_IN_FLIGHT][rhi.Queue]u64,
}

// A thread's lists of one queue and frame slot; `cursor` of them are taken since the reset.
@(private)
CmdPool :: struct {
  pool:   vk.CommandPool,
  lists:  [dynamic]^RhiCmd,
  cursor: int,
}

@(private)
TimingSlot :: struct {
  queries: vk.QueryPool,
  // scopes begun, in any thread; past MAX_TIMED_SCOPES they are not timed
  count:   u32,
  scopes:  [MAX_TIMED_SCOPES]rhi.Timing,
}

@(private)
RhiLayout :: struct {
  set_layout: vk.DescriptorSetLayout,
  kinds:      []rhi.BindKind,
}

@(private)
RhiGroup :: struct {
  set:   vk.DescriptorSet,
  views: [dynamic]vk.ImageView,
}

@(private)
RhiPipeline :: struct {
  pipeline:     vk.Pipeline,
  layout:       vk.PipelineLayout,
  bind_point:   vk.PipelineBindPoint,
  // the set of the bindless arrays, when the layout has them
  bindless_set: u32,
}

// One command list: a command buffer, the pipeline bound on it and the sets bound per bind
// point (graphics, compute), so a set already bound with the same layout is not bound again.
@(private)
RhiCmd :: struct {
  cb:         vk.CommandBuffer,
  pipeline:   ^RhiPipeline,
  queue:      rhi.Queue,
  // renders into the backbuffer: ends in the present layout
  presenting: bool,
  bound:      [2]BoundSets,
  // the frame slot it was begun in, and its open label scopes (their timed index, or
  // MAX_TIMED_SCOPES when untimed)
  slot:       u32,
  labels:     [MAX_LABEL_DEPTH]u32,
  depth:      u32,
}

@(private)
BoundSets :: struct {
  layout: vk.PipelineLayout,
  sets:   [MAX_PIPELINE_SETS]vk.DescriptorSet,
}

// Makes what rhi needs from the start: a timestamp pool per frame slot, when timed.
@(private)
rhi_init :: proc(b: ^Backend) -> vk.Result {
  if !timestamps_supported(&b.gctx) do return .SUCCESS
  info := vk.QueryPoolCreateInfo {
    sType      = .QUERY_POOL_CREATE_INFO,
    queryType  = .TIMESTAMP,
    queryCount = 2 * MAX_TIMED_SCOPES,
  }
  for &t in b.rhi.timing {
    vk.CreateQueryPool(b.gctx.device, &info, nil, &t.queries) or_return
    vk.ResetQueryPool(b.gctx.device, t.queries, 0, 2 * MAX_TIMED_SCOPES)
  }
  return .SUCCESS
}

// Frees what rhi made that shutdown has not: lists, the set pool and the layouts of groups.
@(private)
rhi_shutdown :: proc(b: ^Backend) {
  device := b.gctx.device
  for &thread in b.rhi.cmd_pools do for &queue in thread do for &p in queue {
    for c in p.lists do free(c)
    delete(p.lists)
    if p.pool != 0 do vk.DestroyCommandPool(device, p.pool, nil)
  }
  for t in b.rhi.timing do if t.queries != 0 do vk.DestroyQueryPool(device, t.queries, nil)
  delete(b.rhi.timings)
  for &buf in b.rhi.buffers.items do if buf.buffer != 0 do buffer_destroy(&b.gctx, &buf)
  for view in b.rhi.storage_views do if view != 0 do vk.DestroyImageView(device, view, nil)
  for &g in b.rhi.groups.items {
    for v in g.views do vk.DestroyImageView(device, v, nil)
    delete(g.views)
  }
  if b.rhi.set_pool != 0 do vk.DestroyDescriptorPool(device, b.rhi.set_pool, nil)
  for &l in b.rhi.layouts.items {
    if l.set_layout != 0 do vk.DestroyDescriptorSetLayout(device, l.set_layout, nil)
    delete(l.kinds)
  }
  for &p in b.rhi.pipelines.items do if p.pipeline != 0 do vk.DestroyPipeline(device, p.pipeline, nil)
  for _, layout in b.rhi.pipeline_layouts do vk.DestroyPipelineLayout(device, layout, nil)
  delete(b.rhi.pipeline_layouts)
  rhi.pool_destroy(&b.rhi.buffers)
  rhi.pool_destroy(&b.rhi.layouts)
  rhi.pool_destroy(&b.rhi.groups)
  rhi.pool_destroy(&b.rhi.pipelines)
}

rhi_caps :: proc(b: ^Backend) -> rhi.Caps {
  return {
    bindless = true,
    multi_draw_indirect_count = b.gctx.draw_indirect_count,
    layered_rendering = true,
    explicit_barriers = true,
    async_compute = has_async_compute(&b.gctx),
    indirect_first_instance = true,
    timestamps = timestamps_supported(&b.gctx),
    parallel_recording = true,
  }
}

// Timestamps reset from the CPU, so a slot's scopes are read and reset in frame_wait.
@(private = "file")
timestamps_supported :: proc(gctx: ^GPUContext) -> bool {
  return gctx.host_query_reset && gctx.timestamp_bits[0] > 0 && gctx.device_properties.limits.timestampPeriod > 0
}

rhi_buffer_create :: proc(b: ^Backend, desc: rhi.BufferDesc) -> (rhi.Buffer, bool) {
  usage: vk.BufferUsageFlags
  for u in desc.usage {
    switch u {
    case .STORAGE:  usage += {.STORAGE_BUFFER}
    case .VERTEX:   usage += {.VERTEX_BUFFER}
    case .INDEX:    usage += {.INDEX_BUFFER}
    case .INDIRECT: usage += {.INDIRECT_BUFFER}
    case .COPY_SRC: usage += {.TRANSFER_SRC}
    case .COPY_DST: usage += {.TRANSFER_DST}
    }
  }
  buffer, res := buffer_create(
    &b.gctx,
    vk.DeviceSize(max(desc.size, 16)),
    usage,
    host_visible = desc.memory != .GPU,
    host_cached = desc.memory == .READBACK,
    prefer_device_local = desc.memory == .UPLOAD,
  )
  if !check(res, "rhi buffer") do return 0, false
  slot := rhi.pool_take(&b.rhi.buffers)
  b.rhi.buffers.items[slot] = buffer
  return rhi.Buffer(slot), true
}

// Destroyed RETIRE_GRACE frames on, once no frame in flight reads it.
rhi_buffer_retire :: proc(b: ^Backend, handle: rhi.Buffer) {
  if handle == 0 do return
  defer_destroy(&b.gctx, b.rhi.buffers.items[handle])
  rhi.pool_release(&b.rhi.buffers, u32(handle))
}

rhi_buffer_read :: proc(b: ^Backend, handle: rhi.Buffer, offset: int, dst: []u8) -> bool {
  buffer := &b.rhi.buffers.items[handle]
  if buffer.mapped == nil do return false
  copy(dst, buffer.mapped[offset:][:len(dst)])
  return true
}

// Registers a resource in one of the bindless arrays; the caller guarantees no submitted work
// still reads the entry it replaces.
rhi_bindless_write :: proc(b: ^Backend, array: rhi.BindlessArray, index: u32, resource: rhi.BindResource) {
  set := b.bindless_set
  switch array {
  case .STORAGE_IMAGES:
    view_ref, ok := resource.(rhi.TextureView)
    img := texture_image(b, view_ref.texture) if ok else nil
    if img == nil do return
    old := b.rhi.storage_views[index]
    if old != 0 do defer_destroy(&b.gctx, old)
    view, res := mip_view_create(b, img, u32(max(view_ref.mip, 0)))
    if !check(res, "rhi storage view") do return
    b.rhi.storage_views[index] = view
    write_descriptor(&b.gctx, set, BINDING_STORAGE_IMAGES, index, .STORAGE_IMAGE, vk.DescriptorImageInfo{imageView = view, imageLayout = .GENERAL})
  case .DRAW_LISTS, .PYRAMID_COUNTERS:
    range, ok := resource.(rhi.BufferRange)
    if !ok do return
    buffer := &b.rhi.buffers.items[range.buffer]
    binding: u32 = BINDING_DRAW_LISTS if array == .DRAW_LISTS else BINDING_PYRAMID_COUNTERS
    write_descriptor(&b.gctx, set, binding, index, .STORAGE_BUFFER, buffer_info(buffer))
  }
}

rhi_buffer_write :: proc(b: ^Backend, handle: rhi.Buffer, offset: int, data: []u8) -> bool {
  if len(data) == 0 do return true
  buffer := &b.rhi.buffers.items[handle]
  if buffer.mapped != nil {
    copy(buffer.mapped[offset:][:len(data)], data)
    return true
  }
  return check(queue_buffer_write(&b.gctx, buffer, data, offset), "rhi buffer write")
}

// A view of one mip: a cube's as its six layers, else one 2D level.
@(private = "file")
mip_view_create :: proc(b: ^Backend, img: ^Image, mip: u32) -> (vk.ImageView, vk.Result) {
  if img.cube do return image_create_view(b.gctx.device, img, .D2_ARRAY, mip, 1, 0, 6)
  return image_create_view(b.gctx.device, img, .D2, base_mip = mip)
}

@(private = "file")
shader_stages :: proc(stages: bit_set[rhi.ShaderStage]) -> vk.ShaderStageFlags {
  flags: vk.ShaderStageFlags
  for s in stages {
    switch s {
    case .VERTEX:   flags += {.VERTEX}
    case .FRAGMENT: flags += {.FRAGMENT}
    case .COMPUTE:  flags += {.COMPUTE}
    }
  }
  return flags
}

@(private = "file")
descriptor_type :: proc(kind: rhi.BindKind) -> vk.DescriptorType {
  switch kind {
  case .STORAGE_BUFFER, .STORAGE_BUFFER_READ:
    return .STORAGE_BUFFER
  case .TEXTURE_FLOAT, .TEXTURE_UNFILTERABLE, .TEXTURE_DEPTH, .TEXTURE_CUBE, .TEXTURE_DEPTH_ARRAY:
    return .SAMPLED_IMAGE
  case .STORAGE_TEXTURE, .STORAGE_TEXTURE_ARRAY:
    return .STORAGE_IMAGE
  }
  return .STORAGE_BUFFER
}

rhi_bind_layout_create :: proc(b: ^Backend, desc: rhi.BindLayoutDesc) -> (rhi.BindLayout, bool) {
  bindings := make([]DescriptorBinding, len(desc.entries), context.temp_allocator)
  kinds := make([]rhi.BindKind, len(desc.entries))
  for e, i in desc.entries {
    bindings[i] = {descriptor_type(e.kind), 1, shader_stages(e.stages)}
    kinds[i] = e.kind
  }
  layout, res := create_descriptor_layout(&b.gctx, ..bindings)
  if !check(res, "rhi bind layout") {
    delete(kinds)
    return 0, false
  }
  slot := rhi.pool_take(&b.rhi.layouts)
  b.rhi.layouts.items[slot] = {layout, kinds}
  return rhi.BindLayout(slot), true
}

@(private = "file")
set_pool_get :: proc(b: ^Backend) -> bool {
  if b.rhi.set_pool != 0 do return true
  sizes := [?]vk.DescriptorPoolSize {
    {.STORAGE_BUFFER, RHI_MAX_SETS * 4},
    {.SAMPLED_IMAGE, RHI_MAX_SETS * 8},
    {.STORAGE_IMAGE, RHI_MAX_SETS},
  }
  info := vk.DescriptorPoolCreateInfo {
    sType         = .DESCRIPTOR_POOL_CREATE_INFO,
    flags         = {.FREE_DESCRIPTOR_SET},
    maxSets       = RHI_MAX_SETS,
    poolSizeCount = len(sizes),
    pPoolSizes    = raw_data(sizes[:]),
  }
  return check(vk.CreateDescriptorPool(b.gctx.device, &info, nil, &b.rhi.set_pool), "rhi set pool")
}

rhi_bind_group_create :: proc(b: ^Backend, desc: rhi.BindGroupDesc) -> (rhi.BindGroup, bool) {
  if !set_pool_get(b) do return 0, false
  layout := &b.rhi.layouts.items[desc.layout]
  set: vk.DescriptorSet
  info := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = b.rhi.set_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &layout.set_layout,
  }
  if !check(vk.AllocateDescriptorSets(b.gctx.device, &info, &set), "rhi bind group") do return 0, false
  slot := rhi.pool_take(&b.rhi.groups)
  group := &b.rhi.groups.items[slot]
  group.set = set
  for r, i in desc.resources {
    type := descriptor_type(layout.kinds[i])
    switch v in r {
    case rhi.BufferRange:
      buffer := &b.rhi.buffers.items[v.buffer]
      range := vk.DeviceSize(v.size) if v.size > 0 else buffer.size - vk.DeviceSize(v.offset)
      write_descriptor(&b.gctx, set, u32(i), 0, type, vk.DescriptorBufferInfo{buffer = buffer.buffer, offset = vk.DeviceSize(v.offset), range = range})
    case rhi.TextureView:
      img := texture_image(b, v.texture)
      if img == nil do continue
      view := img.view
      if v.mip >= 0 {
        made, res := mip_view_create(b, img, u32(v.mip))
        if !check(res, "rhi bind group view") do continue
        append(&group.views, made)
        view = made
      }
      write_descriptor(&b.gctx, set, u32(i), 0, type, vk.DescriptorImageInfo{imageView = view, imageLayout = .GENERAL})
    }
  }
  return rhi.BindGroup(slot), true
}

rhi_bind_group_retire :: proc(b: ^Backend, handle: rhi.BindGroup) {
  if handle == 0 do return
  group := &b.rhi.groups.items[handle]
  defer_destroy(&b.gctx, RetiredSet{b.rhi.set_pool, group.set})
  for v in group.views do defer_destroy(&b.gctx, v)
  delete(group.views)
  rhi.pool_release(&b.rhi.groups, u32(handle))
}

// The set layouts of desc, the bindless layout after them when asked, and the push range; made
// once per interface and shared.
@(private = "file")
pipeline_layout_get :: proc(b: ^Backend, desc: rhi.PipelineLayoutDesc) -> (layout: vk.PipelineLayout, bindless_set: u32, ok: bool) {
  key := PipelineLayoutKey{push_size = desc.push_size}
  for l in desc.layouts do if l != rhi.PUSH_GROUP {
    key.sets[key.count] = b.rhi.layouts.items[l].set_layout
    key.count += 1
  }
  bindless_set = key.count
  if desc.bindless {
    key.sets[key.count] = b.bindless_layout
    key.count += 1
  }
  if cached, found := b.rhi.pipeline_layouts[key]; found do return cached, bindless_set, true
  range := vk.PushConstantRange{stageFlags = PUSH_STAGES, size = max(desc.push_size, 4)}
  info := vk.PipelineLayoutCreateInfo {
    sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount         = key.count,
    pSetLayouts            = &key.sets[0],
    pushConstantRangeCount = 1 if desc.push_size > 0 else 0,
    pPushConstantRanges    = &range,
  }
  ok = check(vk.CreatePipelineLayout(b.gctx.device, &info, nil, &layout), "rhi pipeline layout")
  if ok do b.rhi.pipeline_layouts[key] = layout
  return
}

@(private = "file")
pipeline_store :: proc(b: ^Backend, p: RhiPipeline) -> rhi.Pipeline {
  slot := rhi.pool_take(&b.rhi.pipelines)
  b.rhi.pipelines.items[slot] = p
  return rhi.Pipeline(slot)
}

rhi_compute_pipeline_create :: proc(b: ^Backend, desc: rhi.ComputePipelineDesc) -> (rhi.Pipeline, bool) {
  code := desc.shader.spirv.comp
  if len(code) == 0 {
    log.errorf("Compute pipeline without SPIR-V")
    return 0, false
  }
  layout, bindless_set, layout_ok := pipeline_layout_get(b, desc.layout)
  if !layout_ok do return 0, false
  pipeline, res := create_compute_pipeline(&b.gctx, code, layout)
  if !check(res, "rhi compute pipeline") do return 0, false
  return pipeline_store(b, {pipeline, layout, .COMPUTE, bindless_set}), true
}

@(private = "file")
VERTEX_FORMATS := [rhi.VertexFormat]vk.Format {
  .UNORM8X4 = .R8G8B8A8_UNORM,
  .F32X2 = .R32G32_SFLOAT,
  .F32X3 = .R32G32B32_SFLOAT,
  .F32X4 = .R32G32B32A32_SFLOAT,
  .U32   = .R32_UINT,
}

@(private = "file")
TOPOLOGIES := [rhi.Topology]vk.PrimitiveTopology {
  .TRIANGLE_LIST = .TRIANGLE_LIST,
  .LINE_LIST     = .LINE_LIST,
  .POINT_LIST    = .POINT_LIST,
}

@(private = "file")
CULL_MODES := [rhi.CullMode]vk.CullModeFlags {
  .NONE  = {},
  .BACK  = {.BACK},
  .FRONT = {.FRONT},
}

@(private = "file")
COMPARE_OPS := [rhi.CompareOp]vk.CompareOp {
  .LESS_EQUAL    = .LESS_OR_EQUAL,
  .ALWAYS        = .ALWAYS,
  .GREATER       = .GREATER,
  .GREATER_EQUAL = .GREATER_OR_EQUAL,
}

rhi_graphics_pipeline_create :: proc(b: ^Backend, desc: rhi.GraphicsPipelineDesc) -> (rhi.Pipeline, bool) {
  shader := desc.shader.spirv
  if len(shader.vert) == 0 {
    log.errorf("Graphics pipeline without a SPIR-V vertex stage")
    return 0, false
  }
  layout, bindless_set, layout_ok := pipeline_layout_get(b, desc.layout)
  if !layout_ok do return 0, false
  bindings := make([]vk.VertexInputBindingDescription, len(desc.vertex), context.temp_allocator)
  attributes := make([dynamic]vk.VertexInputAttributeDescription, context.temp_allocator)
  for vb, i in desc.vertex {
    bindings[i] = {binding = u32(i), stride = vb.stride, inputRate = .VERTEX if vb.step == .VERTEX else .INSTANCE}
    for a in vb.attributes do append(&attributes, vk.VertexInputAttributeDescription{location = a.location, binding = u32(i), format = VERTEX_FORMATS[a.format], offset = a.offset})
  }
  formats := make([]vk.Format, len(desc.color_formats), context.temp_allocator)
  blend := make([]vk.PipelineColorBlendAttachmentState, len(desc.color_formats), context.temp_allocator)
  for f, i in desc.color_formats {
    formats[i] = b.swapchain.format.format if f == .BACKBUFFER else FORMATS[f]
    switch desc.blend {
    case .NONE:     blend[i] = BLEND_OVERRIDE
    case .ALPHA:    blend[i] = BLEND_ALPHA
    case .ADDITIVE: blend[i] = BLEND_ADDITIVE
    }
  }
  info := GraphicsPipelineDesc {
    vert              = shader.vert,
    frag              = shader.frag,
    vertex_bindings   = bindings,
    vertex_attributes = attributes[:],
    topology          = TOPOLOGIES[desc.topology],
    polygon_mode      = .LINE if desc.wireframe && b.gctx.fill_mode_non_solid else .FILL,
    cull_mode         = CULL_MODES[desc.cull],
    blend             = blend,
    color_formats     = formats,
    layout            = layout,
  }
  if depth, ok := desc.depth.?; ok {
    info.depth = {depthTestEnable = true, depthWriteEnable = b32(depth.write), depthCompareOp = COMPARE_OPS[depth.compare]}
    info.depth_format = .D32_SFLOAT
    info.depth_clamp = b32(depth.clamp && b.gctx.depth_clamp)
    info.depth_bias = {0, depth.slope_bias}
  }
  specialization: vk.SpecializationInfo
  if len(desc.constants) > 0 {
    entries := make([]vk.SpecializationMapEntry, len(desc.constants), context.temp_allocator)
    for _, i in desc.constants do entries[i] = {constantID = u32(i), offset = u32(i * size_of(u32)), size = size_of(u32)}
    specialization = {
      mapEntryCount = u32(len(entries)),
      pMapEntries   = raw_data(entries),
      dataSize      = len(desc.constants) * size_of(u32),
      pData         = raw_data(desc.constants),
    }
    info.specialization = &specialization
  }
  pipeline, res := create_graphics_pipeline(&b.gctx, info)
  if !check(res, "rhi graphics pipeline") do return 0, false
  return pipeline_store(b, {pipeline, layout, .GRAPHICS, bindless_set}), true
}

rhi_pipeline_retire :: proc(b: ^Backend, handle: rhi.Pipeline) {
  if handle == 0 do return
  defer_destroy(&b.gctx, b.rhi.pipelines.items[handle].pipeline)
  rhi.pool_release(&b.rhi.pipelines, u32(handle))
}

@(private = "file")
timeline :: proc(b: ^Backend, queue: rhi.Queue) -> vk.Semaphore {
  return b.gctx.graphics_timeline if queue == .GRAPHICS else b.gctx.compute_timeline
}

// Blocks until the submissions that last used this frame slot are done: its per-frame buffers
// may be rewritten. Separate from frame_begin so the caller places the wait.
rhi_frame_wait :: proc(b: ^Backend) -> (rhi.Frame, bool) {
  slot := u32(b.gctx.frame_serial % FRAMES_IN_FLIGHT)
  b.rhi.frame_index = slot
  frame := rhi.Frame{index = slot}
  semaphores: [2]vk.Semaphore
  values: [2]u64
  count: u32
  for q in rhi.Queue {
    value := b.rhi.slot_value[slot][q]
    if value == 0 do continue
    semaphores[count], values[count] = timeline(b, q), value
    count += 1
  }
  if count > 0 {
    info := vk.SemaphoreWaitInfo {
      sType          = .SEMAPHORE_WAIT_INFO,
      semaphoreCount = count,
      pSemaphores    = &semaphores[0],
      pValues        = &values[0],
    }
    if !check(vk.WaitSemaphores(b.gctx.device, &info, math.max(u64)), "rhi frame wait") do return frame, false
  }
  // nothing of the slot is pending: its lists and timestamps start over
  for &thread in b.rhi.cmd_pools do for &queue in thread {
    p := &queue[slot]
    if p.cursor == 0 do continue
    vk.ResetCommandPool(b.gctx.device, p.pool, {})
    p.cursor = 0
  }
  timings_collect(b, slot)
  return frame, true
}

// Reads the slot's timestamps into b.rhi.timings and resets them.
@(private = "file")
timings_collect :: proc(b: ^Backend, slot: u32) {
  clear(&b.rhi.timings)
  if !timestamps_supported(&b.gctx) do return
  device := b.gctx.device
  t := &b.rhi.timing[slot]
  if t.queries == 0 do return
  n := min(t.count, MAX_TIMED_SCOPES)
  if n == 0 do return
  t.count = 0
  // per query: the value, then whether it is available
  results := make([][2]u64, 2 * n, context.temp_allocator)
  vk.GetQueryPoolResults(device, t.queries, 0, 2 * n, len(results) * size_of([2]u64), raw_data(results), size_of([2]u64), {._64, .WITH_AVAILABILITY})
  vk.ResetQueryPool(device, t.queries, 0, 2 * n)
  period := f64(b.gctx.device_properties.limits.timestampPeriod)
  for i in 0 ..< n {
    begin, end := results[2 * i], results[2 * i + 1]
    // a tiler may leave a timestamp unsampled (0) or sample a scope's ends out of order
    // (MoltenVK): no time for it
    if begin[1] == 0 || end[1] == 0 || begin[0] == 0 || end[0] < begin[0] do continue
    timing := t.scopes[i]
    timing.ms = f32(f64(end[0] - begin[0]) * period / 1e6)
    append(&b.rhi.timings, timing)
  }
}

rhi_frame_timings :: proc(b: ^Backend) -> []rhi.Timing {
  return b.rhi.timings[:]
}

// A suboptimal image is still acquired: the frame goes on and frame_present asks for the resize.
rhi_frame_begin :: proc(b: ^Backend, framebuffer_size: [2]u32) -> rhi.FrameStatus {
  res := acquire_next_image(b.gctx.device, &b.swapchain, b.rhi.frame_index)
  if res == .ERROR_OUT_OF_DATE_KHR do return .RESIZE
  if res != .SUBOPTIMAL_KHR && !check(res, "rhi acquire") do return .ERROR
  b.rhi.acquired = true
  b.rhi.backbuffer_in = false
  return .OK
}

// The presenting submission waits for the acquired image and signals its presentation.
rhi_submit :: proc(b: ^Backend, desc: rhi.SubmitDesc) -> rhi.SyncPoint {
  gctx := &b.gctx
  queue := desc.queue
  waits := make([dynamic]vk.SemaphoreSubmitInfo, 0, len(desc.waits) + 1, context.temp_allocator)
  signals := make([dynamic]vk.SemaphoreSubmitInfo, 0, 2, context.temp_allocator)
  for w in desc.waits {
    mask: vk.PipelineStageFlags2 = {.ALL_COMMANDS}
    if w.stages != {} {
      mask = {}
      for stage in w.stages do mask |= STAGES[stage]
    }
    append(&waits, vk.SemaphoreSubmitInfo{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = timeline(b, w.queue), value = w.value, stageMask = mask})
  }
  assert(!desc.present || (queue == .GRAPHICS && b.rhi.acquired), "present: a graphics submission of an acquired frame")
  for c in desc.cmds do assert(desc.present || !(^RhiCmd)(c).presenting, "a list that renders the backbuffer is in the presenting submission")
  sc := &b.swapchain
  if desc.present {
    append(&waits, vk.SemaphoreSubmitInfo{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = sc.image_available_semaphores[b.rhi.frame_index], stageMask = {.COLOR_ATTACHMENT_OUTPUT}})
    append(&signals, vk.SemaphoreSubmitInfo{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = sc.render_finished_semaphores[sc.image_index], stageMask = {.ALL_COMMANDS}})
  }
  b.rhi.next_value[queue] += 1
  value := b.rhi.next_value[queue]
  append(&signals, vk.SemaphoreSubmitInfo{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = timeline(b, queue), value = value, stageMask = {.ALL_COMMANDS}})
  infos := make([]vk.CommandBufferSubmitInfo, len(desc.cmds), context.temp_allocator)
  for c, i in desc.cmds do infos[i] = {sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = (^RhiCmd)(c).cb}
  submit := vk.SubmitInfo2 {
    sType                    = .SUBMIT_INFO_2,
    waitSemaphoreInfoCount   = u32(len(waits)),
    pWaitSemaphoreInfos      = raw_data(waits),
    commandBufferInfoCount   = u32(len(infos)),
    pCommandBufferInfos      = raw_data(infos),
    signalSemaphoreInfoCount = u32(len(signals)),
    pSignalSemaphoreInfos    = raw_data(signals),
  }
  vk_queue := gctx.graphics_queue if queue == .GRAPHICS else gctx.compute_queue
  check(vk.QueueSubmit2(vk_queue, 1, &submit, 0), "rhi submit")
  b.rhi.slot_value[b.rhi.frame_index][queue] = value
  return {queue = queue, value = value}
}

rhi_frame_present :: proc(b: ^Backend) -> rhi.FrameStatus {
  sc := &b.swapchain
  indices := [?]u32{sc.image_index}
  info := vk.PresentInfoKHR {
    sType              = .PRESENT_INFO_KHR,
    waitSemaphoreCount = 1,
    pWaitSemaphores    = &sc.render_finished_semaphores[sc.image_index],
    swapchainCount     = 1,
    pSwapchains        = &sc.handle,
    pImageIndices      = raw_data(indices[:]),
  }
  res := vk.QueuePresentKHR(b.gctx.present_queue, &info)
  b.rhi.acquired = false
  b.gctx.frame_serial += 1
  if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR do return .RESIZE
  if !check(res, "rhi present") do return .ERROR
  return .OK
}

// Lists are made once per thread, queue and frame slot, from a transient pool frame_wait resets
// whole; a thread touches only its own pools.
rhi_cmd_begin :: proc(b: ^Backend, queue: rhi.Queue, thread: u32) -> rhi.CommandList {
  slot := b.rhi.frame_index
  p := &b.rhi.cmd_pools[thread][queue][slot]
  if p.pool == 0 {
    info := vk.CommandPoolCreateInfo {
      sType            = .COMMAND_POOL_CREATE_INFO,
      flags            = {.TRANSIENT},
      queueFamilyIndex = b.gctx.graphics_family if queue == .GRAPHICS else b.gctx.compute_family,
    }
    check(vk.CreateCommandPool(b.gctx.device, &info, nil, &p.pool), "rhi command pool")
  }
  if p.cursor == len(p.lists) {
    cmd := new(RhiCmd)
    cmd.queue = queue
    allocate_command_buffer(&b.gctx, ([^]vk.CommandBuffer)(&cmd.cb)[:1], p.pool)
    append(&p.lists, cmd)
  }
  cmd := p.lists[p.cursor]
  p.cursor += 1
  cmd.pipeline, cmd.presenting, cmd.bound, cmd.slot, cmd.depth = nil, false, {}, slot, 0
  begin_record(cmd.cb)
  return rhi.CommandList(cmd)
}

rhi_cmd_flush_uploads :: proc(b: ^Backend, handle: rhi.CommandList) {
  record_uploads(&b.gctx, (^RhiCmd)(handle).cb)
}

rhi_cmd_end :: proc(b: ^Backend, handle: rhi.CommandList) {
  cmd := (^RhiCmd)(handle)
  if cmd.presenting do present_barrier(cmd.cb, b.swapchain.images[b.swapchain.image_index])
  vk.EndCommandBuffer(cmd.cb)
}

@(private = "file")
attachment_view :: proc(b: ^Backend, cmd: ^RhiCmd, texture: rhi.TextureHandle) -> (view: vk.ImageView, extent: vk.Extent2D) {
  if texture == rhi.BACKBUFFER {
    sc := &b.swapchain
    // the image leaves UNDEFINED the first time it is used
    if !b.rhi.backbuffer_in {
      b.rhi.backbuffer_in = true
      image_discard_barrier(cmd.cb, {sc.images[sc.image_index], {.COLOR}, {.COLOR_ATTACHMENT_WRITE}, {.COLOR_ATTACHMENT_OUTPUT}})
    }
    cmd.presenting = true
    return sc.views[sc.image_index], sc.extent
  }
  img := texture_image(b, texture)
  return img.view, img.extent
}

@(private = "file")
vk_load_op :: proc(op: rhi.LoadOp) -> vk.AttachmentLoadOp {
  switch op {
  case .LOAD:      return .LOAD
  case .CLEAR:     return .CLEAR
  case .DONT_CARE: return .DONT_CARE
  }
  return .LOAD
}

rhi_cmd_begin_pass :: proc(b: ^Backend, handle: rhi.CommandList, desc: rhi.PassDesc) {
  cmd := (^RhiCmd)(handle)
  extent: vk.Extent2D
  colors := make([]vk.RenderingAttachmentInfo, len(desc.colors), context.temp_allocator)
  for c, i in desc.colors {
    view: vk.ImageView
    view, extent = attachment_view(b, cmd, c.texture)
    colors[i] = create_color_attachment(view, vk_load_op(c.load), .STORE, c.clear)
  }
  depth: Maybe(vk.RenderingAttachmentInfo)
  if target, ok := desc.depth.?; ok {
    view: vk.ImageView
    view, extent = attachment_view(b, cmd, target.texture)
    store: vk.AttachmentStoreOp = .STORE if target.store else .NONE if target.read_only else .DONT_CARE
    depth = create_depth_attachment(view, .LOAD if target.read_only else vk_load_op(target.load), store, target.clear)
  }
  begin_rendering(cmd.cb, extent, depth, ..colors, layer_count = max(desc.layer_count, 1))
}

rhi_cmd_end_pass :: proc(b: ^Backend, handle: rhi.CommandList) {
  vk.CmdEndRendering((^RhiCmd)(handle).cb)
}

// Compute needs no scope on Vulkan.
rhi_cmd_begin_compute :: proc(b: ^Backend, handle: rhi.CommandList) {}

rhi_cmd_end_compute :: proc(b: ^Backend, handle: rhi.CommandList) {}

// A debug label, and a timestamp at each end when the device has them.
rhi_cmd_label_begin :: proc(b: ^Backend, handle: rhi.CommandList, name: string) {
  cmd := (^RhiCmd)(handle)
  if b.gctx.debug_labels {
    label := vk.DebugUtilsLabelEXT{sType = .DEBUG_UTILS_LABEL_EXT, pLabelName = strings.clone_to_cstring(name, context.temp_allocator)}
    vk.CmdBeginDebugUtilsLabelEXT(cmd.cb, &label)
  }
  index := u32(MAX_TIMED_SCOPES)
  t := &b.rhi.timing[cmd.slot]
  if t.queries != 0 && b.gctx.timestamp_bits[0 if cmd.queue == .GRAPHICS else 1] > 0 {
    index = intrinsics.atomic_add(&t.count, 1)
    if index < MAX_TIMED_SCOPES {
      t.scopes[index] = {name = name, queue = cmd.queue, depth = cmd.depth}
      vk.CmdWriteTimestamp2(cmd.cb, {.ALL_COMMANDS}, t.queries, 2 * index)
    } else {
      index = MAX_TIMED_SCOPES
    }
  }
  assert(cmd.depth < MAX_LABEL_DEPTH, "label scopes nest too deep")
  cmd.labels[cmd.depth] = index
  cmd.depth += 1
}

rhi_cmd_label_end :: proc(b: ^Backend, handle: rhi.CommandList) {
  cmd := (^RhiCmd)(handle)
  assert(cmd.depth > 0, "label end without a begin")
  cmd.depth -= 1
  if index := cmd.labels[cmd.depth]; index < MAX_TIMED_SCOPES {
    vk.CmdWriteTimestamp2(cmd.cb, {.ALL_COMMANDS}, b.rhi.timing[cmd.slot].queries, 2 * index + 1)
  }
  if b.gctx.debug_labels do vk.CmdEndDebugUtilsLabelEXT(cmd.cb)
}

rhi_cmd_bind_pipeline :: proc(b: ^Backend, handle: rhi.CommandList, pipeline: rhi.Pipeline) {
  cmd := (^RhiCmd)(handle)
  cmd.pipeline = &b.rhi.pipelines.items[pipeline]
  vk.CmdBindPipeline(cmd.cb, cmd.pipeline.bind_point, cmd.pipeline.pipeline)
}

// Binds `set` at index for the current pipeline unless it is bound there already with the same
// layout (a set bound with a pipeline layout stays bound across pipelines sharing it).
@(private = "file")
set_bind :: proc(cmd: ^RhiCmd, index: u32, set: vk.DescriptorSet) {
  p := cmd.pipeline
  bound := &cmd.bound[0 if p.bind_point == .GRAPHICS else 1]
  if bound.layout != p.layout do bound^ = {layout = p.layout}
  if bound.sets[index] == set do return
  bound.sets[index] = set
  set := set
  vk.CmdBindDescriptorSets(cmd.cb, p.bind_point, p.layout, index, 1, &set, 0, nil)
}

rhi_cmd_bind_group :: proc(b: ^Backend, handle: rhi.CommandList, set: u32, group: rhi.BindGroup) {
  set_bind((^RhiCmd)(handle), set, b.rhi.groups.items[group].set)
}

rhi_cmd_bind_bindless :: proc(b: ^Backend, handle: rhi.CommandList) {
  cmd := (^RhiCmd)(handle)
  set_bind(cmd, cmd.pipeline.bindless_set, b.bindless_set)
}

rhi_cmd_push :: proc(b: ^Backend, handle: rhi.CommandList, data: rawptr, size: u32) {
  cmd := (^RhiCmd)(handle)
  if size == 0 do return
  vk.CmdPushConstants(cmd.cb, cmd.pipeline.layout, PUSH_STAGES, 0, size, data)
}

rhi_cmd_set_scissor :: proc(b: ^Backend, handle: rhi.CommandList, x, y, w, h: u32) {
  scissor := vk.Rect2D{offset = {i32(x), i32(y)}, extent = {w, h}}
  vk.CmdSetScissor((^RhiCmd)(handle).cb, 0, 1, &scissor)
}

rhi_cmd_bind_vertex :: proc(b: ^Backend, handle: rhi.CommandList, slot: u32, buffer: rhi.Buffer, offset: int) {
  buffers := [1]vk.Buffer{b.rhi.buffers.items[buffer].buffer}
  offsets := [1]vk.DeviceSize{vk.DeviceSize(offset)}
  vk.CmdBindVertexBuffers((^RhiCmd)(handle).cb, slot, 1, raw_data(buffers[:]), raw_data(offsets[:]))
}

rhi_cmd_bind_index :: proc(b: ^Backend, handle: rhi.CommandList, buffer: rhi.Buffer, offset: int) {
  vk.CmdBindIndexBuffer((^RhiCmd)(handle).cb, b.rhi.buffers.items[buffer].buffer, vk.DeviceSize(offset), .UINT32)
}

rhi_cmd_draw :: proc(b: ^Backend, handle: rhi.CommandList, vertex_count, instance_count, first_vertex, first_instance: u32) {
  vk.CmdDraw((^RhiCmd)(handle).cb, vertex_count, instance_count, first_vertex, first_instance)
}

rhi_cmd_draw_indexed :: proc(b: ^Backend, handle: rhi.CommandList, index_count, instance_count, first_index: u32, vertex_offset: i32, first_instance: u32) {
  vk.CmdDrawIndexed((^RhiCmd)(handle).cb, index_count, instance_count, first_index, vertex_offset, first_instance)
}

rhi_cmd_draw_indirect :: proc(b: ^Backend, handle: rhi.CommandList, buffer: rhi.Buffer, offset: int, draw_count, stride: u32) {
  vk.CmdDrawIndirect((^RhiCmd)(handle).cb, b.rhi.buffers.items[buffer].buffer, vk.DeviceSize(offset), draw_count, stride)
}

rhi_cmd_draw_indexed_indirect :: proc(b: ^Backend, handle: rhi.CommandList, buffer: rhi.Buffer, offset: int, draw_count, stride: u32) {
  vk.CmdDrawIndexedIndirect((^RhiCmd)(handle).cb, b.rhi.buffers.items[buffer].buffer, vk.DeviceSize(offset), draw_count, stride)
}

rhi_cmd_draw_indexed_indirect_count :: proc(
  b: ^Backend,
  handle: rhi.CommandList,
  buffer: rhi.Buffer,
  offset: int,
  count_buffer: rhi.Buffer,
  count_offset: int,
  max_count, stride: u32,
) {
  vk.CmdDrawIndexedIndirectCount(
    (^RhiCmd)(handle).cb,
    b.rhi.buffers.items[buffer].buffer,
    vk.DeviceSize(offset),
    b.rhi.buffers.items[count_buffer].buffer,
    vk.DeviceSize(count_offset),
    max_count,
    stride,
  )
}

rhi_cmd_dispatch :: proc(b: ^Backend, handle: rhi.CommandList, x, y, z: u32) {
  vk.CmdDispatch((^RhiCmd)(handle).cb, x, y, z)
}

rhi_cmd_fill_buffer :: proc(b: ^Backend, handle: rhi.CommandList, buffer: rhi.Buffer, offset, size: int) {
  vk.CmdFillBuffer((^RhiCmd)(handle).cb, b.rhi.buffers.items[buffer].buffer, vk.DeviceSize(offset), vk.DeviceSize(size), 0)
}

rhi_cmd_copy_buffer :: proc(b: ^Backend, handle: rhi.CommandList, src: rhi.Buffer, src_offset: int, dst: rhi.Buffer, dst_offset, size: int) {
  region := vk.BufferCopy{srcOffset = vk.DeviceSize(src_offset), dstOffset = vk.DeviceSize(dst_offset), size = vk.DeviceSize(size)}
  vk.CmdCopyBuffer((^RhiCmd)(handle).cb, b.rhi.buffers.items[src].buffer, b.rhi.buffers.items[dst].buffer, 1, &region)
}

@(private = "file")
STAGES := [rhi.Stage]vk.PipelineStageFlags2 {
  .DRAW_INDIRECT           = {.DRAW_INDIRECT},
  .VERTEX_SHADER           = {.VERTEX_SHADER},
  .FRAGMENT_SHADER         = {.FRAGMENT_SHADER},
  .COMPUTE_SHADER          = {.COMPUTE_SHADER},
  .EARLY_FRAGMENT_TESTS    = {.EARLY_FRAGMENT_TESTS},
  .LATE_FRAGMENT_TESTS     = {.LATE_FRAGMENT_TESTS},
  .COLOR_ATTACHMENT_OUTPUT = {.COLOR_ATTACHMENT_OUTPUT},
  .TRANSFER                = {.TRANSFER},
}

@(private = "file")
ACCESSES := [rhi.Access]vk.AccessFlags2 {
  .INDIRECT_READ          = {.INDIRECT_COMMAND_READ},
  .SHADER_READ            = {.SHADER_READ},
  .SHADER_WRITE           = {.SHADER_WRITE},
  .COLOR_ATTACHMENT_READ  = {.COLOR_ATTACHMENT_READ},
  .COLOR_ATTACHMENT_WRITE = {.COLOR_ATTACHMENT_WRITE},
  .DEPTH_ATTACHMENT_READ  = {.DEPTH_STENCIL_ATTACHMENT_READ},
  .DEPTH_ATTACHMENT_WRITE = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
  .TRANSFER_READ          = {.TRANSFER_READ},
  .TRANSFER_WRITE         = {.TRANSFER_WRITE},
}

// Every barrier and discard in one vkCmdPipelineBarrier2.
rhi_cmd_barrier :: proc(b: ^Backend, handle: rhi.CommandList, barriers: []rhi.Barrier, discards: []rhi.TextureHandle) {
  if len(barriers) == 0 && len(discards) == 0 do return
  memory := make([]vk.MemoryBarrier2, len(barriers), context.temp_allocator)
  for barrier, i in barriers {
    m := &memory[i]
    m.sType = .MEMORY_BARRIER_2
    for s in barrier.src_stage do m.srcStageMask |= STAGES[s]
    for s in barrier.dst_stage do m.dstStageMask |= STAGES[s]
    for a in barrier.src_access do m.srcAccessMask |= ACCESSES[a]
    for a in barrier.dst_access do m.dstAccessMask |= ACCESSES[a]
  }
  dep := vk.DependencyInfo {
    sType              = .DEPENDENCY_INFO,
    memoryBarrierCount = u32(len(memory)),
    pMemoryBarriers    = raw_data(memory),
  }
  images := make([]ImageDiscard, len(discards), context.temp_allocator)
  for t, i in discards do images[i] = attachment_discard(texture_image(b, t))
  image_discards_fill(&dep, images)
  vk.CmdPipelineBarrier2((^RhiCmd)(handle).cb, &dep)
}
