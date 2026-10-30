package render

import "../geometry"

import "../containers"
import "core:log"
import "rhi"

// Your own GPU programs: buffers, and shaders of three kinds sharing one handle and one params
// scheme: compute and draw shaders written against shader/gpu.slang, post shaders against
// shader/post.slang (pass_post.odin). A compute or draw shader names what it binds once, at
// creation: binding i of set 1 is bindings[i]. Each tick, stage_clear and stage_dispatch queue
// work that the next frame runs once, in order, before it draws the scene; stage_draw sets what
// every camera's forward pass draws, until the next tick's draws replace it; a camera's effects
// run its post shaders. render places the barriers between them. Every dispatch, draw and effect
// takes params: any struct of at most PARAMS_BYTES, which the shader reads as its own struct.
// Buffers and shaders live until buffer_destroy or shader_destroy, teardown or shutdown; destroy
// a shader before what it binds.

// BufferHandle is a GPU buffer of yours (buffer_create); 0 is none.
BufferHandle :: distinct u32

// BufferUsage is what a buffer is besides storage: INDIRECT holds dispatch or draw arguments,
// READBACK is copied back each frame for buffer_read.
BufferUsage :: enum {
  INDIRECT,
  READBACK,
}

// StorageImage binds a texture made with texture_create(storage = true) for a compute shader to
// write; a plain TextureHandle binds it to sample.
StorageImage :: distinct TextureHandle

// Binding is one resource a shader binds: a buffer (read_write in a compute shader, read-only in
// a draw shader), a texture to sample, or an image to write.
Binding :: union {
  BufferHandle,
  TextureHandle,
  StorageImage,
}

// ShaderHandle is a shader of yours: a compute, draw or post shader (compute_shader_create,
// draw_shader_create, post_shader_create); 0 is none.
ShaderHandle :: distinct u32

// DrawState is how a draw shader draws into a camera's lit image. With mesh_vertices its vertex
// shader reads a mesh's vertices (stage_draw with a MeshHandle); without, it makes its own
// vertices from the vertex index (stage_draw with a vertex count).
DrawState :: struct {
  mesh_vertices: bool,
  topology:      Topology,
  cull:          CullMode,
  blend:         BlendMode,
  depth_test:    bool,
  depth_write:   bool,
}

// DEFAULT_DRAW_STATE draws opaque, culled, depth-tested and depth-writing triangles.
DEFAULT_DRAW_STATE :: DrawState {
  topology    = .TRIANGLE_LIST,
  cull        = .BACK,
  blend       = .NONE,
  depth_test  = true,
  depth_write = true,
}

// VertexCount is how many vertices a draw shader makes from the vertex index.
VertexCount :: distinct u32

// DrawSource is what a draw draws: the vertices and indices of a mesh, or a vertex count.
DrawSource :: union {
  MeshHandle,
  VertexCount,
}

// PARAMS_BYTES is the most a dispatch's, draw's or effect's params take.
PARAMS_BYTES :: PUSH_SIZE - 16

// MAX_BINDINGS is the most resources one shader binds.
MAX_BINDINGS :: 8

// MAX_GPU_BUFFERS is how many buffers (buffer_create) exist at once.
MAX_GPU_BUFFERS :: 1024

// MAX_SHADERS is how many shaders of yours exist at once.
MAX_SHADERS :: 256

@(private = "file")
MAX_GPU_WORK :: 1024

@(private)
GpuBuffer :: struct {
  buffer:   rhi.Buffer,
  size:     int,
  // READBACK: where each frame copies it (the backend keeps the copies of frames in flight)
  readback: rhi.Buffer,
}

// Where render runs a shader: staged dispatches, staged draws, or a camera's effects.
@(private)
ShaderKind :: enum u8 {
  COMPUTE,
  DRAW,
  POST,
}

@(private)
Shader :: struct {
  // [writes the backbuffer] for a post shader (the last pass of the presented camera's chain);
  // compute and draw shaders have [0]
  pipelines:     [2]rhi.Pipeline,
  group:         rhi.BindGroup,
  kind:          ShaderKind,
  mesh_vertices: bool,
  // the fullscreen passes a post shader runs per effect
  passes:        u32,
}

// What every shader pushes: the camera it runs for, a post pass's images and pass, then the
// params.
@(private)
ShaderPush :: struct {
  camera_index:         u32,
  // a post pass's: the previous pass's output and input, and which pass of its shader it is
  input_image_index:    u32,
  original_image_index: u32,
  pass:                 u32,
  params:               [PARAMS_BYTES]u8,
}
#assert(size_of(ShaderPush) == PUSH_SIZE)

@(private)
GpuWork :: struct {
  // zeroes `buffer` instead of dispatching
  clear:  bool,
  shader: ShaderHandle,
  // a clear's buffer, or a dispatch_indirect's arguments
  buffer: BufferHandle,
  offset: int,
  groups: [3]u32,
  params: [PARAMS_BYTES]u8,
}

@(private)
GpuDraw :: struct {
  shader:    ShaderHandle,
  source:    DrawSource,
  instances: u32,
  // indirect when set
  args:      BufferHandle,
  offset:    int,
  params:    [PARAMS_BYTES]u8,
}

@(private)
GpuLayoutKey :: struct {
  count:   int,
  compute: bool,
  kinds:   [MAX_BINDINGS]rhi.BindKind,
  formats: [MAX_BINDINGS]TextureFormat,
}

// buffer_create makes a GPU buffer holding data (len(data) elements of T, zeroed when you
// pass make([]T, n)); false when it cannot be made.
buffer_create :: proc(self: ^Renderer, data: []$T, usage: bit_set[BufferUsage] = {}) -> (handle: BufferHandle, ok: bool) #optional_ok {
  #assert(size_of(T) % 4 == 0)
  lock(self)
  handle = BufferHandle(containers.slots_alloc(&self.slots[.GPU_BUFFERS]) or_return)
  defer if !ok do buffer_destroy(self, handle)
  size := len(data) * size_of(T)
  b := &self.gpu_buffers[handle]
  b^ = {size = size}
  flags := bit_set[rhi.BufferUsage]{.STORAGE, .COPY_SRC, .COPY_DST}
  if .INDIRECT in usage do flags += {.INDIRECT}
  b.buffer = dev.buffer_create(&self.gpu, {size = size, usage = flags}) or_return
  if .READBACK in usage {
    b.readback = dev.buffer_create(&self.gpu, {size = size, usage = {.COPY_DST}, memory = .READBACK}) or_return
  }
  if size > 0 do dev.buffer_write(&self.gpu, b.buffer, 0, ([^]u8)(raw_data(data))[:size]) or_return
  return handle, true
}

// buffer_write writes data at element `first` of the buffer; it lands before the next frame's
// work.
buffer_write :: proc(self: ^Renderer, handle: BufferHandle, data: []$T, first := 0) -> bool {
  lock(self)
  b := gpu_buffer(self, handle) or_return
  offset, size := first * size_of(T), len(data) * size_of(T)
  if offset + size > b.size do return false
  return dev.buffer_write(&self.gpu, b.buffer, offset, ([^]u8)(raw_data(data))[:size])
}

// buffer_read fills dst from element `first` of a READBACK buffer as the latest finished frame
// left it, a frame or two behind; zeros before any frame copied it back.
buffer_read :: proc(self: ^Renderer, handle: BufferHandle, dst: []$T, first := 0) -> bool {
  lock(self)
  b := gpu_buffer(self, handle) or_return
  offset, size := first * size_of(T), len(dst) * size_of(T)
  if b.readback == 0 || offset + size > b.size do return false
  _, ok := dev.buffer_read(&self.gpu, b.readback, offset, ([^]u8)(raw_data(dst))[:size])
  return ok
}

// buffer_destroy frees the buffer; frames already submitted still use it.
buffer_destroy :: proc(self: ^Renderer, handle: BufferHandle) {
  lock(self)
  b := gpu_buffer(self, handle) or_else nil
  if b == nil do return
  dev.buffer_retire(&self.gpu, b.buffer)
  dev.buffer_retire(&self.gpu, b.readback)
  b^ = {}
  containers.slots_free(&self.slots[.GPU_BUFFERS], u32(handle))
}

// compute_shader_create makes a compute shader (entry point main) binding `bindings`, from a
// compiled shader: #load("name." + SHADER_EXT).
compute_shader_create :: proc(self: ^Renderer, source: []u8, bindings: ..Binding) -> (shader: ShaderHandle, ok: bool) #optional_ok {
  lock(self)
  layout, group := gpu_bindings(self, bindings, compute = true) or_return
  pipeline, created := dev.compute_pipeline_create(&self.gpu, {source, pipeline_layout(self, .USER, user = layout)})
  return shader_add(self, {pipelines = {pipeline, 0}, group = group, kind = .COMPUTE}, created)
}

// draw_shader_create makes a draw shader (entry points vs_main and fs_main of one compiled
// shader) binding `bindings`, drawn by `state`.
draw_shader_create :: proc(
  self: ^Renderer,
  source: []u8,
  state := DEFAULT_DRAW_STATE,
  bindings: ..Binding,
) -> (
  shader: ShaderHandle,
  ok: bool,
) #optional_ok {
  lock(self)
  layout, group := gpu_bindings(self, bindings, compute = false) or_return
  desc := rhi.GraphicsPipelineDesc {
    shader        = source,
    layout        = pipeline_layout(self, .USER, user = layout),
    topology      = state.topology,
    cull          = state.cull,
    color_formats = material_pass_formats(.FORWARD),
    blend         = state.blend,
    depth         = rhi.DepthState{write = state.depth_write, compare = .LESS_EQUAL if state.depth_test else .ALWAYS},
  }
  if state.mesh_vertices do desc.vertex = mesh_vertex_streams()[:1]
  pipeline, created := dev.graphics_pipeline_create(&self.gpu, desc)
  return shader_add(self, {pipelines = {pipeline, 0}, group = group, kind = .DRAW, mesh_vertices = state.mesh_vertices}, created)
}

// shader_destroy frees a shader: its staged work and draws are dropped, and effects running it
// copy their input.
shader_destroy :: proc(self: ^Renderer, handle: ShaderHandle) {
  lock(self)
  s := shader(self, handle) or_else nil
  if s == nil do return
  for p in s.pipelines do dev.pipeline_retire(&self.gpu, p)
  dev.bind_group_retire(&self.gpu, s.group)
  s^ = {}
  containers.slots_free(&self.slots[.SHADERS], u32(handle))
}

// stage_clear queues zeroing the buffer, ordered with the dispatches around it.
stage_clear :: proc(self: ^Renderer, buffer: BufferHandle) {
  lock(self)
  if _, live := gpu_buffer(self, buffer); live do gpu_work_add(self, {clear = true, buffer = buffer})
}

// stage_dispatch queues a compute shader with `params` (the shaders' `params`, laid out as
// Params; at most PARAMS_BYTES) over:
//   stage_dispatch(r, shader, groups: [3]u32, params): that many workgroups
//   stage_dispatch(r, shader, args: BufferHandle, offset: int, params): the workgroup counts
//   that three u32 at byte `offset` of an INDIRECT buffer hold when it runs
stage_dispatch :: proc {
  stage_dispatch_groups,
  stage_dispatch_indirect,
}

@(private = "file")
stage_dispatch_groups :: proc(self: ^Renderer, shader: ShaderHandle, groups: [3]u32, params: $T) {
  lock(self)
  gpu_work_add(self, {shader = shader, groups = groups, params = pack_params(params)})
}

@(private = "file")
stage_dispatch_indirect :: proc(self: ^Renderer, shader: ShaderHandle, args: BufferHandle, offset: int, params: $T) {
  lock(self)
  gpu_work_add(self, {shader = shader, buffer = args, offset = offset, params = pack_params(params)})
}

// stage_draw draws source with a draw shader in every camera's forward pass, over the lit scene
// and depth-tested against it:
//   stage_draw(r, shader, source, instances: u32, params): that many instances
//   stage_draw(r, shader, source, args: BufferHandle, offset: int, params): with the arguments
//   at byte `offset` of an INDIRECT buffer when it draws: {vertex_count, instance_count,
//   first_vertex, first_instance} for a vertex count; {index_count, instance_count, first_index,
//   vertex_offset, first_instance} for a mesh, its indices and vertices counted from the mesh's
//   first
stage_draw :: proc {
  stage_draw_instances,
  stage_draw_indirect,
}

@(private = "file")
stage_draw_instances :: proc(self: ^Renderer, shader: ShaderHandle, source: DrawSource, instances: u32, params: $T) {
  lock(self)
  gpu_draw_add(self, {shader = shader, source = source, instances = instances, params = pack_params(params)})
}

@(private = "file")
stage_draw_indirect :: proc(self: ^Renderer, shader: ShaderHandle, source: DrawSource, args: BufferHandle, offset: int, params: $T) {
  lock(self)
  gpu_draw_add(self, {shader = shader, source = source, args = args, offset = offset, params = pack_params(params)})
}

@(private = "file")
gpu_buffer :: proc(self: ^Renderer, handle: BufferHandle) -> (^GpuBuffer, bool) {
  if !containers.slots_live(&self.slots[.GPU_BUFFERS], u32(handle)) do return nil, false
  return &self.gpu_buffers[handle], true
}

// The live shader of `handle`.
@(private)
shader :: proc(self: ^Renderer, handle: ShaderHandle) -> (^Shader, bool) {
  if !containers.slots_live(&self.slots[.SHADERS], u32(handle)) do return nil, false
  return &self.shaders[handle], true
}

// The shader of `handle` when it is live and of `kind`.
@(private)
shader_of :: proc(self: ^Renderer, handle: ShaderHandle, kind: ShaderKind) -> (s: ^Shader, ok: bool) {
  s = shader(self, handle) or_return
  return s, s.kind == kind
}

// Stores a shader whose pipelines were made (`created`); false, retiring what it holds, when
// they were not or every handle is taken.
@(private)
shader_add :: proc(self: ^Renderer, s: Shader, created: bool) -> (handle: ShaderHandle, ok: bool) {
  slot: u32
  if created {
    slot, ok = containers.slots_alloc(&self.slots[.SHADERS])
    if !ok do log.errorf("More than %d shaders at once", MAX_SHADERS)
  }
  if !ok {
    for p in s.pipelines do dev.pipeline_retire(&self.gpu, p)
    dev.bind_group_retire(&self.gpu, s.group)
    return
  }
  self.shaders[slot] = s
  return ShaderHandle(slot), true
}

// The layout (cached by what it binds) and the group of a shader's bindings, set 1.
@(private = "file")
gpu_bindings :: proc(self: ^Renderer, bindings: []Binding, compute: bool) -> (layout: rhi.BindLayout, group: rhi.BindGroup, ok: bool) {
  if len(bindings) > MAX_BINDINGS {
    log.errorf("A shader binds at most %d resources, not %d", MAX_BINDINGS, len(bindings))
    return
  }
  key := GpuLayoutKey{count = len(bindings), compute = compute}
  resources := make([]rhi.BindResource, len(bindings), context.temp_allocator)
  for binding, i in bindings {
    switch v in binding {
    case BufferHandle:
      b, live := gpu_buffer(self, v)
      if !live {
        log.errorf("Binding %d: buffer %d is not live", i, v)
        return
      }
      key.kinds[i] = .STORAGE_BUFFER if compute else .STORAGE_BUFFER_READ
      resources[i] = rhi.BufferRange{buffer = b.buffer}
    case TextureHandle:
      key.kinds[i] = .TEXTURE_FLOAT
      resources[i] = rhi.TextureView{texture = v, mip = -1}
    case StorageImage:
      desc: TextureDesc
      // only texture_create's, not render's targets
      if containers.slots_live(&self.slots[.TEXTURES], u32(v)) do desc = dev.texture_desc(&self.gpu, TextureHandle(v))
      if .STORAGE not_in desc.usage || !compute {
        log.errorf("Binding %d: a compute shader writes only textures made with texture_create(storage = true)", i)
        return
      }
      key.kinds[i], key.formats[i] = .STORAGE_TEXTURE, desc.format
      resources[i] = rhi.TextureView{texture = TextureHandle(v), mip = -1}
    case:
      log.errorf("Binding %d is empty", i)
      return
    }
  }
  layout = gpu_layout(self, key) or_return
  group = dev.bind_group_create(&self.gpu, {layout = layout, resources = resources}) or_return
  return layout, group, true
}

// The bind layout of `key`, made once and kept until shutdown.
@(private)
gpu_layout :: proc(self: ^Renderer, key: GpuLayoutKey) -> (layout: rhi.BindLayout, ok: bool) {
  if layout, ok = self.gpu_layouts[key]; ok do return
  entries := make([]rhi.BindEntry, key.count, context.temp_allocator)
  for &e, i in entries do e = {kind = key.kinds[i], stages = {.COMPUTE} if key.compute else {.VERTEX, .FRAGMENT}, format = key.formats[i]}
  layout = dev.bind_layout_create(&self.gpu, {entries = entries}) or_return
  self.gpu_layouts[key] = layout
  return layout, true
}

// params' bytes, as a shader reads them.
@(private)
pack_params :: proc(params: $T) -> (bytes: [PARAMS_BYTES]u8) {
  #assert(size_of(T) <= PARAMS_BYTES, "params take more than PARAMS_BYTES")
  params := params
  copy(bytes[:], ([^]u8)(&params)[:size_of(T)])
  return
}

@(private = "file")
gpu_work_add :: proc(self: ^Renderer, work: GpuWork) {
  if _, compute := shader_of(self, work.shader, .COMPUTE); !work.clear && !compute do return
  if len(self.gpu_work) >= MAX_GPU_WORK {
    log.warnf("More than %d dispatches staged before a frame; dropping", MAX_GPU_WORK)
    return
  }
  append(&self.gpu_work, work)
}

@(private = "file")
gpu_draw_add :: proc(self: ^Renderer, draw: GpuDraw) {
  s, live := shader_of(self, draw.shader, .DRAW)
  if !live do return
  if _, is_mesh := draw.source.(MeshHandle); is_mesh != s.mesh_vertices {
    log.errorf("Draw shader %d draws %s", draw.shader, "meshes" if s.mesh_vertices else "vertex counts")
    return
  }
  if self.gpu_draws_stale do clear(&self.gpu_draws)
  self.gpu_draws_stale = false
  append(&self.gpu_draws, draw)
}

@(private = "file")
gpu_bind :: proc(self: ^Renderer, cmd: rhi.CommandList, s: ^Shader, f: u32, params: [PARAMS_BYTES]u8, camera: u32) {
  push := ShaderPush{camera_index = camera, params = params}
  dev.cmd_bind_pipeline(&self.gpu, cmd, s.pipelines[0])
  scene_bind(self, cmd, .USER, f)
  dev.cmd_bind_group(&self.gpu, cmd, 1, s.group)
  dev.cmd_push(&self.gpu, cmd, &push, size_of(push))
}

// The staged work in order, then the readback copies, before anything draws.
@(private)
gpu_work_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32) {
  readbacks := false
  buffers := self.gpu_buffers[:self.slots[.GPU_BUFFERS].high_water]
  for b in buffers do readbacks ||= b.readback != 0
  if len(self.gpu_work) == 0 && !readbacks do return
  barrier(self, cmd, .FRAME_TO_GPU_WORK)
  in_compute := false
  for &work, i in self.gpu_work {
    if i > 0 do barrier(self, cmd, .GPU_WORK)
    if work.clear {
      if in_compute do dev.cmd_end_compute(&self.gpu, cmd)
      in_compute = false
      if b, live := gpu_buffer(self, work.buffer); live && b.size > 0 do dev.cmd_fill_buffer(&self.gpu, cmd, b.buffer, 0, (b.size + 3) &~ 3)
      continue
    }
    s := shader_of(self, work.shader, .COMPUTE) or_continue
    if !in_compute do dev.cmd_begin_compute(&self.gpu, cmd)
    in_compute = true
    gpu_bind(self, cmd, s, f, work.params, u32(self.main_camera))
    if work.buffer != 0 {
      args := gpu_buffer(self, work.buffer) or_continue
      dev.cmd_dispatch_indirect(&self.gpu, cmd, args.buffer, work.offset)
    } else {
      dev.cmd_dispatch(&self.gpu, cmd, work.groups.x, work.groups.y, work.groups.z)
    }
  }
  if in_compute do dev.cmd_end_compute(&self.gpu, cmd)
  barrier(self, cmd, .GPU_WORK_TO_DRAW)
  for b in buffers {
    if b.readback == 0 do continue
    dev.cmd_copy_buffer(&self.gpu, cmd, b.buffer, 0, b.readback, 0, b.size)
  }
}

// Inside camera cam's forward pass.
@(private)
gpu_draws_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, cam: u32) {
  for &draw in self.gpu_draws {
    s := shader_of(self, draw.shader, .DRAW) or_continue
    gpu_bind(self, cmd, s, f, draw.params, cam)
    args: ^GpuBuffer
    if draw.args != 0 do args = gpu_buffer(self, draw.args) or_continue
    switch source in draw.source {
    case MeshHandle:
      mesh := write_table(self, .MESHES, MeshData)[u32(source)]
      if mesh.index_count == 0 do continue
      dev.cmd_bind_vertex(&self.gpu, cmd, 0, mesh_buffer(self, .VERTEX), int(mesh.vertex_offset) * size_of(geometry.Vertex))
      dev.cmd_bind_index(&self.gpu, cmd, mesh_buffer(self, .INDEX), int(mesh.first_index) * size_of(u32))
      if args != nil {
        dev.cmd_draw_indexed_indirect(&self.gpu, cmd, args.buffer, draw.offset, 1, 5 * size_of(u32))
      } else {
        dev.cmd_draw_indexed(&self.gpu, cmd, mesh.index_count, draw.instances, 0, 0, 0)
      }
    case VertexCount:
      if args != nil {
        dev.cmd_draw_indirect(&self.gpu, cmd, args.buffer, draw.offset, 1, 4 * size_of(u32))
      } else {
        dev.cmd_draw(&self.gpu, cmd, u32(source), draw.instances, 0, 0)
      }
    }
  }
}

// After a frame submits: its work ran, and its draws stay until a tick stages others.
@(private)
gpu_frame_done :: proc(self: ^Renderer) {
  clear(&self.gpu_work)
  self.gpu_draws_stale = true
}

// Teardown keeps buffers and shaders (they are the application's) but drops what was staged.
@(private)
gpu_reset :: proc(self: ^Renderer) {
  clear(&self.gpu_work)
  clear(&self.gpu_draws)
}

@(private)
gpu_shutdown :: proc(self: ^Renderer) {
  delete(self.gpu_work)
  delete(self.gpu_draws)
  delete(self.gpu_layouts)
}
