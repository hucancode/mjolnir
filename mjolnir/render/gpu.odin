package render

import "../geometry"

import "../containers"
import "core:log"
import "rhi"

// Your own GPU programs: buffers, compute shaders and draw shaders, written against
// shader/gpu.slang. A shader names what
// it binds once, at creation: binding i of set 1 is bindings[i]. Each tick, stage_clear and
// stage_dispatch queue work that the next frame runs once, in order, before it draws the scene;
// stage_draw sets what every camera's forward pass draws, until the next tick's draws replace
// it. render places the barriers between them. Buffers and shaders live until *_destroy or
// shutdown; destroy a shader before what it binds.

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

// ComputeShader is a compute shader of yours (compute_shader_create); 0 is none.
ComputeShader :: distinct u32

// DrawShader is a vertex and fragment shader of yours (draw_shader_create); 0 is none.
DrawShader :: distinct u32

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

// GPU_PARAMS_BYTES is the most a dispatch or draw's params may take (the shaders' `params`).
GPU_PARAMS_BYTES :: PUSH_SIZE - 16

// MAX_BINDINGS is the most resources one shader binds.
MAX_BINDINGS :: 8

// MAX_GPU_BUFFERS is how many buffers (buffer_create) exist at once.
MAX_GPU_BUFFERS :: 1024

// MAX_GPU_SHADERS is how many compute and draw shaders exist at once.
MAX_GPU_SHADERS :: 256

@(private = "file")
MAX_GPU_WORK :: 1024

@(private)
GpuBuffer :: struct {
  buffer:   rhi.Buffer,
  size:     int,
  // READBACK: the copy each frame slot makes
  readback: [FRAMES_IN_FLIGHT]rhi.Buffer,
}

@(private)
GpuShader :: struct {
  pipeline:      rhi.Pipeline,
  group:         rhi.BindGroup,
  mesh_vertices: bool,
}

// What every user dispatch and draw pushes: the camera it draws for, then its params.
@(private)
GpuPush :: struct {
  camera_index: u32,
  _:            [3]u32,
  params:       [GPU_PARAMS_BYTES]u8,
}
#assert(size_of(GpuPush) == PUSH_SIZE)

@(private)
GpuWork :: struct {
  // zeroes `buffer` instead of dispatching
  clear:  bool,
  shader: ComputeShader,
  // a clear's buffer, or a dispatch_indirect's arguments
  buffer: BufferHandle,
  offset: int,
  groups: [3]u32,
  push:   GpuPush,
}

@(private)
GpuDraw :: struct {
  shader:    DrawShader,
  source:    DrawSource,
  instances: u32,
  // indirect when set
  args:      BufferHandle,
  offset:    int,
  push:      GpuPush,
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
    for &r in b.readback do r = dev.buffer_create(&self.gpu, {size = size, usage = {.COPY_DST}, memory = .READBACK}) or_return
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

// buffer_read fills dst from element `first` of a READBACK buffer as a recent frame left it,
// a frame or two behind; false before any frame copied it back.
buffer_read :: proc(self: ^Renderer, handle: BufferHandle, dst: []$T, first := 0) -> bool {
  lock(self)
  b := gpu_buffer(self, handle) or_return
  offset, size := first * size_of(T), len(dst) * size_of(T)
  if b.readback[0] == 0 || offset + size > b.size do return false
  return dev.buffer_read(&self.gpu, b.readback[current_frame(self)], offset, ([^]u8)(raw_data(dst))[:size])
}

// buffer_destroy frees the buffer; frames already submitted still use it.
buffer_destroy :: proc(self: ^Renderer, handle: BufferHandle) {
  lock(self)
  b := gpu_buffer(self, handle) or_else nil
  if b == nil do return
  dev.buffer_retire(&self.gpu, b.buffer)
  for r in b.readback do dev.buffer_retire(&self.gpu, r)
  b^ = {}
  containers.slots_free(&self.slots[.GPU_BUFFERS], u32(handle))
}

// compute_shader_create makes a compute shader (entry point main) binding `bindings`, from a
// compiled shader: #load("name." + SHADER_EXT).
compute_shader_create :: proc(self: ^Renderer, source: []u8, bindings: ..Binding) -> (shader: ComputeShader, ok: bool) #optional_ok {
  lock(self)
  layout, group := gpu_bindings(self, bindings, compute = true) or_return
  pipeline := dev.compute_pipeline_create(&self.gpu, {source, pipeline_layout(self, .USER, user = layout)}) or_return
  return ComputeShader(gpu_shader_add(self, {pipeline = pipeline, group = group}) or_return), true
}

// draw_shader_create makes a draw shader (entry points vs_main and fs_main of one compiled
// shader) binding `bindings`, drawn by `state`.
draw_shader_create :: proc(
  self: ^Renderer,
  source: []u8,
  state := DEFAULT_DRAW_STATE,
  bindings: ..Binding,
) -> (
  shader: DrawShader,
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
  pipeline := dev.graphics_pipeline_create(&self.gpu, desc) or_return
  return DrawShader(gpu_shader_add(self, {pipeline = pipeline, group = group, mesh_vertices = state.mesh_vertices}) or_return), true
}

// compute_shader_destroy frees a compute shader; its staged work is dropped.
compute_shader_destroy :: proc(self: ^Renderer, shader: ComputeShader) {
  gpu_shader_destroy(self, u32(shader))
}

// draw_shader_destroy frees a draw shader; its staged draws are dropped.
draw_shader_destroy :: proc(self: ^Renderer, shader: DrawShader) {
  gpu_shader_destroy(self, u32(shader))
}

// stage_clear queues zeroing the buffer, ordered with the dispatches around it.
stage_clear :: proc(self: ^Renderer, buffer: BufferHandle) {
  lock(self)
  if _, live := gpu_buffer(self, buffer); live do gpu_work_add(self, {clear = true, buffer = buffer})
}

// stage_dispatch queues the shader over `groups` workgroups with `params` (the shaders'
// `params`, laid out as Params; at most GPU_PARAMS_BYTES).
stage_dispatch :: proc(self: ^Renderer, shader: ComputeShader, groups: [3]u32, params: $T) {
  lock(self)
  gpu_work_add(self, {shader = shader, groups = groups, push = gpu_push(params)})
}

// stage_dispatch_indirect queues the shader over the workgroup counts that three u32 at byte
// `offset` of an INDIRECT buffer hold when it runs.
stage_dispatch_indirect :: proc(self: ^Renderer, shader: ComputeShader, args: BufferHandle, offset: int, params: $T) {
  lock(self)
  gpu_work_add(self, {shader = shader, buffer = args, offset = offset, push = gpu_push(params)})
}

// stage_draw draws `instances` of source with the shader in every camera's forward pass, over
// the lit scene and depth-tested against it.
stage_draw :: proc(self: ^Renderer, shader: DrawShader, source: DrawSource, instances: u32, params: $T) {
  lock(self)
  gpu_draw_add(self, {shader = shader, source = source, instances = instances, push = gpu_push(params)})
}

// stage_draw_indirect draws source with the arguments at byte `offset` of an INDIRECT buffer when
// it draws: {vertex_count, instance_count, first_vertex, first_instance} for a vertex count;
// {index_count, instance_count, first_index, vertex_offset, first_instance} for a mesh, its
// indices and vertices counted from the mesh's first.
stage_draw_indirect :: proc(self: ^Renderer, shader: DrawShader, source: DrawSource, args: BufferHandle, offset: int, params: $T) {
  lock(self)
  gpu_draw_add(self, {shader = shader, source = source, args = args, offset = offset, push = gpu_push(params)})
}

@(private = "file")
gpu_buffer :: proc(self: ^Renderer, handle: BufferHandle) -> (^GpuBuffer, bool) {
  if !containers.slots_live(&self.slots[.GPU_BUFFERS], u32(handle)) do return nil, false
  return &self.gpu_buffers[handle], true
}

@(private = "file")
gpu_shader :: proc(self: ^Renderer, handle: u32) -> (^GpuShader, bool) {
  if !containers.slots_live(&self.slots[.GPU_SHADERS], handle) do return nil, false
  return &self.gpu_shaders[handle], true
}

// false, retiring what `shader` holds, when every handle is taken
@(private = "file")
gpu_shader_add :: proc(self: ^Renderer, shader: GpuShader) -> (handle: u32, ok: bool) {
  handle, ok = containers.slots_alloc(&self.slots[.GPU_SHADERS])
  if !ok {
    log.errorf("More than %d shaders at once", MAX_GPU_SHADERS)
    dev.pipeline_retire(&self.gpu, shader.pipeline)
    dev.bind_group_retire(&self.gpu, shader.group)
    return
  }
  self.gpu_shaders[handle] = shader
  return
}

@(private = "file")
gpu_shader_destroy :: proc(self: ^Renderer, handle: u32) {
  lock(self)
  s := gpu_shader(self, handle) or_else nil
  if s == nil do return
  dev.pipeline_retire(&self.gpu, s.pipeline)
  dev.bind_group_retire(&self.gpu, s.group)
  s^ = {}
  containers.slots_free(&self.slots[.GPU_SHADERS], handle)
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
      format := self.storage_formats[v] if u32(v) < MAX_TEXTURES else {}
      if format == {} || !compute {
        log.errorf("Binding %d: a compute shader writes only textures made with texture_create(storage = true)", i)
        return
      }
      key.kinds[i], key.formats[i] = .STORAGE_TEXTURE, format
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

// The camera index is set as the work or draw is recorded.
@(private = "file")
gpu_push :: proc(params: $T) -> (push: GpuPush) {
  #assert(size_of(T) <= GPU_PARAMS_BYTES, "params take more than GPU_PARAMS_BYTES")
  params := params
  copy(push.params[:], ([^]u8)(&params)[:size_of(T)])
  return
}

@(private = "file")
gpu_work_add :: proc(self: ^Renderer, work: GpuWork) {
  if !work.clear && !containers.slots_live(&self.slots[.GPU_SHADERS], u32(work.shader)) do return
  if len(self.gpu_work) >= MAX_GPU_WORK {
    log.warnf("More than %d dispatches staged before a frame; dropping", MAX_GPU_WORK)
    return
  }
  append(&self.gpu_work, work)
}

@(private = "file")
gpu_draw_add :: proc(self: ^Renderer, draw: GpuDraw) {
  s, live := gpu_shader(self, u32(draw.shader))
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
gpu_bind :: proc(self: ^Renderer, cmd: rhi.CommandList, s: ^GpuShader, f: u32, push: GpuPush, camera: u32) {
  push := push
  push.camera_index = camera
  dev.cmd_bind_pipeline(&self.gpu, cmd, s.pipeline)
  scene_bind(self, cmd, .USER, f)
  dev.cmd_bind_group(&self.gpu, cmd, 1, s.group)
  dev.cmd_push(&self.gpu, cmd, &push, size_of(push))
}

// The staged work in order, then the readback copies, before anything draws.
@(private)
gpu_work_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32) {
  readbacks := false
  buffers := self.gpu_buffers[:self.slots[.GPU_BUFFERS].high_water]
  for b in buffers do readbacks ||= b.readback[0] != 0
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
    s := gpu_shader(self, u32(work.shader)) or_continue
    if !in_compute do dev.cmd_begin_compute(&self.gpu, cmd)
    in_compute = true
    gpu_bind(self, cmd, s, f, work.push, u32(self.main_camera))
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
    if b.readback[f] == 0 do continue
    dev.cmd_copy_buffer(&self.gpu, cmd, b.buffer, 0, b.readback[f], 0, b.size)
  }
}

// Inside camera cam's forward pass.
@(private)
gpu_draws_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, cam: u32) {
  for &draw in self.gpu_draws {
    s := gpu_shader(self, u32(draw.shader)) or_continue
    gpu_bind(self, cmd, s, f, draw.push, cam)
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
