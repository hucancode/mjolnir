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

// CommandList names a command buffer (Vulkan) or encoder (WebGPU) being recorded.
CommandList :: distinct u32

// BACKBUFFER stands for the image frame_begin acquired wherever a TextureHandle names a pass
// target. One command list per frame renders into it, and that list leaves it ready to present.
BACKBUFFER :: TextureHandle(max(u32))

Queue :: enum {
  GRAPHICS,
  COMPUTE,
}

// SyncPoint is reached when `queue` has completed the submission that signalled `value`. As a
// wait, `stages` are the ones of the waiting submission that hold until then (none: all).
SyncPoint :: struct {
  queue:  Queue,
  value:  u64,
  stages: bit_set[Stage],
}

// What the device can do, known once it is up; what a backend always can or cannot do is its
// compile-time constants (BINDLESS, LAYERED_RENDERING). render branches on these.
Caps :: struct {
  multi_draw_indirect_count: bool,
  // the COMPUTE queue runs beside the GRAPHICS one, ordered only by the SyncPoints a submission
  // waits on. When false a COMPUTE list is recorded into the graphics list instead.
  async_compute:             bool,
  // an indirect draw's first instance offsets its instance-rate vertex streams; when false it
  // must be 0 (core WebGPU without indirect-first-instance)
  indirect_first_instance:   bool,
  // label scopes are timed on the GPU (frame_timings)
  timestamps:                bool,
}

// Threads that may record command lists at once: cmd_begin's `thread` is below it.
MAX_RECORD_THREADS :: 8

// Timing is a label scope's GPU time, in milliseconds. `depth` is how many scopes enclose it.
Timing :: struct {
  name:  string,
  queue: Queue,
  depth: u32,
  ms:    f32,
}

// SubmitDesc is one submission: `cmds` in order on `queue` once `waits` are reached. `present`
// makes it the frame's presenting submission: it waits for the image frame_begin acquired and
// frame_present waits for it; exactly one submission per frame presents.
SubmitDesc :: struct {
  queue:   Queue,
  cmds:    []CommandList,
  waits:   []SyncPoint,
  present: bool,
}

BufferUsage :: enum {
  STORAGE,
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
  // GPU-written, CPU-read (buffer_read)
  READBACK,
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
// beside them; storage textures are write-only, one mip, of BindEntry.format.
BindKind :: enum {
  STORAGE_BUFFER,
  STORAGE_BUFFER_READ,
  TEXTURE_FLOAT,
  TEXTURE_UNFILTERABLE,
  TEXTURE_DEPTH,
  TEXTURE_CUBE,
  TEXTURE_DEPTH_ARRAY,
  STORAGE_TEXTURE,
  // a mip of a cube seen as six layers
  STORAGE_TEXTURE_ARRAY,
}

BindEntry :: struct {
  kind:   BindKind,
  stages: bit_set[ShaderStage],
  // the texel format of a storage texture
  format: TextureFormat,
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

// TextureView names one mip of a texture; `mip` -1 is every mip (the texture's own view: a
// cube as a cube, a layered texture as an array).
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

// A shader in the form each backend takes: SPIR-V per stage (entry point "main") or one WGSL
// module (entry points vs_main, fs_main, main). A pass loads only its backend's form.
ShaderSource :: struct {
  spirv: struct {
    vert, frag, comp: []u8,
  },
  wgsl:  string,
}

VertexStep :: enum {
  VERTEX,
  INSTANCE,
}

VertexFormat :: enum {
  UNORM8X4,
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
  POINT_LIST,
}

CullMode :: enum {
  NONE,
  BACK,
  FRONT,
}

BlendMode :: enum {
  NONE,
  ALPHA,
  ADDITIVE,
}

CompareOp :: enum {
  LESS_EQUAL,
  ALWAYS,
  GREATER,
  GREATER_EQUAL,
}

DepthState :: struct {
  write:      bool,
  compare:    CompareOp,
  // clamp depth instead of clipping at the near and far planes, where the API can (not WebGPU)
  clamp:      bool,
  // slope-scaled bias, 0 for none
  slope_bias: f32,
}

// PUSH_GROUP in PipelineLayoutDesc.layouts marks where the push group sits, on a backend
// without push constants (WebGPU); without it the group follows the last layout.
PUSH_GROUP :: BindLayout(max(u32))

// A pipeline's resource interface: `layouts` are sets 0 .. n - 1. With `bindless` (the backend's BINDLESS)
// the global texture arrays follow as set n. cmd_push writes `push_size` bytes of constants, or on a backend without push constants (WebGPU) to a push group that
// every pipeline has, whether or not it pushes (PUSH_GROUP).
PipelineLayoutDesc :: struct {
  layouts:   []BindLayout,
  push_size: u32,
  bindless:  bool,
}

ComputePipelineDesc :: struct {
  shader: ShaderSource,
  layout: PipelineLayoutDesc,
}

GraphicsPipelineDesc :: struct {
  shader:        ShaderSource,
  layout:        PipelineLayoutDesc,
  vertex:        []VertexBuffer,
  topology:      Topology,
  cull:          CullMode,
  color_formats: []TextureFormat,
  blend:         BlendMode,
  // a pipeline draws depth only when `depth` is set
  depth:         Maybe(DepthState),
  // shader constants by id (SPIR-V specialization constant id, WGSL @id), all u32
  constants:     []u32,
  // lines instead of filled triangles, where the API can (not WebGPU)
  wireframe:     bool,
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
  // first layer of a layered texture; PassDesc.layer_count layers from it
  layer:     u32,
  load:      LoadOp,
  clear:     f32,
  store:     bool,
  read_only: bool,
}

// PassDesc opens a render pass over its targets, viewport and scissor covering them.
PassDesc :: struct {
  colors:      []ColorTarget,
  depth:       Maybe(DepthTarget),
  // layers drawn into together (the backend's LAYERED_RENDERING) when above 1; 0 is 1
  layer_count: u32,
}

// The global arrays beside the textures (bindless_write), as the shaders index them.
BindlessArray :: enum {
  // storage images: a TextureView names one mip
  STORAGE_IMAGES,
  // indirect draw lists, storage buffers
  DRAW_LISTS,
  // one u32 per depth pyramid slot: its groups done
  PYRAMID_COUNTERS,
}

// Frame is one frame slot: `index` picks the copy of per-frame resources (below the backend's
// frames in flight).
Frame :: struct {
  index: u32,
}

// Procs is what a backend provides, over its device and window types. Each backend declares
// `PROCS :: rhi.Procs(Backend, WindowHandle){...}`: that assignment is the conformance check.
// render calls the backend's procs directly, so none of this costs a dispatch.
Procs :: struct($Device: typeid, $Window: typeid) {
  // lifecycle: init brings the device up on window (ready says when it is, the web finishes
  // later); shutdown destroys everything. wait_idle lands every upload and waits for the GPU,
  // then destroys what was retired. tick destroys what was retired RETIRE_GRACE frames ago,
  // once per frame. frame_serial counts presented frames; extent is the swapchain's size.
  init:                          proc(d: ^Device, app_name: string, window: Window, framebuffer_size: [2]u32) -> bool,
  ready:                         proc(d: ^Device) -> bool,
  shutdown:                      proc(d: ^Device),
  wait_idle:                     proc(d: ^Device),
  tick:                          proc(d: ^Device),
  frame_serial:                  proc(d: ^Device) -> u64,
  extent:                        proc(d: ^Device) -> [2]u32,
  resize:                        proc(d: ^Device, framebuffer_size: [2]u32) -> bool,

  caps:                          proc(d: ^Device) -> Caps,

  // resources: a texture's handle is picked by the caller; on a bindless device it is the
  // texture's index in the global arrays. `data` fills level 0 (the other levels are made).
  texture_create:                proc(d: ^Device, handle: TextureHandle, desc: TextureDesc, data: []u8) -> bool,
  // destroyed at once: the caller retires the handle first
  texture_destroy:               proc(d: ^Device, handle: TextureHandle),
  buffer_create:                 proc(d: ^Device, desc: BufferDesc) -> (Buffer, bool),
  // destroyed once no frame in flight can use it
  buffer_retire:                 proc(d: ^Device, buffer: Buffer),
  // UPLOAD buffers are written at once; GPU buffers are staged and land where the caller next
  // records cmd_flush_uploads
  buffer_write:                  proc(d: ^Device, buffer: Buffer, offset: int, data: []u8) -> bool,
  // BINDLESS: the textures of texture_create are in their own array already
  bindless_write:                proc(d: ^Device, array: BindlessArray, index: u32, resource: BindResource),
  // the last copy a READBACK buffer received from cmd_copy_buffer and a frame completed
  buffer_read:                   proc(d: ^Device, buffer: Buffer, offset: int, dst: []u8) -> bool,
  bind_layout_create:            proc(d: ^Device, desc: BindLayoutDesc) -> (BindLayout, bool),
  bind_group_create:             proc(d: ^Device, desc: BindGroupDesc) -> (BindGroup, bool),
  bind_group_retire:             proc(d: ^Device, group: BindGroup),
  compute_pipeline_create:       proc(d: ^Device, desc: ComputePipelineDesc) -> (Pipeline, bool),
  graphics_pipeline_create:      proc(d: ^Device, desc: GraphicsPipelineDesc) -> (Pipeline, bool),
  pipeline_retire:               proc(d: ^Device, pipeline: Pipeline),

  // frame pacing: wait for the frame slot (its previous submissions are done, its per-frame
  // resources may be rewritten), acquire, record, submit, present
  frame_wait:                    proc(d: ^Device) -> (Frame, bool),
  frame_begin:                   proc(d: ^Device, framebuffer_size: [2]u32) -> FrameStatus,
  submit:                        proc(d: ^Device, desc: SubmitDesc) -> SyncPoint,
  frame_present:                 proc(d: ^Device) -> FrameStatus,
  // Caps.timestamps: the label scopes of the frame slot frame_wait last waited for, in the order
  // they began; valid until the next frame_wait
  frame_timings:                 proc(d: ^Device) -> []Timing,

  // command recording. A list is the frame slot's: begun after frame_wait, reused once the slot
  // comes round again. `thread` (below MAX_RECORD_THREADS) is the recording thread's index.
  cmd_begin:                     proc(d: ^Device, queue: Queue, thread: u32) -> CommandList,
  cmd_end:                       proc(d: ^Device, cmd: CommandList),
  // records every staged write (buffer_write to GPU buffers, texture data) and makes it
  // visible to everything after it; first in the first list a frame submits
  cmd_flush_uploads:             proc(d: ^Device, cmd: CommandList),
  cmd_begin_pass:                proc(d: ^Device, cmd: CommandList, desc: PassDesc),
  cmd_end_pass:                  proc(d: ^Device, cmd: CommandList),
  // a compute scope: a pass on WebGPU, nothing on Vulkan
  cmd_begin_compute:             proc(d: ^Device, cmd: CommandList),
  cmd_end_compute:               proc(d: ^Device, cmd: CommandList),
  // a named scope for debuggers (RenderDoc, Xcode) and, with Caps.timestamps, timed. Scopes nest
  // and close in the list, pass or compute scope they opened in. `name` outlives the frame.
  cmd_label_begin:               proc(d: ^Device, cmd: CommandList, name: string),
  cmd_label_end:                 proc(d: ^Device, cmd: CommandList),
  cmd_bind_pipeline:             proc(d: ^Device, cmd: CommandList, pipeline: Pipeline),
  cmd_bind_group:                proc(d: ^Device, cmd: CommandList, set: u32, group: BindGroup),
  // the global bindless arrays (the backend's BINDLESS), at the set after the layouts of the pipeline
  // just bound (PipelineLayoutDesc.bindless)
  cmd_bind_bindless:             proc(d: ^Device, cmd: CommandList),
  cmd_push:                      proc(d: ^Device, cmd: CommandList, data: rawptr, size: u32),
  cmd_set_scissor:               proc(d: ^Device, cmd: CommandList, x, y, w, h: u32),
  // the viewport within the pass's targets, depth 0 to 1
  cmd_set_viewport:              proc(d: ^Device, cmd: CommandList, x, y, w, h: u32),
  cmd_bind_vertex:               proc(d: ^Device, cmd: CommandList, slot: u32, buffer: Buffer, offset: int),
  cmd_bind_index:                proc(d: ^Device, cmd: CommandList, buffer: Buffer, offset: int),
  cmd_draw:                      proc(d: ^Device, cmd: CommandList, vertex_count, instance_count, first_vertex, first_instance: u32),
  cmd_draw_indexed:              proc(d: ^Device, cmd: CommandList, index_count, instance_count, first_index: u32, vertex_offset: i32, first_instance: u32),
  // `draw_count` draws read from consecutive commands `stride` bytes apart
  cmd_draw_indirect:             proc(d: ^Device, cmd: CommandList, buffer: Buffer, offset: int, draw_count, stride: u32),
  cmd_draw_indexed_indirect:     proc(d: ^Device, cmd: CommandList, buffer: Buffer, offset: int, draw_count, stride: u32),
  // Caps.multi_draw_indirect_count: up to max_count draws, the count read at count_offset
  cmd_draw_indexed_indirect_count: proc(d: ^Device, cmd: CommandList, buffer: Buffer, offset: int, count_buffer: Buffer, count_offset: int, max_count, stride: u32),
  cmd_dispatch:                  proc(d: ^Device, cmd: CommandList, x, y, z: u32),
  // the group counts are three u32 at `offset` of an INDIRECT buffer
  cmd_dispatch_indirect:         proc(d: ^Device, cmd: CommandList, buffer: Buffer, offset: int),
  cmd_fill_buffer:               proc(d: ^Device, cmd: CommandList, buffer: Buffer, offset, size: int),
  cmd_copy_buffer:               proc(d: ^Device, cmd: CommandList, src: Buffer, src_offset: int, dst: Buffer, dst_offset, size: int),
  // one dependency: every barrier, and `discards`, textures about to be written whole whose old
  // contents are dropped (ordered after all earlier work)
  cmd_barrier:                   proc(d: ^Device, cmd: CommandList, barriers: []Barrier, discards: []TextureHandle),
}
