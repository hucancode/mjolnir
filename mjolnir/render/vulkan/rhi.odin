package vulkan_backend

import rhi "../rhi"

import "core:log"
import "core:math"
import vk "vendor:vulkan"

// The backend's half of rhi's explicit contract (rhi/device.odin): PROCS is the conformance
// check, every proc below is one of its fields. Nothing here decides: a barrier is the one the
// caller recorded, a submission waits on what the caller named, and bindless, push constants,
// indirect count and layered rendering are exposed through rhi.Caps as they are.

PROCS :: rhi.Procs(Backend) {
  caps                            = rhi_caps,
  buffer_create                   = rhi_buffer_create,
  buffer_retire                   = rhi_buffer_retire,
  buffer_write                    = rhi_buffer_write,
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
  cmd_begin                       = rhi_cmd_begin,
  cmd_end                         = rhi_cmd_end,
  cmd_begin_pass                  = rhi_cmd_begin_pass,
  cmd_end_pass                    = rhi_cmd_end_pass,
  cmd_begin_compute               = rhi_cmd_begin_compute,
  cmd_end_compute                 = rhi_cmd_end_compute,
  cmd_bind_pipeline               = rhi_cmd_bind_pipeline,
  cmd_bind_group                  = rhi_cmd_bind_group,
  cmd_bind_bindless               = rhi_cmd_bind_bindless,
  cmd_push                        = rhi_cmd_push,
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
  cmd_texture_discard             = rhi_cmd_texture_discard,
}

// SPIR-V of rhi.Shader, entry point "main"; a stage left empty is absent (DEPTH_REDUCE_FROM_DEPTH is WebGPU's).
@(private = "file")
SHADERS := [rhi.Shader]struct {
  vert, frag, comp: []u8,
} {
  .CULL                    = {comp = #load("shader/occlusion_culling/cull.spv")},
  .DEPTH_REDUCE            = {comp = #load("shader/occlusion_culling/depth_reduce.spv")},
  .DEPTH_REDUCE_FROM_DEPTH = {},
  .SHADOW_DEPTH            = {vert = #load("shader/shadow/vert.spv")},
}

// Sets for bind groups: rhi's own pool, apart from the scene pool.
@(private = "file")
RHI_MAX_SETS :: 4096

@(private = "file")
PUSH_STAGES :: vk.ShaderStageFlags{.VERTEX, .FRAGMENT, .COMPUTE}

// What rhi's handles name: index 0 of every pool is none, released slots are reused.
@(private)
RhiState :: struct {
  buffers:       [dynamic]Buffer,
  layouts:       [dynamic]RhiLayout,
  groups:        [dynamic]RhiGroup,
  pipelines:     [dynamic]RhiPipeline,
  free:          struct {
    buffers, layouts, groups, pipelines: [dynamic]u32,
  },
  set_pool:      vk.DescriptorPool,
  // command lists made so far per queue and frame slot, and how many this frame took
  cmds:          [rhi.Queue][FRAMES_IN_FLIGHT][dynamic]^RhiCmd,
  cmd_cursor:    [rhi.Queue]int,
  frame_index:   u32,
  // an image is acquired and not yet presented
  acquired:      bool,
  // the first graphics list of the frame flushes the staged uploads
  uploads_done:  bool,
  // the backbuffer left UNDEFINED this frame
  backbuffer_in: bool,
  // per queue: the value the next submission signals, and per frame slot the last one signalled
  next_value:    [rhi.Queue]u64,
  slot_value:    [FRAMES_IN_FLIGHT][rhi.Queue]u64,
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

// One command list: a command buffer and the pipeline bound on it.
@(private)
RhiCmd :: struct {
  cb:        vk.CommandBuffer,
  pipeline:  ^RhiPipeline,
  queue:     rhi.Queue,
  // renders into the backbuffer: ends in the present layout
  presenting: bool,
}

@(private = "file")
slot_take :: proc(pool: ^[dynamic]$T, free: ^[dynamic]u32) -> u32 {
  if len(pool) == 0 do append(pool, T{})
  if len(free) > 0 do return pop(free)
  append(pool, T{})
  return u32(len(pool) - 1)
}

// Frees what rhi made that shutdown has not: lists, the set pool and the layouts of groups.
@(private)
rhi_shutdown :: proc(b: ^Backend) {
  device := b.gctx.device
  for q in rhi.Queue do for frame in 0 ..< FRAMES_IN_FLIGHT {
    for c in b.rhi.cmds[q][frame] do free(c)
    delete(b.rhi.cmds[q][frame])
  }
  for &buf in b.rhi.buffers do if buf.buffer != 0 do buffer_destroy(device, &buf)
  for &g in b.rhi.groups {
    for v in g.views do vk.DestroyImageView(device, v, nil)
    delete(g.views)
  }
  if b.rhi.set_pool != 0 do vk.DestroyDescriptorPool(device, b.rhi.set_pool, nil)
  for &l in b.rhi.layouts {
    if l.set_layout != 0 do vk.DestroyDescriptorSetLayout(device, l.set_layout, nil)
    delete(l.kinds)
  }
  for &p in b.rhi.pipelines {
    if p.pipeline != 0 do vk.DestroyPipeline(device, p.pipeline, nil)
    if p.layout != 0 do vk.DestroyPipelineLayout(device, p.layout, nil)
  }
  delete(b.rhi.buffers)
  delete(b.rhi.layouts)
  delete(b.rhi.groups)
  delete(b.rhi.pipelines)
  delete(b.rhi.free.buffers)
  delete(b.rhi.free.layouts)
  delete(b.rhi.free.groups)
  delete(b.rhi.free.pipelines)
}

rhi_caps :: proc(b: ^Backend) -> rhi.Caps {
  return {
    bindless = true,
    push_constants = true,
    multi_draw_indirect_count = b.gctx.draw_indirect_count,
    indirect_first_instance = true,
    layered_rendering = true,
    explicit_barriers = true,
    async_compute = b.gctx.compute_family != b.gctx.graphics_family,
    frames_in_flight = FRAMES_IN_FLIGHT,
    retire_grace = RETIRE_GRACE,
    uniform_alignment = u32(b.gctx.device_properties.limits.minUniformBufferOffsetAlignment),
  }
}

rhi_buffer_create :: proc(b: ^Backend, desc: rhi.BufferDesc) -> (rhi.Buffer, bool) {
  usage: vk.BufferUsageFlags
  for u in desc.usage {
    switch u {
    case .STORAGE:  usage += {.STORAGE_BUFFER}
    case .UNIFORM:  usage += {.UNIFORM_BUFFER}
    case .VERTEX:   usage += {.VERTEX_BUFFER}
    case .INDEX:    usage += {.INDEX_BUFFER}
    case .INDIRECT: usage += {.INDIRECT_BUFFER}
    case .COPY_SRC: usage += {.TRANSFER_SRC}
    case .COPY_DST: usage += {.TRANSFER_DST}
    }
  }
  buffer, res := buffer_create(&b.gctx, vk.DeviceSize(max(desc.size, 16)), usage, host_visible = desc.memory == .UPLOAD)
  if !check(res, "rhi buffer") do return 0, false
  slot := slot_take(&b.rhi.buffers, &b.rhi.free.buffers)
  b.rhi.buffers[slot] = buffer
  return rhi.Buffer(slot), true
}

// Destroyed RETIRE_GRACE frames on, once no frame in flight reads it.
rhi_buffer_retire :: proc(b: ^Backend, handle: rhi.Buffer) {
  if handle == 0 do return
  defer_destroy(&b.gctx, b.rhi.buffers[handle])
  b.rhi.buffers[handle] = {}
  append(&b.rhi.free.buffers, u32(handle))
}

rhi_buffer_write :: proc(b: ^Backend, handle: rhi.Buffer, offset: int, data: []u8) -> bool {
  if len(data) == 0 do return true
  buffer := &b.rhi.buffers[handle]
  if buffer.mapped != nil {
    copy(buffer.mapped[offset:][:len(data)], data)
    return true
  }
  return check(queue_buffer_write(&b.gctx, buffer, data, offset), "rhi buffer write")
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
  case .UNIFORM_BUFFER:
    return .UNIFORM_BUFFER
  case .TEXTURE_FLOAT, .TEXTURE_UNFILTERABLE, .TEXTURE_DEPTH, .TEXTURE_CUBE, .TEXTURE_DEPTH_ARRAY:
    return .SAMPLED_IMAGE
  case .STORAGE_TEXTURE:
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
  slot := slot_take(&b.rhi.layouts, &b.rhi.free.layouts)
  b.rhi.layouts[slot] = {layout, kinds}
  return rhi.BindLayout(slot), true
}

@(private = "file")
set_pool_get :: proc(b: ^Backend) -> bool {
  if b.rhi.set_pool != 0 do return true
  sizes := [?]vk.DescriptorPoolSize {
    {.STORAGE_BUFFER, RHI_MAX_SETS * 4},
    {.UNIFORM_BUFFER, RHI_MAX_SETS},
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
  layout := &b.rhi.layouts[desc.layout]
  set: vk.DescriptorSet
  info := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = b.rhi.set_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &layout.set_layout,
  }
  if !check(vk.AllocateDescriptorSets(b.gctx.device, &info, &set), "rhi bind group") do return 0, false
  slot := slot_take(&b.rhi.groups, &b.rhi.free.groups)
  group := &b.rhi.groups[slot]
  group.set = set
  for r, i in desc.resources {
    type := descriptor_type(layout.kinds[i])
    switch v in r {
    case rhi.BufferRange:
      buffer := &b.rhi.buffers[v.buffer]
      range := vk.DeviceSize(v.size) if v.size > 0 else buffer.size - vk.DeviceSize(v.offset)
      write_descriptor(&b.gctx, set, u32(i), 0, type, vk.DescriptorBufferInfo{buffer = buffer.buffer, offset = vk.DeviceSize(v.offset), range = range})
    case rhi.TextureView:
      img := texture_image(b, v.texture)
      if img == nil do continue
      view := img.view
      if v.mip >= 0 {
        made, res := image_create_view(b.gctx.device, img, .D2, base_mip = u32(v.mip))
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
  group := &b.rhi.groups[handle]
  defer_destroy(&b.gctx, RetiredSet{b.rhi.set_pool, group.set})
  for v in group.views do defer_destroy(&b.gctx, v)
  delete(group.views)
  group^ = {}
  append(&b.rhi.free.groups, u32(handle))
}

// The set layouts of desc, the bindless layout after them when asked, and the push range.
@(private = "file")
pipeline_layout_make :: proc(b: ^Backend, desc: rhi.PipelineLayoutDesc) -> (layout: vk.PipelineLayout, bindless_set: u32, ok: bool) {
  sets := make([dynamic]vk.DescriptorSetLayout, 0, len(desc.layouts) + 1, context.temp_allocator)
  for l in desc.layouts do append(&sets, b.rhi.layouts[l].set_layout)
  bindless_set = u32(len(sets))
  if desc.bindless do append(&sets, b.scene.bindless_layout)
  range := vk.PushConstantRange{stageFlags = PUSH_STAGES, size = max(desc.push_size, 4)}
  info := vk.PipelineLayoutCreateInfo {
    sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount         = u32(len(sets)),
    pSetLayouts            = raw_data(sets),
    pushConstantRangeCount = 1 if desc.push_size > 0 else 0,
    pPushConstantRanges    = &range,
  }
  ok = check(vk.CreatePipelineLayout(b.gctx.device, &info, nil, &layout), "rhi pipeline layout")
  return
}

@(private = "file")
pipeline_store :: proc(b: ^Backend, p: RhiPipeline) -> rhi.Pipeline {
  slot := slot_take(&b.rhi.pipelines, &b.rhi.free.pipelines)
  b.rhi.pipelines[slot] = p
  return rhi.Pipeline(slot)
}

rhi_compute_pipeline_create :: proc(b: ^Backend, desc: rhi.ComputePipelineDesc) -> (rhi.Pipeline, bool) {
  code := SHADERS[desc.shader].comp
  if len(code) == 0 {
    log.errorf("Shader %v has no compute stage on Vulkan", desc.shader)
    return 0, false
  }
  layout, bindless_set, layout_ok := pipeline_layout_make(b, desc.layout)
  if !layout_ok do return 0, false
  pipeline, res := create_compute_pipeline(&b.gctx, code, layout)
  if !check(res, "rhi compute pipeline") {
    vk.DestroyPipelineLayout(b.gctx.device, layout, nil)
    return 0, false
  }
  return pipeline_store(b, {pipeline, layout, .COMPUTE, bindless_set}), true
}

@(private = "file")
VERTEX_FORMATS := [rhi.VertexFormat]vk.Format {
  .F32X2 = .R32G32_SFLOAT,
  .F32X3 = .R32G32B32_SFLOAT,
  .F32X4 = .R32G32B32A32_SFLOAT,
  .U32   = .R32_UINT,
}

rhi_graphics_pipeline_create :: proc(b: ^Backend, desc: rhi.GraphicsPipelineDesc) -> (rhi.Pipeline, bool) {
  shader := SHADERS[desc.shader]
  if len(shader.vert) == 0 {
    log.errorf("Shader %v has no vertex stage on Vulkan", desc.shader)
    return 0, false
  }
  layout, bindless_set, layout_ok := pipeline_layout_make(b, desc.layout)
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
    formats[i] = FORMATS[f]
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
    topology          = .TRIANGLE_LIST if desc.topology == .TRIANGLE_LIST else .LINE_LIST,
    cull_mode         = {.BACK} if desc.cull == .BACK else {},
    blend             = blend,
    color_formats     = formats,
    layout            = layout,
  }
  if depth, ok := desc.depth.?; ok {
    info.depth = {depthTestEnable = true, depthWriteEnable = b32(depth.write), depthCompareOp = .LESS_OR_EQUAL if depth.compare == .LESS_EQUAL else .ALWAYS}
    info.depth_format = .D32_SFLOAT
    info.depth_clamp = b32(depth.clamp && b.gctx.depth_clamp)
    info.depth_bias = {0, depth.slope_bias}
  }
  pipeline, res := create_graphics_pipeline(&b.gctx, info)
  if !check(res, "rhi graphics pipeline") {
    vk.DestroyPipelineLayout(b.gctx.device, layout, nil)
    return 0, false
  }
  return pipeline_store(b, {pipeline, layout, .GRAPHICS, bindless_set}), true
}

rhi_pipeline_retire :: proc(b: ^Backend, handle: rhi.Pipeline) {
  if handle == 0 do return
  p := &b.rhi.pipelines[handle]
  defer_destroy(&b.gctx, p.pipeline)
  defer_destroy(&b.gctx, p.layout)
  p^ = {}
  append(&b.rhi.free.pipelines, u32(handle))
}

@(private = "file")
timeline :: proc(b: ^Backend, queue: rhi.Queue) -> vk.Semaphore {
  return b.gctx.graphics_timeline if queue == .GRAPHICS else b.gctx.compute_timeline
}

// Blocks until the submissions that last used this frame slot are done: its per-frame buffers
// may be rewritten. Separate from frame_begin so the caller places the wait.
rhi_frame_wait :: proc(b: ^Backend) -> bool {
  slot := u32(b.gctx.frame_serial % FRAMES_IN_FLIGHT)
  semaphores: [2]vk.Semaphore
  values: [2]u64
  count: u32
  for q in rhi.Queue {
    value := b.rhi.slot_value[slot][q]
    if value == 0 do continue
    semaphores[count], values[count] = timeline(b, q), value
    count += 1
  }
  if count == 0 do return true
  info := vk.SemaphoreWaitInfo {
    sType          = .SEMAPHORE_WAIT_INFO,
    semaphoreCount = count,
    pSemaphores    = &semaphores[0],
    pValues        = &values[0],
  }
  return check(vk.WaitSemaphores(b.gctx.device, &info, math.max(u64)), "rhi frame wait")
}

rhi_frame_begin :: proc(b: ^Backend, framebuffer_size: [2]u32) -> (rhi.Frame, rhi.FrameStatus) {
  frame_index := u32(b.gctx.frame_serial % FRAMES_IN_FLIGHT)
  res := acquire_next_image(b.gctx.device, &b.swapchain, frame_index)
  if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR do return {}, .RESIZE
  if !check(res, "rhi acquire") do return {}, .ERROR
  b.rhi.frame_index = frame_index
  b.rhi.acquired = true
  b.rhi.cmd_cursor = {}
  b.rhi.uploads_done = false
  b.rhi.backbuffer_in = false
  return {index = frame_index}, .OK
}

// The graphics submission of an acquired frame waits for the image and signals its presentation.
rhi_submit :: proc(b: ^Backend, queue: rhi.Queue, cmds: []rhi.CommandList, wait: []rhi.SyncPoint) -> rhi.SyncPoint {
  gctx := &b.gctx
  waits := make([dynamic]vk.SemaphoreSubmitInfo, 0, len(wait) + 1, context.temp_allocator)
  signals := make([dynamic]vk.SemaphoreSubmitInfo, 0, 2, context.temp_allocator)
  for w in wait do append(&waits, vk.SemaphoreSubmitInfo{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = timeline(b, w.queue), value = w.value, stageMask = {.ALL_COMMANDS}})
  presenting := queue == .GRAPHICS && b.rhi.acquired
  sc := &b.swapchain
  if presenting {
    append(&waits, vk.SemaphoreSubmitInfo{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = sc.image_available_semaphores[b.rhi.frame_index], stageMask = {.COLOR_ATTACHMENT_OUTPUT}})
    append(&signals, vk.SemaphoreSubmitInfo{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = sc.render_finished_semaphores[sc.image_index], stageMask = {.ALL_COMMANDS}})
  }
  b.rhi.next_value[queue] += 1
  value := b.rhi.next_value[queue]
  append(&signals, vk.SemaphoreSubmitInfo{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = timeline(b, queue), value = value, stageMask = {.ALL_COMMANDS}})
  infos := make([]vk.CommandBufferSubmitInfo, len(cmds), context.temp_allocator)
  for c, i in cmds do infos[i] = {sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = (^RhiCmd)(c).cb}
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
  return {queue, value}
}

rhi_frame_present :: proc(b: ^Backend, frame: rhi.Frame) -> rhi.FrameStatus {
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

// Lists are made once per queue and frame slot and reset by cmd_begin. The first graphics one
// of a frame carries the staged uploads.
rhi_cmd_begin :: proc(b: ^Backend, queue: rhi.Queue) -> rhi.CommandList {
  slot := b.rhi.frame_index
  ring := &b.rhi.cmds[queue][slot]
  cursor := b.rhi.cmd_cursor[queue]
  if cursor == len(ring) {
    cmd := new(RhiCmd)
    cmd.queue = queue
    pool := b.gctx.command_pool if queue == .GRAPHICS else b.gctx.compute_command_pool
    allocate_command_buffer(&b.gctx, ([^]vk.CommandBuffer)(&cmd.cb)[:1], pool)
    append(ring, cmd)
  }
  b.rhi.cmd_cursor[queue] += 1
  cmd := ring[cursor]
  cmd.pipeline, cmd.presenting = nil, false
  begin_record(cmd.cb)
  if queue == .GRAPHICS && !b.rhi.uploads_done {
    b.rhi.uploads_done = true
    record_uploads(&b.gctx, cmd.cb)
  }
  return rhi.CommandList(cmd)
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
    store: vk.AttachmentStoreOp = .STORE if target.store || target.read_only else .DONT_CARE
    depth = create_depth_attachment(view, .LOAD if target.read_only else vk_load_op(target.load), store, target.clear)
  }
  begin_rendering(cmd.cb, extent, depth, ..colors)
}

rhi_cmd_end_pass :: proc(b: ^Backend, handle: rhi.CommandList) {
  vk.CmdEndRendering((^RhiCmd)(handle).cb)
}

// Compute needs no scope on Vulkan.
rhi_cmd_begin_compute :: proc(b: ^Backend, handle: rhi.CommandList) {}

rhi_cmd_end_compute :: proc(b: ^Backend, handle: rhi.CommandList) {}

rhi_cmd_bind_pipeline :: proc(b: ^Backend, handle: rhi.CommandList, pipeline: rhi.Pipeline) {
  cmd := (^RhiCmd)(handle)
  cmd.pipeline = &b.rhi.pipelines[pipeline]
  vk.CmdBindPipeline(cmd.cb, cmd.pipeline.bind_point, cmd.pipeline.pipeline)
}

rhi_cmd_bind_group :: proc(b: ^Backend, handle: rhi.CommandList, set: u32, group: rhi.BindGroup) {
  cmd := (^RhiCmd)(handle)
  sets := [1]vk.DescriptorSet{b.rhi.groups[group].set}
  vk.CmdBindDescriptorSets(cmd.cb, cmd.pipeline.bind_point, cmd.pipeline.layout, set, 1, raw_data(sets[:]), 0, nil)
}

rhi_cmd_bind_bindless :: proc(b: ^Backend, handle: rhi.CommandList) {
  cmd := (^RhiCmd)(handle)
  sets := [1]vk.DescriptorSet{b.scene.bindless_set}
  vk.CmdBindDescriptorSets(cmd.cb, cmd.pipeline.bind_point, cmd.pipeline.layout, cmd.pipeline.bindless_set, 1, raw_data(sets[:]), 0, nil)
}

rhi_cmd_push :: proc(b: ^Backend, handle: rhi.CommandList, data: rawptr, size: u32) {
  cmd := (^RhiCmd)(handle)
  if size == 0 do return
  vk.CmdPushConstants(cmd.cb, cmd.pipeline.layout, PUSH_STAGES, 0, size, data)
}

rhi_cmd_bind_vertex :: proc(b: ^Backend, handle: rhi.CommandList, slot: u32, buffer: rhi.Buffer, offset: int) {
  buffers := [1]vk.Buffer{b.rhi.buffers[buffer].buffer}
  offsets := [1]vk.DeviceSize{vk.DeviceSize(offset)}
  vk.CmdBindVertexBuffers((^RhiCmd)(handle).cb, slot, 1, raw_data(buffers[:]), raw_data(offsets[:]))
}

rhi_cmd_bind_index :: proc(b: ^Backend, handle: rhi.CommandList, buffer: rhi.Buffer, offset: int) {
  vk.CmdBindIndexBuffer((^RhiCmd)(handle).cb, b.rhi.buffers[buffer].buffer, vk.DeviceSize(offset), .UINT32)
}

rhi_cmd_draw :: proc(b: ^Backend, handle: rhi.CommandList, vertex_count, instance_count, first_vertex, first_instance: u32) {
  vk.CmdDraw((^RhiCmd)(handle).cb, vertex_count, instance_count, first_vertex, first_instance)
}

rhi_cmd_draw_indexed :: proc(b: ^Backend, handle: rhi.CommandList, index_count, instance_count, first_index: u32, vertex_offset: i32, first_instance: u32) {
  vk.CmdDrawIndexed((^RhiCmd)(handle).cb, index_count, instance_count, first_index, vertex_offset, first_instance)
}

rhi_cmd_draw_indirect :: proc(b: ^Backend, handle: rhi.CommandList, buffer: rhi.Buffer, offset: int) {
  vk.CmdDrawIndirect((^RhiCmd)(handle).cb, b.rhi.buffers[buffer].buffer, vk.DeviceSize(offset), 1, 0)
}

rhi_cmd_draw_indexed_indirect :: proc(b: ^Backend, handle: rhi.CommandList, buffer: rhi.Buffer, offset: int) {
  vk.CmdDrawIndexedIndirect((^RhiCmd)(handle).cb, b.rhi.buffers[buffer].buffer, vk.DeviceSize(offset), 1, 0)
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
    b.rhi.buffers[buffer].buffer,
    vk.DeviceSize(offset),
    b.rhi.buffers[count_buffer].buffer,
    vk.DeviceSize(count_offset),
    max_count,
    stride,
  )
}

rhi_cmd_dispatch :: proc(b: ^Backend, handle: rhi.CommandList, x, y, z: u32) {
  vk.CmdDispatch((^RhiCmd)(handle).cb, x, y, z)
}

rhi_cmd_fill_buffer :: proc(b: ^Backend, handle: rhi.CommandList, buffer: rhi.Buffer, offset, size: int) {
  vk.CmdFillBuffer((^RhiCmd)(handle).cb, b.rhi.buffers[buffer].buffer, vk.DeviceSize(offset), vk.DeviceSize(size), 0)
}

rhi_cmd_copy_buffer :: proc(b: ^Backend, handle: rhi.CommandList, src: rhi.Buffer, src_offset: int, dst: rhi.Buffer, dst_offset, size: int) {
  region := vk.BufferCopy{srcOffset = vk.DeviceSize(src_offset), dstOffset = vk.DeviceSize(dst_offset), size = vk.DeviceSize(size)}
  vk.CmdCopyBuffer((^RhiCmd)(handle).cb, b.rhi.buffers[src].buffer, b.rhi.buffers[dst].buffer, 1, &region)
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

rhi_cmd_barrier :: proc(b: ^Backend, handle: rhi.CommandList, barrier: rhi.Barrier) {
  src_stage, dst_stage: vk.PipelineStageFlags2
  src_access, dst_access: vk.AccessFlags2
  for s in barrier.src_stage do src_stage |= STAGES[s]
  for s in barrier.dst_stage do dst_stage |= STAGES[s]
  for a in barrier.src_access do src_access |= ACCESSES[a]
  for a in barrier.dst_access do dst_access |= ACCESSES[a]
  memory_barrier((^RhiCmd)(handle).cb, src_access, dst_access, src_stage, dst_stage)
}

rhi_cmd_texture_discard :: proc(b: ^Backend, handle: rhi.CommandList, textures: []rhi.TextureHandle) {
  discards := make([]ImageDiscard, len(textures), context.temp_allocator)
  for t, i in textures do discards[i] = attachment_discard(texture_image(b, t))
  image_discard_barrier((^RhiCmd)(handle).cb, ..discards)
}
