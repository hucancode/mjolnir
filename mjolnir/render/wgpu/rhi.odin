package wgpu_backend

import rhi "../rhi"

import "core:fmt"
import "core:log"
import "core:mem"
import wgpu "vendor:wgpu"

// The backend's half of rhi's explicit contract (rhi/device.odin): PROCS is the conformance
// check, every proc below is one of its fields. WebGPU syncs on its own, so barriers are no-ops;
// it has no push constants, so cmd_push writes the pipeline's push group (the frame group:
// a dynamic-offset uniform, then every sampler) at the set after the pipeline's layouts, which
// every pipeline of this contract takes and every pass binds with cmd_push, even of size 0.

PROCS :: rhi.Procs(Backend, WindowHandle) {
  init                            = init,
  window_size                     = window_size,
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
  cmd_set_viewport                = rhi_cmd_set_viewport,
  cmd_bind_vertex                 = rhi_cmd_bind_vertex,
  cmd_bind_index                  = rhi_cmd_bind_index,
  cmd_draw                        = rhi_cmd_draw,
  cmd_draw_indexed                = rhi_cmd_draw_indexed,
  cmd_draw_indirect               = rhi_cmd_draw_indirect,
  cmd_draw_indexed_indirect       = rhi_cmd_draw_indexed_indirect,
  cmd_draw_indexed_indirect_count = rhi_cmd_draw_indexed_indirect_count,
  cmd_dispatch                    = rhi_cmd_dispatch,
  cmd_dispatch_indirect           = rhi_cmd_dispatch_indirect,
  cmd_fill_buffer                 = rhi_cmd_fill_buffer,
  cmd_copy_buffer                 = rhi_cmd_copy_buffer,
  cmd_copy_backbuffer             = rhi_cmd_copy_backbuffer,
  cmd_barrier                     = rhi_cmd_barrier,
}


// A READBACK buffer is a ring of mappable buffers, as a buffer cannot be copied into while it
// maps; `data` is the last copy that came back. A retired one is freed, and its handle with
// it, once no entry maps.
@(private)
Readback :: struct {
  slots:   [READBACK_RING]ReadbackSlot,
  data:    []u8,
  retired: bool,
}

@(private)
READBACK_RING :: 3

@(private)
ReadbackSlot :: struct {
  buffer:  wgpu.Buffer,
  // copied this frame, to map once submitted
  copied:  bool,
  // copied or mapping
  pending: bool,
}

// Command lists recorded at once: the frame's, plus a precompute's.
@(private)
MAX_CMDS :: 8

@(private)
Group :: struct {
  group: wgpu.BindGroup,
  // views made for it, released with it
  views: [dynamic]wgpu.TextureView,
}

@(private)
Pipeline :: struct {
  render:   wgpu.RenderPipeline,
  compute:  wgpu.ComputePipeline,
  // the set of the push group
  push_set: u32,
}

// One command list: an encoder and the pass open on it.
@(private)
Cmd :: struct {
  encoder:  wgpu.CommandEncoder,
  render:   wgpu.RenderPassEncoder,
  compute:  wgpu.ComputePassEncoder,
  finished: wgpu.CommandBuffer,
  push_set: u32,
  // views of layers made for its passes, released once it is submitted
  views:    [dynamic]wgpu.TextureView,
}

rhi_caps :: proc(b: ^Backend) -> rhi.Caps {
  return {indirect_first_instance = b.indirect_first_instance}
}

rhi_buffer_create :: proc(b: ^Backend, desc: rhi.BufferDesc) -> (rhi.Buffer, bool) {
  usage := wgpu.BufferUsageFlags{.CopyDst}
  for u in desc.usage {
    switch u {
    case .STORAGE:  usage += {.Storage}
    case .VERTEX:   usage += {.Vertex}
    case .INDEX:    usage += {.Index}
    case .INDIRECT: usage += {.Indirect}
    case .COPY_SRC: usage += {.CopySrc}
    case .COPY_DST:
    }
  }
  if desc.memory == .READBACK {
    rb := Readback{data = make([]u8, (max(desc.size, 4) + 3) &~ 3)}
    for &s in rb.slots do s.buffer = buffer_create(b, len(rb.data), {.MapRead, .CopyDst})
    slot := rhi.pool_take(&b.buffers)
    b.buffers.items[slot] = rb.slots[0].buffer
    b.readbacks[rhi.Buffer(slot)] = rb
    return rhi.Buffer(slot), true
  }
  buffer := buffer_create(b, max(desc.size, 16), usage)
  if buffer == nil do return 0, false
  slot := rhi.pool_take(&b.buffers)
  b.buffers.items[slot] = buffer
  return rhi.Buffer(slot), true
}

// The last copy of a READBACK buffer that came back (zeros before the first).
rhi_buffer_read :: proc(b: ^Backend, buffer: rhi.Buffer, offset: int, dst: []u8) -> bool {
  rb, ok := b.readbacks[buffer]
  if !ok do return false
  copy(dst, rb.data[offset:])
  return true
}

// WebGPU has no bindless arrays: callers branch on BINDLESS.
rhi_bindless_write :: proc(b: ^Backend, array: rhi.BindlessArray, index: u32, resource: rhi.BindResource) {
  log.errorf("WebGPU has no bindless arrays")
}

// Maps every ring entry copied into since the last submission. The callback finds the entry
// by its readback's handle and ring index.
@(private = "file")
readbacks_map :: proc(b: ^Backend) {
  for handle, &rb in b.readbacks {
    for &s, i in rb.slots {
      if !s.copied do continue
      s.copied = false
      key := uintptr(u32(handle) * READBACK_RING + u32(i))
      wgpu.BufferMapAsync(s.buffer, {.Read}, 0, uint(len(rb.data)), {mode = .AllowProcessEvents, callback = readback_mapped, userdata1 = b, userdata2 = rawptr(key)})
    }
  }
}

@(private = "file")
readback_mapped :: proc "c" (status: wgpu.MapAsyncStatus, message: wgpu.StringView, userdata1, userdata2: rawptr) {
  b := (^Backend)(userdata1)
  context = b.context_
  handle := rhi.Buffer(u32(uintptr(userdata2)) / READBACK_RING)
  if handle not_in b.readbacks do return
  rb := &b.readbacks[handle]
  slot := &rb.slots[u32(uintptr(userdata2)) % READBACK_RING]
  if status == .Success {
    if !rb.retired {
      bytes := wgpu.BufferGetConstMappedRangeSlice(slot.buffer, 0, len(rb.data), u8)
      copy(rb.data, bytes)
    }
    wgpu.BufferUnmap(slot.buffer)
  }
  slot.pending = false
  if rb.retired do readback_free(b, handle)
}

// Frees a retired readback's ring and handle once no entry maps (pending, no longer just copied).
@(private = "file")
readback_free :: proc(b: ^Backend, handle: rhi.Buffer) {
  rb := &b.readbacks[handle]
  for s in rb.slots do if s.pending && !s.copied do return
  for s in rb.slots do wgpu.BufferRelease(s.buffer)
  delete(rb.data)
  delete_key(&b.readbacks, handle)
  rhi.pool_release(&b.buffers, u32(handle))
}

// WebGPU keeps a released buffer alive for work already submitted. A READBACK buffer's ring
// goes with it, once no entry maps.
rhi_buffer_retire :: proc(b: ^Backend, buffer: rhi.Buffer) {
  if buffer == 0 do return
  if buffer in b.readbacks {
    rb := &b.readbacks[buffer]
    rb.retired = true
    readback_free(b, buffer)
    return
  }
  wgpu.BufferRelease(b.buffers.items[buffer])
  rhi.pool_release(&b.buffers, u32(buffer))
}

rhi_buffer_write :: proc(b: ^Backend, buffer: rhi.Buffer, offset: int, data: []u8) -> bool {
  if len(data) == 0 do return true
  // WriteBuffer takes 4-byte multiples
  size := (len(data) + 3) &~ 3
  if size == len(data) {
    wgpu.QueueWriteBuffer(b.queue, b.buffers.items[buffer], u64(offset), raw_data(data), uint(size))
    return true
  }
  padded := make([]u8, size, context.temp_allocator)
  copy(padded, data)
  wgpu.QueueWriteBuffer(b.queue, b.buffers.items[buffer], u64(offset), raw_data(padded), uint(size))
  return true
}

@(private = "file")
stage_flags :: proc(stages: bit_set[rhi.ShaderStage]) -> wgpu.ShaderStageFlags {
  flags: wgpu.ShaderStageFlags
  for s in stages {
    switch s {
    case .VERTEX:   flags += {.Vertex}
    case .FRAGMENT: flags += {.Fragment}
    case .COMPUTE:  flags += {.Compute}
    }
  }
  return flags
}

rhi_bind_layout_create :: proc(b: ^Backend, desc: rhi.BindLayoutDesc) -> (rhi.BindLayout, bool) {
  entries := make([]wgpu.BindGroupLayoutEntry, len(desc.entries), context.temp_allocator)
  for e, i in desc.entries {
    entry := wgpu.BindGroupLayoutEntry{binding = u32(i), visibility = stage_flags(e.stages)}
    switch e.kind {
    case .STORAGE_BUFFER:        entry.buffer = {type = .Storage}
    case .STORAGE_BUFFER_READ:   entry.buffer = {type = .ReadOnlyStorage}
    case .TEXTURE_FLOAT:         entry.texture = {sampleType = .Float, viewDimension = ._2D}
    case .TEXTURE_UNFILTERABLE:  entry.texture = {sampleType = .UnfilterableFloat, viewDimension = ._2D}
    case .TEXTURE_DEPTH:         entry.texture = {sampleType = .Depth, viewDimension = ._2D}
    case .TEXTURE_CUBE:          entry.texture = {sampleType = .Float, viewDimension = .Cube}
    case .TEXTURE_DEPTH_ARRAY:   entry.texture = {sampleType = .Depth, viewDimension = ._2DArray}
    case .STORAGE_TEXTURE:       entry.storageTexture = {access = .WriteOnly, format = FORMATS[e.format], viewDimension = ._2D}
    case .STORAGE_TEXTURE_ARRAY: entry.storageTexture = {access = .WriteOnly, format = FORMATS[e.format], viewDimension = ._2DArray}
    }
    entries[i] = entry
  }
  layout := wgpu.DeviceCreateBindGroupLayout(b.device, &{entryCount = uint(len(entries)), entries = raw_data(entries)})
  if layout == nil do return 0, false
  slot := rhi.pool_take(&b.layouts)
  b.layouts.items[slot] = layout
  return rhi.BindLayout(slot), true
}

rhi_bind_group_create :: proc(b: ^Backend, desc: rhi.BindGroupDesc) -> (rhi.BindGroup, bool) {
  entries := make([]wgpu.BindGroupEntry, len(desc.resources), context.temp_allocator)
  slot := rhi.pool_take(&b.groups)
  group := &b.groups.items[slot]
  for r, i in desc.resources {
    entries[i].binding = u32(i)
    switch v in r {
    case rhi.BufferRange:
      buffer := b.buffers.items[v.buffer]
      size := u64(v.size) if v.size > 0 else wgpu.BufferGetSize(buffer) - u64(v.offset)
      entries[i].buffer = buffer
      entries[i].offset = u64(v.offset)
      entries[i].size = size
    case rhi.TextureView:
      t := &b.textures[v.texture]
      if v.mip < 0 {
        entries[i].textureView = t.view
      } else if t.desc.cube {
        // a cube level as six layers
        view := wgpu.TextureCreateView(t.texture, &{dimension = ._2DArray, baseMipLevel = u32(v.mip), mipLevelCount = 1, arrayLayerCount = 6})
        append(&group.views, view)
        entries[i].textureView = view
      } else {
        view := wgpu.TextureCreateView(t.texture, &{dimension = ._2D, baseMipLevel = u32(v.mip), mipLevelCount = 1, arrayLayerCount = 1})
        append(&group.views, view)
        entries[i].textureView = view
      }
    }
  }
  layout := b.layouts.items[desc.layout]
  group.group = wgpu.DeviceCreateBindGroup(b.device, &{layout = layout, entryCount = uint(len(entries)), entries = raw_data(entries)})
  if group.group == nil {
    rhi_bind_group_retire(b, rhi.BindGroup(slot))
    return 0, false
  }
  return rhi.BindGroup(slot), true
}

rhi_bind_group_retire :: proc(b: ^Backend, handle: rhi.BindGroup) {
  if handle == 0 do return
  group := &b.groups.items[handle]
  if group.group != nil do wgpu.BindGroupRelease(group.group)
  for view in group.views do wgpu.TextureViewRelease(view)
  delete(group.views)
  rhi.pool_release(&b.groups, u32(handle))
}

// The layouts of desc, the push group where PUSH_GROUP marks it, else after them.
@(private = "file")
pipeline_layout_make :: proc(b: ^Backend, desc: rhi.PipelineLayoutDesc) -> (wgpu.PipelineLayout, u32) {
  layouts := make([dynamic]wgpu.BindGroupLayout, 0, len(desc.layouts) + 1, context.temp_allocator)
  push_set := u32(len(desc.layouts))
  for l, i in desc.layouts {
    if l == rhi.PUSH_GROUP {
      push_set = u32(i)
      append(&layouts, b.frame_layout)
    } else {
      append(&layouts, b.layouts.items[l])
    }
  }
  if int(push_set) == len(desc.layouts) do append(&layouts, b.frame_layout)
  layout := wgpu.DeviceCreatePipelineLayout(b.device, &{bindGroupLayoutCount = uint(len(layouts)), bindGroupLayouts = raw_data(layouts[:])})
  return layout, push_set
}

@(private = "file")
pipeline_store :: proc(b: ^Backend, p: Pipeline) -> rhi.Pipeline {
  slot := rhi.pool_take(&b.pipelines)
  b.pipelines.items[slot] = p
  return rhi.Pipeline(slot)
}

rhi_compute_pipeline_create :: proc(b: ^Backend, desc: rhi.ComputePipelineDesc) -> (rhi.Pipeline, bool) {
  module := shader_module(b, string(desc.shader))
  defer wgpu.ShaderModuleRelease(module)
  layout, push_set := pipeline_layout_make(b, desc.layout)
  defer wgpu.PipelineLayoutRelease(layout)
  pipeline := wgpu.DeviceCreateComputePipeline(b.device, &{layout = layout, compute = {module = module, entryPoint = "main"}})
  if pipeline == nil {
    log.errorf("Compute pipeline creation failed")
    return 0, false
  }
  return pipeline_store(b, {compute = pipeline, push_set = push_set}), true
}

@(private = "file")
VERTEX_FORMATS := [rhi.VertexFormat]wgpu.VertexFormat {
  .UNORM8X4 = .Unorm8x4,
  .F32X2 = .Float32x2,
  .F32X3 = .Float32x3,
  .F32X4 = .Float32x4,
  .U32   = .Uint32,
}

@(private = "file")
TOPOLOGIES := [rhi.Topology]wgpu.PrimitiveTopology {
  .TRIANGLE_LIST = .TriangleList,
  .LINE_LIST     = .LineList,
  .POINT_LIST    = .PointList,
}

@(private = "file")
CULL_MODES := [rhi.CullMode]wgpu.CullMode {
  .NONE  = .None,
  .BACK  = .Back,
  .FRONT = .Front,
}

@(private = "file")
COMPARE_FUNCTIONS := [rhi.CompareOp]wgpu.CompareFunction {
  .LESS_EQUAL    = .LessEqual,
  .ALWAYS        = .Always,
  .GREATER       = .Greater,
  .GREATER_EQUAL = .GreaterEqual,
}

rhi_graphics_pipeline_create :: proc(b: ^Backend, desc: rhi.GraphicsPipelineDesc) -> (rhi.Pipeline, bool) {
  module := shader_module(b, string(desc.shader))
  defer wgpu.ShaderModuleRelease(module)
  layout, push_set := pipeline_layout_make(b, desc.layout)
  defer wgpu.PipelineLayoutRelease(layout)
  buffers := make([]wgpu.VertexBufferLayout, len(desc.vertex), context.temp_allocator)
  for vb, i in desc.vertex {
    attributes := make([]wgpu.VertexAttribute, len(vb.attributes), context.temp_allocator)
    for a, j in vb.attributes do attributes[j] = {format = VERTEX_FORMATS[a.format], offset = u64(a.offset), shaderLocation = a.location}
    buffers[i] = {
      stepMode       = .Vertex if vb.step == .VERTEX else .Instance,
      arrayStride    = u64(vb.stride),
      attributeCount = uint(len(attributes)),
      attributes     = raw_data(attributes),
    }
  }
  blend: ^wgpu.BlendState
  switch desc.blend {
  case .NONE:
  case .ALPHA:    blend = &BLEND_ALPHA
  case .ADDITIVE: blend = &BLEND_ADDITIVE
  }
  targets := make([]wgpu.ColorTargetState, len(desc.color_formats), context.temp_allocator)
  for format, i in desc.color_formats {
    targets[i] = {format = b.surface_view_format if format == .BACKBUFFER else FORMATS[format], blend = blend, writeMask = wgpu.ColorWriteMaskFlags_All}
  }
  constants := make([]wgpu.ConstantEntry, len(desc.constants), context.temp_allocator)
  for c, i in desc.constants do constants[i] = {key = fmt.tprintf("%d", i), value = f64(c)}
  fragment := wgpu.FragmentState {
    module        = module,
    entryPoint    = "fs_main",
    constantCount = uint(len(constants)),
    constants     = raw_data(constants),
    targetCount   = uint(len(targets)),
    targets       = raw_data(targets),
  }
  depth_state: wgpu.DepthStencilState
  state, has_depth := desc.depth.?
  if has_depth {
    depth_state = {
      format              = .Depth32Float,
      depthWriteEnabled   = .True if state.write else .False,
      depthCompare        = COMPARE_FUNCTIONS[state.compare],
      stencilFront        = {compare = .Always},
      stencilBack         = {compare = .Always},
      depthBiasSlopeScale = state.slope_bias,
    }
  }
  pipeline := wgpu.DeviceCreateRenderPipeline(
    b.device,
    &{
      layout = layout,
      vertex = {
        module = module,
        entryPoint = "vs_main",
        constantCount = uint(len(constants)),
        constants = raw_data(constants),
        bufferCount = uint(len(buffers)),
        buffers = raw_data(buffers),
      },
      primitive = {topology = TOPOLOGIES[desc.topology], frontFace = FRONT_FACE, cullMode = CULL_MODES[desc.cull]},
      depthStencil = &depth_state if has_depth else nil,
      multisample = {count = 1, mask = 0xFFFFFFFF},
      fragment = &fragment if len(targets) > 0 else nil,
    },
  )
  if pipeline == nil {
    log.errorf("Render pipeline creation failed")
    return 0, false
  }
  return pipeline_store(b, {render = pipeline, push_set = push_set}), true
}

rhi_pipeline_retire :: proc(b: ^Backend, handle: rhi.Pipeline) {
  if handle == 0 do return
  p := &b.pipelines.items[handle]
  if p.render != nil do wgpu.RenderPipelineRelease(p.render)
  if p.compute != nil do wgpu.ComputePipelineRelease(p.compute)
  rhi.pool_release(&b.pipelines, u32(handle))
}

// Queue order is the only sync: no frame slot to wait for.
rhi_frame_wait :: proc(b: ^Backend) -> (rhi.Frame, bool) {
  return {index = 0}, b.up
}

rhi_frame_begin :: proc(b: ^Backend, framebuffer_size: [2]u32) -> rhi.FrameStatus {
  if !b.up do return .ERROR
  events_process(b)
  if ([2]u32{max(framebuffer_size.x, 1), max(framebuffer_size.y, 1)}) != b.surface_extent do return .RESIZE
  surface_texture := surface_texture_get(b)
  #partial switch surface_texture.status {
  case .SuccessOptimal, .SuccessSuboptimal:
  case .Timeout, .Outdated, .Lost, .Occluded:
    if surface_texture.texture != nil do wgpu.TextureRelease(surface_texture.texture)
    return .RESIZE
  case:
    log.errorf("WebGPU surface texture: %v", surface_texture.status)
    return .ERROR
  }
  b.surface_texture = surface_texture.texture
  b.surface_output = wgpu.TextureCreateView(
    surface_texture.texture,
    &{format = b.surface_view_format, dimension = ._2D, mipLevelCount = 1, arrayLayerCount = 1},
  )
  return .OK
}

// Submits the finished lists in order on the one queue; waits are already satisfied by it. The
// uniforms written so far go first.
rhi_submit :: proc(b: ^Backend, desc: rhi.SubmitDesc) -> rhi.SyncPoint {
  cmds, queue := desc.cmds, desc.queue
  if b.uniform_cursor > b.flushed {
    wgpu.QueueWriteBuffer(
      b.queue,
      b.uniform_buffer,
      u64(b.flushed),
      &b.uniforms[b.flushed],
      uint(b.uniform_cursor - b.flushed),
    )
    b.flushed = b.uniform_cursor
  }
  buffers := make([]wgpu.CommandBuffer, len(cmds), context.temp_allocator)
  for c, i in cmds do buffers[i] = b.cmds[c].finished
  wgpu.QueueSubmit(b.queue, buffers)
  for c in cmds {
    state := &b.cmds[c]
    wgpu.CommandBufferRelease(state.finished)
    wgpu.CommandEncoderRelease(state.encoder)
    for v in state.views do wgpu.TextureViewRelease(v)
    // the slot is free again; its views array is kept for the next list
    views := state.views
    clear(&views)
    state^ = {views = views}
  }
  readbacks_map(b)
  // one queue orders everything: nothing waits on a value
  return {queue = queue}
}

rhi_frame_present :: proc(b: ^Backend) -> rhi.FrameStatus {
  wgpu.SurfacePresent(b.surface)
  wgpu.TextureViewRelease(b.surface_output)
  wgpu.TextureRelease(b.surface_texture)
  b.surface_output, b.surface_texture = nil, nil
  b.uniform_cursor, b.flushed = 0, 0
  b.frame_serial += 1
  return .OK
}

// Caps.timestamps is false: no scope is timed.
rhi_frame_timings :: proc(b: ^Backend) -> []rhi.Timing {
  return nil
}

// One queue and one recording thread: `thread` is always 0.
rhi_cmd_begin :: proc(b: ^Backend, queue: rhi.Queue, thread: u32) -> rhi.CommandList {
  for &c, i in b.cmds do if c.encoder == nil {
    c.encoder = wgpu.DeviceCreateCommandEncoder(b.device)
    return rhi.CommandList(i)
  }
  panic("more than MAX_CMDS command lists at once")
}

rhi_cmd_end :: proc(b: ^Backend, cmd: rhi.CommandList) {
  state := &b.cmds[cmd]
  state.finished = wgpu.CommandEncoderFinish(state.encoder)
}

// QueueWriteBuffer lands writes before the next submission on its own.
rhi_cmd_flush_uploads :: proc(b: ^Backend, cmd: rhi.CommandList) {}

@(private = "file")
texture_view_of :: proc(b: ^Backend, texture: rhi.TextureHandle) -> wgpu.TextureView {
  return b.surface_output if texture == rhi.BACKBUFFER else b.textures[texture].view
}

// WebGPU has no undefined load: DONT_CARE clears.
@(private = "file")
load_op :: proc(op: rhi.LoadOp) -> wgpu.LoadOp {
  switch op {
  case .LOAD:      return .Load
  case .CLEAR:     return .Clear
  case .DONT_CARE: return .Clear
  }
  return .Load
}

rhi_cmd_begin_pass :: proc(b: ^Backend, cmd: rhi.CommandList, desc: rhi.PassDesc) {
  state := &b.cmds[cmd]
  colors := make([]wgpu.RenderPassColorAttachment, len(desc.colors), context.temp_allocator)
  for c, i in desc.colors {
    colors[i] = {
      view       = texture_view_of(b, c.texture),
      depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
      loadOp     = load_op(c.load),
      storeOp    = .Store,
      clearValue = {f64(c.clear.r), f64(c.clear.g), f64(c.clear.b), f64(c.clear.a)},
    }
  }
  info := wgpu.RenderPassDescriptor{colorAttachmentCount = uint(len(colors)), colorAttachments = raw_data(colors)}
  depth: wgpu.RenderPassDepthStencilAttachment
  if target, ok := desc.depth.?; ok {
    view := texture_view_of(b, target.texture)
    if t := &b.textures[target.texture]; target.texture != rhi.BACKBUFFER && t.desc.layers > 1 {
      // one layer of the atlas
      view = wgpu.TextureCreateView(t.texture, &{dimension = ._2D, mipLevelCount = 1, baseArrayLayer = target.layer, arrayLayerCount = 1})
      append(&state.views, view)
    }
    depth = {view = view, depthClearValue = target.clear, depthReadOnly = b32(target.read_only)}
    if !target.read_only {
      depth.depthLoadOp = load_op(target.load)
      depth.depthStoreOp = .Store if target.store else .Discard
    }
    info.depthStencilAttachment = &depth
  }
  state.render = wgpu.CommandEncoderBeginRenderPass(state.encoder, &info)
}

rhi_cmd_end_pass :: proc(b: ^Backend, cmd: rhi.CommandList) {
  state := &b.cmds[cmd]
  wgpu.RenderPassEncoderEnd(state.render)
  wgpu.RenderPassEncoderRelease(state.render)
  state.render = nil
}

rhi_cmd_begin_compute :: proc(b: ^Backend, cmd: rhi.CommandList) {
  state := &b.cmds[cmd]
  state.compute = wgpu.CommandEncoderBeginComputePass(state.encoder)
}

rhi_cmd_end_compute :: proc(b: ^Backend, cmd: rhi.CommandList) {
  state := &b.cmds[cmd]
  wgpu.ComputePassEncoderEnd(state.compute)
  wgpu.ComputePassEncoderRelease(state.compute)
  state.compute = nil
}

rhi_cmd_bind_pipeline :: proc(b: ^Backend, cmd: rhi.CommandList, pipeline: rhi.Pipeline) {
  state := &b.cmds[cmd]
  p := &b.pipelines.items[pipeline]
  state.push_set = p.push_set
  if state.render != nil {
    wgpu.RenderPassEncoderSetPipeline(state.render, p.render)
  } else {
    wgpu.ComputePassEncoderSetPipeline(state.compute, p.compute)
  }
}

rhi_cmd_bind_group :: proc(b: ^Backend, cmd: rhi.CommandList, set: u32, group: rhi.BindGroup) {
  state := &b.cmds[cmd]
  g := b.groups.items[group].group
  if state.render != nil {
    wgpu.RenderPassEncoderSetBindGroup(state.render, set, g)
  } else {
    wgpu.ComputePassEncoderSetBindGroup(state.compute, set, g)
  }
}

// A debug group on the pass open, else on the encoder; it closes where it opened.
rhi_cmd_label_begin :: proc(b: ^Backend, cmd: rhi.CommandList, name: string) {
  state := &b.cmds[cmd]
  if state.render != nil {
    wgpu.RenderPassEncoderPushDebugGroup(state.render, name)
  } else if state.compute != nil {
    wgpu.ComputePassEncoderPushDebugGroup(state.compute, name)
  } else {
    wgpu.CommandEncoderPushDebugGroup(state.encoder, name)
  }
}

rhi_cmd_label_end :: proc(b: ^Backend, cmd: rhi.CommandList) {
  state := &b.cmds[cmd]
  if state.render != nil {
    wgpu.RenderPassEncoderPopDebugGroup(state.render)
  } else if state.compute != nil {
    wgpu.ComputePassEncoderPopDebugGroup(state.compute)
  } else {
    wgpu.CommandEncoderPopDebugGroup(state.encoder)
  }
}

// WebGPU has no bindless arrays.
rhi_cmd_bind_bindless :: proc(b: ^Backend, cmd: rhi.CommandList) {}

// Writes data to the next entry of the uniform ring and binds the push group at its offset.
rhi_cmd_push :: proc(b: ^Backend, cmd: rhi.CommandList, data: rawptr, size: u32) {
  state := &b.cmds[cmd]
  assert(size <= UNIFORM_ALIGNMENT)
  offset := b.uniform_cursor
  assert(offset + UNIFORM_ALIGNMENT <= UNIFORM_CAPACITY, "uniform ring full")
  if size > 0 do mem.copy(&b.uniforms[offset], data, int(size))
  b.uniform_cursor += UNIFORM_ALIGNMENT
  if state.render != nil {
    wgpu.RenderPassEncoderSetBindGroup(state.render, state.push_set, b.frame_group, {u32(offset)})
  } else {
    wgpu.ComputePassEncoderSetBindGroup(state.compute, state.push_set, b.frame_group, {u32(offset)})
  }
}

rhi_cmd_set_scissor :: proc(b: ^Backend, cmd: rhi.CommandList, x, y, w, h: u32) {
  wgpu.RenderPassEncoderSetScissorRect(b.cmds[cmd].render, x, y, w, h)
}

rhi_cmd_set_viewport :: proc(b: ^Backend, cmd: rhi.CommandList, x, y, w, h: u32) {
  wgpu.RenderPassEncoderSetViewport(b.cmds[cmd].render, f32(x), f32(y), f32(w), f32(h), 0, 1)
}

rhi_cmd_bind_vertex :: proc(b: ^Backend, cmd: rhi.CommandList, slot: u32, buffer: rhi.Buffer, offset: int) {
  state := &b.cmds[cmd]
  buf := b.buffers.items[buffer]
  wgpu.RenderPassEncoderSetVertexBuffer(state.render, slot, buf, u64(offset), wgpu.BufferGetSize(buf) - u64(offset))
}

rhi_cmd_bind_index :: proc(b: ^Backend, cmd: rhi.CommandList, buffer: rhi.Buffer, offset: int) {
  state := &b.cmds[cmd]
  buf := b.buffers.items[buffer]
  wgpu.RenderPassEncoderSetIndexBuffer(state.render, buf, .Uint32, u64(offset), wgpu.BufferGetSize(buf) - u64(offset))
}

rhi_cmd_draw :: proc(b: ^Backend, cmd: rhi.CommandList, vertex_count, instance_count, first_vertex, first_instance: u32) {
  wgpu.RenderPassEncoderDraw(b.cmds[cmd].render, vertex_count, instance_count, first_vertex, first_instance)
}

rhi_cmd_draw_indexed :: proc(b: ^Backend, cmd: rhi.CommandList, index_count, instance_count, first_index: u32, vertex_offset: i32, first_instance: u32) {
  wgpu.RenderPassEncoderDrawIndexed(b.cmds[cmd].render, index_count, instance_count, first_index, vertex_offset, first_instance)
}

// A draw each: render's commands are 5 words apart, and a non-indexed multi-draw reads them
// 4 words apart.
rhi_cmd_draw_indirect :: proc(b: ^Backend, cmd: rhi.CommandList, buffer: rhi.Buffer, offset: int, draw_count, stride: u32) {
  render, buf := b.cmds[cmd].render, b.buffers.items[buffer]
  for i in 0 ..< draw_count do wgpu.RenderPassEncoderDrawIndirect(render, buf, u64(offset) + u64(i) * u64(stride))
}

// Natively consecutive commands are one multi-draw (wgpu-native has it on every adapter, in
// hardware or not); the web, or commands apart, take a draw each.
rhi_cmd_draw_indexed_indirect :: proc(b: ^Backend, cmd: rhi.CommandList, buffer: rhi.Buffer, offset: int, draw_count, stride: u32) {
  render, buf := b.cmds[cmd].render, b.buffers.items[buffer]
  when ODIN_OS != .JS {
    if draw_count > 1 && stride == 5 * size_of(u32) {
      wgpu.RenderPassEncoderMultiDrawIndexedIndirect(render, buf, u64(offset), draw_count)
      return
    }
  }
  for i in 0 ..< draw_count do wgpu.RenderPassEncoderDrawIndexedIndirect(render, buf, u64(offset) + u64(i) * u64(stride))
}

// Caps.multi_draw_indirect_count is false: callers branch on it.
rhi_cmd_draw_indexed_indirect_count :: proc(
  b: ^Backend,
  cmd: rhi.CommandList,
  buffer: rhi.Buffer,
  offset: int,
  count_buffer: rhi.Buffer,
  count_offset: int,
  max_count, stride: u32,
) {
  log.errorf("WebGPU has no indirect count draws (Caps.multi_draw_indirect_count)")
}

rhi_cmd_dispatch :: proc(b: ^Backend, cmd: rhi.CommandList, x, y, z: u32) {
  wgpu.ComputePassEncoderDispatchWorkgroups(b.cmds[cmd].compute, x, y, z)
}

rhi_cmd_dispatch_indirect :: proc(b: ^Backend, cmd: rhi.CommandList, buffer: rhi.Buffer, offset: int) {
  wgpu.ComputePassEncoderDispatchWorkgroupsIndirect(b.cmds[cmd].compute, b.buffers.items[buffer], u64(offset))
}

// Outside any pass; zeroes the range (WebGPU fills nothing else).
rhi_cmd_fill_buffer :: proc(b: ^Backend, cmd: rhi.CommandList, buffer: rhi.Buffer, offset, size: int) {
  wgpu.CommandEncoderClearBuffer(b.cmds[cmd].encoder, b.buffers.items[buffer], u64(offset), u64(size))
}

// Caps.backbuffer_copy is false: the surface is not a copy source.
rhi_cmd_copy_backbuffer :: proc(b: ^Backend, cmd: rhi.CommandList, dst: rhi.Buffer) {}

rhi_cmd_copy_buffer :: proc(b: ^Backend, cmd: rhi.CommandList, src: rhi.Buffer, src_offset: int, dst: rhi.Buffer, dst_offset, size: int) {
  target := b.buffers.items[dst]
  if dst in b.readbacks {
    target = nil
    rb := &b.readbacks[dst]
    for &s in rb.slots do if !s.pending {
      target = s.buffer
      s.pending, s.copied = true, true
      break
    }
    // every entry is still mapping: skip this copy
    if target == nil do return
  }
  wgpu.CommandEncoderCopyBufferToBuffer(
    b.cmds[cmd].encoder,
    b.buffers.items[src],
    u64(src_offset),
    target,
    u64(dst_offset),
    u64(size),
  )
}

// WebGPU orders and flushes on its own.
rhi_cmd_barrier :: proc(b: ^Backend, cmd: rhi.CommandList, barriers: []rhi.Barrier, discards: []rhi.TextureHandle) {}

// Releases what rhi made that shutdown has not: buffers, layouts, groups and pipelines.
@(private)
rhi_shutdown :: proc(b: ^Backend) {
  // a readback's ring holds the buffer b.buffers names
  for handle, rb in b.readbacks {
    b.buffers.items[handle] = nil
    for s in rb.slots do wgpu.BufferRelease(s.buffer)
    delete(rb.data)
  }
  delete(b.readbacks)
  for &c in b.cmds do delete(c.views)
  for buffer in b.buffers.items do if buffer != nil do wgpu.BufferRelease(buffer)
  for layout in b.layouts.items do if layout != nil do wgpu.BindGroupLayoutRelease(layout)
  for &g in b.groups.items {
    if g.group != nil do wgpu.BindGroupRelease(g.group)
    for v in g.views do wgpu.TextureViewRelease(v)
    delete(g.views)
  }
  for p in b.pipelines.items {
    if p.render != nil do wgpu.RenderPipelineRelease(p.render)
    if p.compute != nil do wgpu.ComputePipelineRelease(p.compute)
  }
  rhi.pool_destroy(&b.buffers)
  rhi.pool_destroy(&b.layouts)
  rhi.pool_destroy(&b.groups)
  rhi.pool_destroy(&b.pipelines)
}
