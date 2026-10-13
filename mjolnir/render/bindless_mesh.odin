package render

import cont "../containers"
import "core:log"
import "core:sync"
import "gpu"
import "mesh"
import vk "vendor:vulkan"

// Primitive names a builtin mesh in Renderer.builtin_meshes.
Primitive :: enum {
  CUBE,
  SPHERE,
  QUAD_XZ,
  QUAD_XY,
  CONE,
  CYLINDER,
}

@(private)
MeshFlag :: enum u32 {
  SKINNED,
}

@(private)
MeshFlagSet :: bit_set[MeshFlag;u32]

// as the cull shader reads it from the mesh table
@(private)
MeshData :: struct {
  aabb_min:        [3]f32,
  index_count:     u32,
  aabb_max:        [3]f32,
  first_index:     u32,
  vertex_offset:   i32,
  skinning_offset: u32,
  flags:           MeshFlagSet,
  vertex_count:    u32,
}

// One buffer per stream, sub-allocated by its slab; skinning is read through the scene set.
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

// capacities come from the slab configs, so no offset can pass the end of a buffer
@(private)
mesh_arena_init :: proc(r: ^Renderer) -> vk.Result {
  for stream, s in MESH_STREAMS {
    cont.slab_init(&r.mesh_slabs[s], stream.slab)
    size := vk.DeviceSize(r.mesh_slabs[s].capacity) * vk.DeviceSize(stream.elem_size)
    r.mesh_buffers[s] = gpu.buffer_create(&r.gctx, size, stream.usage, host_visible = false) or_return
  }
  return .SUCCESS
}

@(private)
mesh_arena_destroy :: proc(r: ^Renderer) {
  for &b in r.mesh_buffers do gpu.buffer_destroy(r.gctx.device, &b)
  for &slab in r.mesh_slabs do cont.slab_destroy(&slab)
}

// Returns the first element index; empty data takes no range.
@(private = "file")
mesh_arena_upload :: proc(r: ^Renderer, stream: MeshStream, data: []$T) -> (offset: u32, ret: vk.Result) {
  if len(data) == 0 do return 0, .SUCCESS
  slab := &r.mesh_slabs[stream]
  ok: bool
  offset, ok = cont.slab_alloc(slab, u32(len(data)))
  if !ok do return 0, .ERROR_OUT_OF_DEVICE_MEMORY
  ret = gpu.queue_buffer_write(&r.gctx, &r.mesh_buffers[stream], data, int(offset))
  if ret != .SUCCESS do cont.slab_free(slab, offset)
  return
}

@(private)
free_mesh :: proc(r: ^Renderer, m: MeshData) {
  if m.vertex_count > 0 do cont.slab_free(&r.mesh_slabs[.VERTEX], u32(m.vertex_offset))
  if m.index_count > 0 do cont.slab_free(&r.mesh_slabs[.INDEX], m.first_index)
  if .SKINNED in m.flags do cont.slab_free(&r.mesh_slabs[.SKINNING], m.skinning_offset)
}

@(private)
VERTEX_BINDING_DESCRIPTION := [?]vk.VertexInputBindingDescription {
  {binding = 0, stride = size_of(mesh.Vertex), inputRate = .VERTEX},
}

@(private)
VERTEX_ATTRIBUTE_DESCRIPTIONS := [?]vk.VertexInputAttributeDescription {
  {location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(mesh.Vertex, position))},
  {location = 1, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(mesh.Vertex, normal))},
  {location = 2, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(mesh.Vertex, color))},
  {location = 3, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(mesh.Vertex, uv))},
  {location = 4, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(mesh.Vertex, tangent))},
}

// On failure the ranges taken so far are freed.
@(private)
upload_mesh :: proc(
  render: ^Renderer,
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

// create_mesh uploads geometry_data into the mesh arena.
// Ownership of the geometry transfers: it is deleted.
create_mesh :: proc(
  self: ^Renderer,
  geometry_data: mesh.Geometry,
) -> (
  handle: MeshHandle,
  ok: bool,
) #optional_ok {
  defer mesh.delete_geometry(geometry_data)
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  handle = MeshHandle(cont.slots_alloc(&self.mesh_slots) or_return)
  if res := upload_mesh(self, &self.gctx, u32(handle), &self.meshes[handle], geometry_data); res != .SUCCESS {
    log.errorf("Mesh %d upload failed: %v", handle, res)
    cont.slots_free(&self.mesh_slots, u32(handle))
    return 0, false
  }
  return handle, true
}

// destroy_mesh invalidates handle at once; the arena ranges are freed once no frame in flight draws it.
destroy_mesh :: proc(self: ^Renderer, handle: MeshHandle) {
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  cont.slots_free(&self.mesh_slots, u32(handle))
}

@(private)
init_builtin_meshes :: proc(self: ^Renderer) {
  self.builtin_meshes[.CUBE] = create_mesh(self, mesh.make_cube())
  self.builtin_meshes[.SPHERE] = create_mesh(self, mesh.make_sphere())
  self.builtin_meshes[.QUAD_XZ] = create_mesh(self, mesh.make_quad())
  self.builtin_meshes[.QUAD_XY] = create_mesh(self, mesh.make_billboard_quad())
  self.builtin_meshes[.CONE] = create_mesh(self, mesh.make_cone())
  self.builtin_meshes[.CYLINDER] = create_mesh(self, mesh.make_cylinder())
}
