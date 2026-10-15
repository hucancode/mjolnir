package wgpu_backend

import rhi "../rhi"

import "core:log"
import "core:mem"
import wgpu "vendor:wgpu"

// The backend's half of rhi's explicit contract (rhi/device.odin): PROCS is the conformance
// check, every proc below is one of its fields. WebGPU syncs on its own, so barriers are no-ops;
// it has no push constants, so cmd_push writes the pipeline's push group (the frame group:
// a dynamic-offset uniform, then every sampler) at the set after the pipeline's layouts, which
// every pipeline of this contract takes and every pass binds with cmd_push, even of size 0.

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

// The shaders of rhi.Shader, WGSL; entry points vs_main, fs_main and main.
@(private = "file")
SHADER_SOURCES := [rhi.Shader]string {
  .CULL                    = #load("shader/common.wgsl", string) + #load("shader/cull.wgsl", string),
  .DEPTH_REDUCE            = #load("shader/common.wgsl", string) + #load("shader/depth_reduce_from_mip.wgsl", string) + #load("shader/depth_reduce.wgsl", string),
  .DEPTH_REDUCE_FROM_DEPTH = #load("shader/common.wgsl", string) + #load("shader/depth_reduce_from_depth.wgsl", string) + #load("shader/depth_reduce.wgsl", string),
  .SHADOW_DEPTH            = #load("shader/common.wgsl", string) + #load("shader/shadow.wgsl", string),
}

// What rhi handles name: index 0 of every pool is none. Released slots are reused.
@(private)
RhiState :: struct {
  buffers:     [dynamic]wgpu.Buffer,
  layouts:     [dynamic]wgpu.BindGroupLayout,
  groups:      [dynamic]RhiGroup,
  pipelines:   [dynamic]RhiPipeline,
  free:        struct {
    buffers, layouts, groups, pipelines: [dynamic]u32,
  },
  // the frame frame_begin acquired
  surface:     wgpu.Texture,
  output:      wgpu.TextureView,
  // bytes of the uniform ring already written to the queue this frame
  flushed:     int,
  // per queue: the value the next submission signals
  next_value:  [rhi.Queue]u64,
}

@(private)
RhiGroup :: struct {
  group: wgpu.BindGroup,
  // views made for it, released with it
  views: [dynamic]wgpu.TextureView,
}

@(private)
RhiPipeline :: struct {
  render:   wgpu.RenderPipeline,
  compute:  wgpu.ComputePipeline,
  // the set of the push group
  push_set: u32,
}

// One command list: an encoder and the pass open on it.
@(private)
CmdState :: struct {
  encoder:  wgpu.CommandEncoder,
  render:   wgpu.RenderPassEncoder,
  compute:  wgpu.ComputePassEncoder,
  finished: wgpu.CommandBuffer,
  push_set: u32,
}

@(private = "file")
slot_take :: proc(pool: ^[dynamic]$T, free: ^[dynamic]u32) -> u32 {
  if len(pool) == 0 do append(pool, T{})
  if len(free) > 0 do return pop(free)
  append(pool, T{})
  return u32(len(pool) - 1)
}

rhi_caps :: proc(b: ^Backend) -> rhi.Caps {
  return {
    frames_in_flight  = FRAMES_IN_FLIGHT,
    retire_grace      = RETIRE_GRACE,
    uniform_alignment = UNIFORM_ALIGNMENT,
  }
}

rhi_buffer_create :: proc(b: ^Backend, desc: rhi.BufferDesc) -> (rhi.Buffer, bool) {
  usage := wgpu.BufferUsageFlags{.CopyDst}
  for u in desc.usage {
    switch u {
    case .STORAGE:  usage += {.Storage}
    case .UNIFORM:  usage += {.Uniform}
    case .VERTEX:   usage += {.Vertex}
    case .INDEX:    usage += {.Index}
    case .INDIRECT: usage += {.Indirect}
    case .COPY_SRC: usage += {.CopySrc}
    case .COPY_DST:
    }
  }
  buffer := buffer_create(b, max(desc.size, 16), usage)
  if buffer == nil do return 0, false
  slot := slot_take(&b.rhi.buffers, &b.rhi.free.buffers)
  b.rhi.buffers[slot] = buffer
  return rhi.Buffer(slot), true
}

// WebGPU keeps a released buffer alive for work already submitted.
rhi_buffer_retire :: proc(b: ^Backend, buffer: rhi.Buffer) {
  if buffer == 0 do return
  wgpu.BufferRelease(b.rhi.buffers[buffer])
  b.rhi.buffers[buffer] = nil
  append(&b.rhi.free.buffers, u32(buffer))
}

rhi_buffer_write :: proc(b: ^Backend, buffer: rhi.Buffer, offset: int, data: []u8) -> bool {
  if len(data) == 0 do return true
  // WriteBuffer takes 4-byte multiples
  size := (len(data) + 3) &~ 3
  if size == len(data) {
    wgpu.QueueWriteBuffer(b.queue, b.rhi.buffers[buffer], u64(offset), raw_data(data), uint(size))
    return true
  }
  padded := make([]u8, size, context.temp_allocator)
  copy(padded, data)
  wgpu.QueueWriteBuffer(b.queue, b.rhi.buffers[buffer], u64(offset), raw_data(padded), uint(size))
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
    case .UNIFORM_BUFFER:        entry.buffer = {type = .Uniform}
    case .TEXTURE_FLOAT:         entry.texture = {sampleType = .Float, viewDimension = ._2D}
    case .TEXTURE_UNFILTERABLE:  entry.texture = {sampleType = .UnfilterableFloat, viewDimension = ._2D}
    case .TEXTURE_DEPTH:         entry.texture = {sampleType = .Depth, viewDimension = ._2D}
    case .TEXTURE_CUBE:          entry.texture = {sampleType = .Float, viewDimension = .Cube}
    case .TEXTURE_DEPTH_ARRAY:   entry.texture = {sampleType = .Depth, viewDimension = ._2DArray}
    case .STORAGE_TEXTURE:       entry.storageTexture = {access = .WriteOnly, format = .R32Float, viewDimension = ._2D}
    }
    entries[i] = entry
  }
  layout := wgpu.DeviceCreateBindGroupLayout(b.device, &{entryCount = uint(len(entries)), entries = raw_data(entries)})
  if layout == nil do return 0, false
  slot := slot_take(&b.rhi.layouts, &b.rhi.free.layouts)
  b.rhi.layouts[slot] = layout
  return rhi.BindLayout(slot), true
}

rhi_bind_group_create :: proc(b: ^Backend, desc: rhi.BindGroupDesc) -> (rhi.BindGroup, bool) {
  entries := make([]wgpu.BindGroupEntry, len(desc.resources), context.temp_allocator)
  slot := slot_take(&b.rhi.groups, &b.rhi.free.groups)
  group := &b.rhi.groups[slot]
  for r, i in desc.resources {
    entries[i].binding = u32(i)
    switch v in r {
    case rhi.BufferRange:
      buffer := b.rhi.buffers[v.buffer]
      size := u64(v.size) if v.size > 0 else wgpu.BufferGetSize(buffer) - u64(v.offset)
      entries[i].buffer = buffer
      entries[i].offset = u64(v.offset)
      entries[i].size = size
    case rhi.TextureView:
      t := &b.textures[v.texture]
      if v.mip < 0 {
        entries[i].textureView = t.view
      } else {
        view := wgpu.TextureCreateView(t.texture, &{dimension = ._2D, baseMipLevel = u32(v.mip), mipLevelCount = 1, arrayLayerCount = 1})
        append(&group.views, view)
        entries[i].textureView = view
      }
    }
  }
  layout := b.rhi.layouts[desc.layout]
  group.group = wgpu.DeviceCreateBindGroup(b.device, &{layout = layout, entryCount = uint(len(entries)), entries = raw_data(entries)})
  if group.group == nil {
    rhi_bind_group_retire(b, rhi.BindGroup(slot))
    return 0, false
  }
  return rhi.BindGroup(slot), true
}

rhi_bind_group_retire :: proc(b: ^Backend, handle: rhi.BindGroup) {
  if handle == 0 do return
  group := &b.rhi.groups[handle]
  if group.group != nil do wgpu.BindGroupRelease(group.group)
  for view in group.views do wgpu.TextureViewRelease(view)
  delete(group.views)
  group^ = {}
  append(&b.rhi.free.groups, u32(handle))
}

// The layouts of desc, then the push group.
@(private = "file")
pipeline_layout_make :: proc(b: ^Backend, desc: rhi.PipelineLayoutDesc) -> (wgpu.PipelineLayout, u32) {
  layouts := make([]wgpu.BindGroupLayout, len(desc.layouts) + 1, context.temp_allocator)
  for l, i in desc.layouts do layouts[i] = b.rhi.layouts[l]
  layouts[len(desc.layouts)] = b.frame_layout
  layout := wgpu.DeviceCreatePipelineLayout(b.device, &{bindGroupLayoutCount = uint(len(layouts)), bindGroupLayouts = raw_data(layouts)})
  return layout, u32(len(desc.layouts))
}

@(private = "file")
pipeline_store :: proc(b: ^Backend, p: RhiPipeline) -> rhi.Pipeline {
  slot := slot_take(&b.rhi.pipelines, &b.rhi.free.pipelines)
  b.rhi.pipelines[slot] = p
  return rhi.Pipeline(slot)
}

rhi_compute_pipeline_create :: proc(b: ^Backend, desc: rhi.ComputePipelineDesc) -> (rhi.Pipeline, bool) {
  module := shader_module(b, SHADER_SOURCES[desc.shader])
  defer wgpu.ShaderModuleRelease(module)
  layout, push_set := pipeline_layout_make(b, desc.layout)
  defer wgpu.PipelineLayoutRelease(layout)
  pipeline := wgpu.DeviceCreateComputePipeline(b.device, &{layout = layout, compute = {module = module, entryPoint = "main"}})
  if pipeline == nil {
    log.errorf("Compute pipeline %v creation failed", desc.shader)
    return 0, false
  }
  return pipeline_store(b, {compute = pipeline, push_set = push_set}), true
}

@(private = "file")
VERTEX_FORMATS := [rhi.VertexFormat]wgpu.VertexFormat {
  .F32X2 = .Float32x2,
  .F32X3 = .Float32x3,
  .F32X4 = .Float32x4,
  .U32   = .Uint32,
}

rhi_graphics_pipeline_create :: proc(b: ^Backend, desc: rhi.GraphicsPipelineDesc) -> (rhi.Pipeline, bool) {
  module := shader_module(b, SHADER_SOURCES[desc.shader])
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
    targets[i] = {format = FORMATS[format], blend = blend, writeMask = wgpu.ColorWriteMaskFlags_All}
  }
  fragment := wgpu.FragmentState{module = module, entryPoint = "fs_main", targetCount = uint(len(targets)), targets = raw_data(targets)}
  depth_state: wgpu.DepthStencilState
  state, has_depth := desc.depth.?
  if has_depth {
    depth_state = {
      format              = .Depth32Float,
      depthWriteEnabled   = .True if state.write else .False,
      depthCompare        = .LessEqual if state.compare == .LESS_EQUAL else .Always,
      stencilFront        = {compare = .Always},
      stencilBack         = {compare = .Always},
      depthBiasSlopeScale = state.slope_bias,
    }
  }
  pipeline := wgpu.DeviceCreateRenderPipeline(
    b.device,
    &{
      layout = layout,
      vertex = {module = module, entryPoint = "vs_main", bufferCount = uint(len(buffers)), buffers = raw_data(buffers)},
      primitive = {
        topology  = .TriangleList if desc.topology == .TRIANGLE_LIST else .LineList,
        frontFace = FRONT_FACE,
        cullMode  = .Back if desc.cull == .BACK else .None,
      },
      depthStencil = &depth_state if has_depth else nil,
      multisample = {count = 1, mask = 0xFFFFFFFF},
      fragment = &fragment if len(targets) > 0 else nil,
    },
  )
  if pipeline == nil {
    log.errorf("Render pipeline %v creation failed", desc.shader)
    return 0, false
  }
  return pipeline_store(b, {render = pipeline, push_set = push_set}), true
}

rhi_pipeline_retire :: proc(b: ^Backend, handle: rhi.Pipeline) {
  if handle == 0 do return
  p := &b.rhi.pipelines[handle]
  if p.render != nil do wgpu.RenderPipelineRelease(p.render)
  if p.compute != nil do wgpu.ComputePipelineRelease(p.compute)
  p^ = {}
  append(&b.rhi.free.pipelines, u32(handle))
}

// Queue order is the only sync: no frame slot to wait for.
rhi_frame_wait :: proc(b: ^Backend) -> bool {
  return b.up
}

rhi_frame_begin :: proc(b: ^Backend, framebuffer_size: [2]u32) -> (rhi.Frame, rhi.FrameStatus) {
  if !b.up do return {}, .ERROR
  events_process(b)
  if ([2]u32{max(framebuffer_size.x, 1), max(framebuffer_size.y, 1)}) != b.surface_extent do return {}, .RESIZE
  surface_texture := surface_texture_get(b)
  #partial switch surface_texture.status {
  case .SuccessOptimal, .SuccessSuboptimal:
  case .Timeout, .Outdated, .Lost, .Occluded:
    if surface_texture.texture != nil do wgpu.TextureRelease(surface_texture.texture)
    return {}, .RESIZE
  case:
    log.errorf("WebGPU surface texture: %v", surface_texture.status)
    return {}, .ERROR
  }
  b.rhi.surface = surface_texture.texture
  b.rhi.output = wgpu.TextureCreateView(
    surface_texture.texture,
    &{format = b.surface_view_format, dimension = ._2D, mipLevelCount = 1, arrayLayerCount = 1},
  )
  return {index = 0}, .OK
}

// Submits the finished lists in order on the one queue; waits are already satisfied by it. The
// uniforms written so far go first.
rhi_submit :: proc(b: ^Backend, queue: rhi.Queue, cmds: []rhi.CommandList, wait: []rhi.SyncPoint) -> rhi.SyncPoint {
  if b.uniform_cursor > b.rhi.flushed {
    wgpu.QueueWriteBuffer(
      b.queue,
      b.uniform_buffer,
      u64(b.rhi.flushed),
      &b.uniforms[b.rhi.flushed],
      uint(b.uniform_cursor - b.rhi.flushed),
    )
    b.rhi.flushed = b.uniform_cursor
  }
  buffers := make([]wgpu.CommandBuffer, len(cmds), context.temp_allocator)
  for c, i in cmds do buffers[i] = (^CmdState)(c).finished
  wgpu.QueueSubmit(b.queue, buffers)
  for c in cmds {
    state := (^CmdState)(c)
    wgpu.CommandBufferRelease(state.finished)
    wgpu.CommandEncoderRelease(state.encoder)
    free(state)
  }
  b.rhi.next_value[queue] += 1
  return {queue, b.rhi.next_value[queue]}
}

rhi_frame_present :: proc(b: ^Backend, frame: rhi.Frame) -> rhi.FrameStatus {
  wgpu.SurfacePresent(b.surface)
  wgpu.TextureViewRelease(b.rhi.output)
  wgpu.TextureRelease(b.rhi.surface)
  b.rhi.output, b.rhi.surface = nil, nil
  b.uniform_cursor, b.rhi.flushed = 0, 0
  b.frame_serial += 1
  return .OK
}

rhi_cmd_begin :: proc(b: ^Backend, queue: rhi.Queue) -> rhi.CommandList {
  state := new(CmdState)
  state.encoder = wgpu.DeviceCreateCommandEncoder(b.device)
  return rhi.CommandList(state)
}

rhi_cmd_end :: proc(b: ^Backend, cmd: rhi.CommandList) {
  state := (^CmdState)(cmd)
  state.finished = wgpu.CommandEncoderFinish(state.encoder)
}

@(private = "file")
texture_view_of :: proc(b: ^Backend, texture: rhi.TextureHandle) -> wgpu.TextureView {
  return b.rhi.output if texture == rhi.BACKBUFFER else b.textures[texture].view
}

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
  state := (^CmdState)(cmd)
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
    depth = {view = texture_view_of(b, target.texture), depthClearValue = target.clear, depthReadOnly = b32(target.read_only)}
    if !target.read_only {
      depth.depthLoadOp = load_op(target.load)
      depth.depthStoreOp = .Store if target.store else .Discard
    }
    info.depthStencilAttachment = &depth
  }
  state.render = wgpu.CommandEncoderBeginRenderPass(state.encoder, &info)
}

rhi_cmd_end_pass :: proc(b: ^Backend, cmd: rhi.CommandList) {
  state := (^CmdState)(cmd)
  wgpu.RenderPassEncoderEnd(state.render)
  wgpu.RenderPassEncoderRelease(state.render)
  state.render = nil
}

rhi_cmd_begin_compute :: proc(b: ^Backend, cmd: rhi.CommandList) {
  state := (^CmdState)(cmd)
  state.compute = wgpu.CommandEncoderBeginComputePass(state.encoder)
}

rhi_cmd_end_compute :: proc(b: ^Backend, cmd: rhi.CommandList) {
  state := (^CmdState)(cmd)
  wgpu.ComputePassEncoderEnd(state.compute)
  wgpu.ComputePassEncoderRelease(state.compute)
  state.compute = nil
}

rhi_cmd_bind_pipeline :: proc(b: ^Backend, cmd: rhi.CommandList, pipeline: rhi.Pipeline) {
  state := (^CmdState)(cmd)
  p := &b.rhi.pipelines[pipeline]
  state.push_set = p.push_set
  if state.render != nil {
    wgpu.RenderPassEncoderSetPipeline(state.render, p.render)
  } else {
    wgpu.ComputePassEncoderSetPipeline(state.compute, p.compute)
  }
}

rhi_cmd_bind_group :: proc(b: ^Backend, cmd: rhi.CommandList, set: u32, group: rhi.BindGroup) {
  state := (^CmdState)(cmd)
  g := b.rhi.groups[group].group
  if state.render != nil {
    wgpu.RenderPassEncoderSetBindGroup(state.render, set, g)
  } else {
    wgpu.ComputePassEncoderSetBindGroup(state.compute, set, g)
  }
}

// WebGPU has no bindless arrays.
rhi_cmd_bind_bindless :: proc(b: ^Backend, cmd: rhi.CommandList) {}

// Writes data to the next entry of the uniform ring and binds the push group at its offset.
rhi_cmd_push :: proc(b: ^Backend, cmd: rhi.CommandList, data: rawptr, size: u32) {
  state := (^CmdState)(cmd)
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

rhi_cmd_bind_vertex :: proc(b: ^Backend, cmd: rhi.CommandList, slot: u32, buffer: rhi.Buffer, offset: int) {
  state := (^CmdState)(cmd)
  buf := b.rhi.buffers[buffer]
  wgpu.RenderPassEncoderSetVertexBuffer(state.render, slot, buf, u64(offset), wgpu.BufferGetSize(buf) - u64(offset))
}

rhi_cmd_bind_index :: proc(b: ^Backend, cmd: rhi.CommandList, buffer: rhi.Buffer, offset: int) {
  state := (^CmdState)(cmd)
  buf := b.rhi.buffers[buffer]
  wgpu.RenderPassEncoderSetIndexBuffer(state.render, buf, .Uint32, u64(offset), wgpu.BufferGetSize(buf) - u64(offset))
}

rhi_cmd_draw :: proc(b: ^Backend, cmd: rhi.CommandList, vertex_count, instance_count, first_vertex, first_instance: u32) {
  wgpu.RenderPassEncoderDraw((^CmdState)(cmd).render, vertex_count, instance_count, first_vertex, first_instance)
}

rhi_cmd_draw_indexed :: proc(b: ^Backend, cmd: rhi.CommandList, index_count, instance_count, first_index: u32, vertex_offset: i32, first_instance: u32) {
  wgpu.RenderPassEncoderDrawIndexed((^CmdState)(cmd).render, index_count, instance_count, first_index, vertex_offset, first_instance)
}

rhi_cmd_draw_indirect :: proc(b: ^Backend, cmd: rhi.CommandList, buffer: rhi.Buffer, offset: int) {
  wgpu.RenderPassEncoderDrawIndirect((^CmdState)(cmd).render, b.rhi.buffers[buffer], u64(offset))
}

rhi_cmd_draw_indexed_indirect :: proc(b: ^Backend, cmd: rhi.CommandList, buffer: rhi.Buffer, offset: int) {
  wgpu.RenderPassEncoderDrawIndexedIndirect((^CmdState)(cmd).render, b.rhi.buffers[buffer], u64(offset))
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
  wgpu.ComputePassEncoderDispatchWorkgroups((^CmdState)(cmd).compute, x, y, z)
}

// Outside any pass; zeroes the range (WebGPU fills nothing else).
rhi_cmd_fill_buffer :: proc(b: ^Backend, cmd: rhi.CommandList, buffer: rhi.Buffer, offset, size: int) {
  wgpu.CommandEncoderClearBuffer((^CmdState)(cmd).encoder, b.rhi.buffers[buffer], u64(offset), u64(size))
}

rhi_cmd_copy_buffer :: proc(b: ^Backend, cmd: rhi.CommandList, src: rhi.Buffer, src_offset: int, dst: rhi.Buffer, dst_offset, size: int) {
  wgpu.CommandEncoderCopyBufferToBuffer(
    (^CmdState)(cmd).encoder,
    b.rhi.buffers[src],
    u64(src_offset),
    b.rhi.buffers[dst],
    u64(dst_offset),
    u64(size),
  )
}

// WebGPU orders and flushes on its own.
rhi_cmd_barrier :: proc(b: ^Backend, cmd: rhi.CommandList, barrier: rhi.Barrier) {}

rhi_cmd_texture_discard :: proc(b: ^Backend, cmd: rhi.CommandList, textures: []rhi.TextureHandle) {}
