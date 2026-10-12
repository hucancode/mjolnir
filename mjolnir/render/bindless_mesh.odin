package render

import cont "../containers"
import "gpu"
import "mesh"
import vk "vendor:vulkan"

MeshHandle :: distinct cont.Handle

// The mesh arena: one buffer per stream, sub-allocated by its slab. Vertices
// and indices are bound as vertex/index buffers; skinning is a storage
// buffer read by the vertex shader through the scene set.
@(private)
MeshStream :: enum {
  VERTEX,
  INDEX,
  SKINNING,
}

@(private = "file")
VERTEX_SLAB_CONFIG :: [cont.MAX_SLAB_CLASSES]struct {
  block_size, block_count: u32,
} {
  {block_size = 256, block_count = 512},
  {block_size = 1024, block_count = 128},
  {block_size = 4096, block_count = 64},
  {block_size = 16384, block_count = 16},
  {block_size = 65536, block_count = 8},
  {block_size = 131072, block_count = 4},
  {block_size = 262144, block_count = 1},
  {block_size = 0, block_count = 0},
}

@(private = "file")
MESH_STREAMS := [MeshStream]struct {
  slab:      [cont.MAX_SLAB_CLASSES]struct {
    block_size, block_count: u32,
  },
  elem_size: int,
  usage:     vk.BufferUsageFlags,
} {
  .VERTEX = {VERTEX_SLAB_CONFIG, size_of(mesh.Vertex), {.VERTEX_BUFFER}},
  .INDEX = {
    {
      {block_size = 128, block_count = 2048},
      {block_size = 512, block_count = 1024},
      {block_size = 2048, block_count = 512},
      {block_size = 8192, block_count = 256},
      {block_size = 32768, block_count = 128},
      {block_size = 131072, block_count = 32},
      {block_size = 524288, block_count = 8},
      {block_size = 2097152, block_count = 4},
    },
    size_of(u32),
    {.INDEX_BUFFER},
  },
  .SKINNING = {VERTEX_SLAB_CONFIG, size_of(mesh.SkinningData), {.STORAGE_BUFFER}},
}

// Buffer capacities come from the slab configs, so a slab can never hand out
// an offset past the end of its buffer.
@(private)
mesh_arena_init :: proc(r: ^Manager) -> vk.Result {
  for stream, s in MESH_STREAMS {
    cont.slab_init(&r.mesh_slabs[s], stream.slab)
    size := vk.DeviceSize(r.mesh_slabs[s].capacity) * vk.DeviceSize(stream.elem_size)
    r.mesh_buffers[s] = gpu.buffer_create(&r.gctx, size, stream.usage, host_visible = false) or_return
  }
  return .SUCCESS
}

@(private)
mesh_arena_destroy :: proc(r: ^Manager) {
  for &b in r.mesh_buffers do gpu.buffer_destroy(r.gctx.device, &b)
  for &slab in r.mesh_slabs do cont.slab_destroy(&slab)
}

// Copy `data` into a range of the stream's buffer taken from its slab; its
// first element index. Empty data takes no range; a failed copy frees its range.
@(private = "file")
mesh_arena_upload :: proc(r: ^Manager, stream: MeshStream, data: []$T) -> (offset: u32, ret: vk.Result) {
  if len(data) == 0 do return 0, .SUCCESS
  slab := &r.mesh_slabs[stream]
  ok: bool
  offset, ok = cont.slab_alloc(slab, u32(len(data)))
  if !ok do return 0, .ERROR_OUT_OF_DEVICE_MEMORY
  ret = gpu.queue_buffer_write(&r.gctx, &r.mesh_buffers[stream], data, int(offset))
  if ret != .SUCCESS do cont.slab_free(slab, offset)
  return
}

// Free the arena ranges of a mesh: its vertex and index ranges when it has
// vertices and indices, its skinning range when skinned.
free_mesh :: proc(r: ^Manager, m: MeshData) {
  if m.vertex_count > 0 do cont.slab_free(&r.mesh_slabs[.VERTEX], u32(m.vertex_offset))
  if m.index_count > 0 do cont.slab_free(&r.mesh_slabs[.INDEX], m.first_index)
  if .SKINNED in m.flags do cont.slab_free(&r.mesh_slabs[.SKINNING], m.skinning_offset)
}

VERTEX_BINDING_DESCRIPTION := [?]vk.VertexInputBindingDescription {
  {binding = 0, stride = size_of(mesh.Vertex), inputRate = .VERTEX},
}

VERTEX_ATTRIBUTE_DESCRIPTIONS := [?]vk.VertexInputAttributeDescription {
  {location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(mesh.Vertex, position))},
  {location = 1, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(mesh.Vertex, normal))},
  {location = 2, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(mesh.Vertex, color))},
  {location = 3, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(mesh.Vertex, uv))},
  {location = 4, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(mesh.Vertex, tangent))},
}

// Upload a geometry into the mesh arena and describe it in `m` and in
// mesh_data_buffer at `index`. On failure the ranges taken so far are freed.
// The ranges are freed by mesh_retire.
@(private)
upload_mesh :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  index: u32,
  m: ^MeshData,
  g: mesh.Geometry,
) -> (
  ret: vk.Result,
) {
  aabb := mesh.aabb_from_vertices(g.vertices)
  m^ = {aabb_min = aabb.min, aabb_max = aabb.max}
  defer if ret != .SUCCESS {
    free_mesh(render, m^)
    m^ = {}
  }
  offset := mesh_arena_upload(render, .VERTEX, g.vertices) or_return
  m.vertex_offset, m.vertex_count = i32(offset), u32(len(g.vertices))
  m.first_index = mesh_arena_upload(render, .INDEX, g.indices) or_return
  m.index_count = u32(len(g.indices))
  m.skinning_offset = mesh_arena_upload(render, .SKINNING, g.skinnings) or_return
  if len(g.skinnings) > 0 do m.flags |= {.SKINNED}
  return gpu.queue_buffer_write(gctx, &render.mesh_data_buffer, []MeshData{m^}, int(index))
}
