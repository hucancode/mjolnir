package rhi

// The explicit part of the contract: resources, pipelines, bindings, command recording, sync
// and frame pacing. render records every pass through these; a backend maps them onto its API
// and adds nothing the caller did not ask for. Where the APIs differ, Caps says so and render
// chooses (bindless or bind groups, one layered draw or a pass per view, ...); a backend never
// emulates a capability it lacks behind the caller's back.

// Handles are indices into a backend's pools; 0 is none.
Buffer :: distinct u32
Pipeline :: distinct u32
BindLayout :: distinct u32
BindGroup :: distinct u32

// CommandList is a command buffer (Vulkan) or encoder (WebGPU) being recorded.
CommandList :: distinct rawptr

// BACKBUFFER stands for the image frame_begin acquired wherever a TextureHandle names a pass
// target. One command list per frame renders into it, and that list leaves it ready to present.
BACKBUFFER :: TextureHandle(max(u32))

Queue :: enum {
  GRAPHICS,
  COMPUTE,
}

// SyncPoint is reached when `queue` has completed the submission that signalled `value`.
SyncPoint :: struct {
  queue: Queue,
  value: u64,
}

// What the device can do. render branches on these.
Caps :: struct {
  // textures and storage images reach shaders through global arrays indexed by handle
  bindless:                  bool,
  // cmd_push: small constants beside every draw or dispatch (Vulkan push constants; WebGPU
  // a dynamic-offset uniform ring in the pipeline's push group)
  push_constants:            bool,
  multi_draw_indirect_count: bool,
  // draws honour first_instance of indirect commands, so it can tag a draw
  indirect_first_instance:   bool,
  // one pass renders into several layers of a texture (PassDesc.layer_count)
  layered_rendering:         bool,
  // cmd_barrier and cmd_texture_discard do something: the caller owns hazards. When false the
  // queue order is the only sync and they are no-ops.
  explicit_barriers:         bool,
  // COMPUTE is a queue of its own
  async_compute:             bool,
  frames_in_flight:          u32,
  // frames a retired resource waits before it is destroyed
  retire_grace:              u32,
  // granularity of cmd_push offsets and uniform ring entries, in bytes
  uniform_alignment:         u32,
}

BufferUsage :: enum {
  STORAGE,
  UNIFORM,
  VERTEX,
  INDEX,
  INDIRECT,
  COPY_SRC,
  COPY_DST,
}

// Where a buffer lives: GPU is device-local and written through buffer_write (staged); UPLOAD
// is CPU-written and GPU-read, persistently mapped where the API allows.
MemoryKind :: enum {
  GPU,
  UPLOAD,
}

BufferDesc :: struct {
  size:   int,
  usage:  bit_set[BufferUsage],
  memory: MemoryKind,
}

Stage :: enum {
  DRAW_INDIRECT,
  VERTEX_SHADER,
  FRAGMENT_SHADER,
  COMPUTE_SHADER,
  EARLY_FRAGMENT_TESTS,
  LATE_FRAGMENT_TESTS,
  COLOR_ATTACHMENT_OUTPUT,
  TRANSFER,
}

Access :: enum {
  INDIRECT_READ,
  SHADER_READ,
  SHADER_WRITE,
  COLOR_ATTACHMENT_READ,
  COLOR_ATTACHMENT_WRITE,
  DEPTH_ATTACHMENT_READ,
  DEPTH_ATTACHMENT_WRITE,
  TRANSFER_READ,
  TRANSFER_WRITE,
}

// A global memory dependency: `dst_access` in `dst_stage` sees what `src_access` wrote in
// `src_stage`, for everything recorded before and after it on the queue.
Barrier :: struct {
  src_stage, dst_stage:   bit_set[Stage],
  src_access, dst_access: bit_set[Access],
}

ShaderStage :: enum {
  VERTEX,
  FRAGMENT,
  COMPUTE,
}

// BindKind is what a binding holds. Textures are sampled through the sampler the backend binds
// beside them; STORAGE_TEXTURE is write-only R32F.
BindKind :: enum {
  STORAGE_BUFFER,
  STORAGE_BUFFER_READ,
  UNIFORM_BUFFER,
  TEXTURE_FLOAT,
  TEXTURE_UNFILTERABLE,
  TEXTURE_DEPTH,
  TEXTURE_CUBE,
  TEXTURE_DEPTH_ARRAY,
  STORAGE_TEXTURE,
}

BindEntry :: struct {
  kind:   BindKind,
  stages: bit_set[ShaderStage],
}

// BindLayout binding i is entries[i].
BindLayoutDesc :: struct {
  entries: []BindEntry,
}

BufferRange :: struct {
  buffer: Buffer,
  offset: int,
  // 0 is to the end
  size:   int,
}

// TextureView names one mip of a texture; `mip` -1 is every mip.
TextureView :: struct {
  texture: TextureHandle,
  mip:     i32,
}

BindResource :: union {
  BufferRange,
  TextureView,
}

// BindGroup binding i is resources[i].
BindGroupDesc :: struct {
  layout:    BindLayout,
  resources: []BindResource,
}

// Shaders the backends ship, one source per backend (SPIR-V, WGSL); a backend leaves out one
// whose capability it lacks and pipeline creation fails for it. Grows as passes move into render.
Shader :: enum {
  // tests nodes against views and writes draws
  CULL,
  // builds a depth pyramid: all mips in one dispatch where Vulkan can, mip by mip otherwise
  DEPTH_REDUCE,
  // WebGPU's first reduce step, from the depth image rather than the mip above
  DEPTH_REDUCE_FROM_DEPTH,
  // depth-only vertex shader of the shadow maps
  SHADOW_DEPTH,
}

VertexStep :: enum {
  VERTEX,
  INSTANCE,
}

VertexFormat :: enum {
  F32X2,
  F32X3,
  F32X4,
  U32,
}

VertexAttribute :: struct {
  location: u32,
  format:   VertexFormat,
  offset:   u32,
}

VertexBuffer :: struct {
  stride:     u32,
  step:       VertexStep,
  attributes: []VertexAttribute,
}

Topology :: enum {
  TRIANGLE_LIST,
  LINE_LIST,
}

CullMode :: enum {
  NONE,
  BACK,
}

BlendMode :: enum {
  NONE,
  ALPHA,
  ADDITIVE,
}

CompareOp :: enum {
  LESS_EQUAL,
  ALWAYS,
}

DepthState :: struct {
  write:      bool,
  compare:    CompareOp,
  // clamp depth instead of clipping at the near and far planes, where the API can (not WebGPU)
  clamp:      bool,
  // slope-scaled bias, 0 for none
  slope_bias: f32,
}

// A pipeline's resource interface: `layouts` are sets 0 .. n - 1. With `bindless` (Caps.bindless)
// the global texture arrays follow as set n. cmd_push writes `push_size` bytes of constants
// (Caps.push_constants), or on a backend without them (WebGPU) to a push group that takes set
// n and that every pipeline has, whether or not it pushes.
PipelineLayoutDesc :: struct {
  layouts:   []BindLayout,
  push_size: u32,
  bindless:  bool,
}

ComputePipelineDesc :: struct {
  shader: Shader,
  layout: PipelineLayoutDesc,
}

GraphicsPipelineDesc :: struct {
  shader:        Shader,
  layout:        PipelineLayoutDesc,
  vertex:        []VertexBuffer,
  topology:      Topology,
  cull:          CullMode,
  color_formats: []TextureFormat,
  blend:         BlendMode,
  // a pipeline draws depth only when `depth` is set
  depth:         Maybe(DepthState),
}

LoadOp :: enum {
  LOAD,
  CLEAR,
  DONT_CARE,
}

ColorTarget :: struct {
  texture: TextureHandle,
  load:    LoadOp,
  clear:   [4]f32,
}

DepthTarget :: struct {
  texture:   TextureHandle,
  load:      LoadOp,
  clear:     f32,
  store:     bool,
  read_only: bool,
}

// PassDesc opens a render pass over its targets, viewport and scissor covering them.
PassDesc :: struct {
  colors: []ColorTarget,
  depth:  Maybe(DepthTarget),
}

// Frame is one acquired frame: `index` picks the copy of per-frame resources (below
// Caps.frames_in_flight).
Frame :: struct {
  index: u32,
}

// Procs is what a backend provides, over its device type. Each backend declares
// `PROCS :: rhi.Procs(Backend){...}`: that assignment is the conformance check. render calls the
// backend's procs directly, so none of this costs a dispatch.
Procs :: struct($Device: typeid) {
  caps:                          proc(d: ^Device) -> Caps,

  // resources
  buffer_create:                 proc(d: ^Device, desc: BufferDesc) -> (Buffer, bool),
  // destroyed once no frame in flight can use it
  buffer_retire:                 proc(d: ^Device, buffer: Buffer),
  // GPU buffers are written when the next command list is submitted; UPLOAD buffers at once
  buffer_write:                  proc(d: ^Device, buffer: Buffer, offset: int, data: []u8) -> bool,
  bind_layout_create:            proc(d: ^Device, desc: BindLayoutDesc) -> (BindLayout, bool),
  bind_group_create:             proc(d: ^Device, desc: BindGroupDesc) -> (BindGroup, bool),
  bind_group_retire:             proc(d: ^Device, group: BindGroup),
  compute_pipeline_create:       proc(d: ^Device, desc: ComputePipelineDesc) -> (Pipeline, bool),
  graphics_pipeline_create:      proc(d: ^Device, desc: GraphicsPipelineDesc) -> (Pipeline, bool),
  pipeline_retire:               proc(d: ^Device, pipeline: Pipeline),

  // frame pacing: wait for the frame slot, acquire, record, submit, present
  frame_wait:                    proc(d: ^Device) -> bool,
  frame_begin:                   proc(d: ^Device, framebuffer_size: [2]u32) -> (Frame, FrameStatus),
  submit:                        proc(d: ^Device, queue: Queue, cmds: []CommandList, wait: []SyncPoint) -> SyncPoint,
  frame_present:                 proc(d: ^Device, frame: Frame) -> FrameStatus,

  // command recording
  cmd_begin:                     proc(d: ^Device, queue: Queue) -> CommandList,
  cmd_end:                       proc(d: ^Device, cmd: CommandList),
  cmd_begin_pass:                proc(d: ^Device, cmd: CommandList, desc: PassDesc),
  cmd_end_pass:                  proc(d: ^Device, cmd: CommandList),
  // a compute scope: a pass on WebGPU, nothing on Vulkan
  cmd_begin_compute:             proc(d: ^Device, cmd: CommandList),
  cmd_end_compute:               proc(d: ^Device, cmd: CommandList),
  cmd_bind_pipeline:             proc(d: ^Device, cmd: CommandList, pipeline: Pipeline),
  cmd_bind_group:                proc(d: ^Device, cmd: CommandList, set: u32, group: BindGroup),
  // the global bindless arrays (Caps.bindless), at the set after the layouts of the pipeline
  // just bound (PipelineLayoutDesc.bindless)
  cmd_bind_bindless:             proc(d: ^Device, cmd: CommandList),
  cmd_push:                      proc(d: ^Device, cmd: CommandList, data: rawptr, size: u32),
  cmd_bind_vertex:               proc(d: ^Device, cmd: CommandList, slot: u32, buffer: Buffer, offset: int),
  cmd_bind_index:                proc(d: ^Device, cmd: CommandList, buffer: Buffer, offset: int),
  cmd_draw:                      proc(d: ^Device, cmd: CommandList, vertex_count, instance_count, first_vertex, first_instance: u32),
  cmd_draw_indexed:              proc(d: ^Device, cmd: CommandList, index_count, instance_count, first_index: u32, vertex_offset: i32, first_instance: u32),
  cmd_draw_indirect:             proc(d: ^Device, cmd: CommandList, buffer: Buffer, offset: int),
  cmd_draw_indexed_indirect:     proc(d: ^Device, cmd: CommandList, buffer: Buffer, offset: int),
  // Caps.multi_draw_indirect_count: up to max_count draws, the count read at count_offset
  cmd_draw_indexed_indirect_count: proc(d: ^Device, cmd: CommandList, buffer: Buffer, offset: int, count_buffer: Buffer, count_offset: int, max_count, stride: u32),
  cmd_dispatch:                  proc(d: ^Device, cmd: CommandList, x, y, z: u32),
  cmd_fill_buffer:               proc(d: ^Device, cmd: CommandList, buffer: Buffer, offset, size: int),
  cmd_copy_buffer:               proc(d: ^Device, cmd: CommandList, src: Buffer, src_offset: int, dst: Buffer, dst_offset, size: int),
  cmd_barrier:                   proc(d: ^Device, cmd: CommandList, barrier: Barrier),
  // textures about to be rendered into whole, their old contents dropped
  cmd_texture_discard:           proc(d: ^Device, cmd: CommandList, textures: []TextureHandle),
}
