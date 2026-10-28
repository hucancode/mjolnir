package render

import "../geometry"

import "../containers"
import "core:log"

// Primitive names a builtin mesh in Renderer.builtin_meshes.
Primitive :: enum {
  CUBE,
  SPHERE,
  QUAD_XZ,
  QUAD_XY,
  CONE,
  CYLINDER,
}

@(private = "file")
VERTEX_SLAB_CONFIG :: containers.SlabConfig {
  {block_size = 256, block_count = 512},
  {block_size = 1024, block_count = 128},
  {block_size = 4096, block_count = 64},
  {block_size = 16384, block_count = 16},
  {block_size = 65536, block_count = 8},
  {block_size = 131072, block_count = 4},
  {block_size = 262144, block_count = 1},
  {block_size = 0, block_count = 0},
}

// Each stream's buffer holds its slab's capacity, so no offset can pass the end of a buffer.
@(private)
MESH_STREAMS := [MeshStream]struct {
  slab:      containers.SlabConfig,
  elem_size: int,
} {
  .VERTEX = {VERTEX_SLAB_CONFIG, size_of(geometry.Vertex)},
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
  },
  .SKINNING = {VERTEX_SLAB_CONFIG, size_of(geometry.SkinningData)},
}

// Returns the first element index; empty data takes no range.
@(private = "file")
mesh_arena_upload :: proc(self: ^Renderer, stream: MeshStream, data: []$T) -> (offset: u32, ok: bool) {
  if len(data) == 0 do return 0, true
  slab := &self.mesh_slabs[stream]
  offset = containers.slab_alloc(slab, u32(len(data))) or_return
  ok = mesh_write(self, stream, data, offset)
  if !ok do containers.slab_free(slab, offset)
  return
}

@(private)
free_mesh :: proc(self: ^Renderer, m: MeshData) {
  if m.vertex_count > 0 do containers.slab_free(&self.mesh_slabs[.VERTEX], u32(m.vertex_offset))
  if m.index_count > 0 do containers.slab_free(&self.mesh_slabs[.INDEX], m.first_index)
  if .SKINNED in m.flags do containers.slab_free(&self.mesh_slabs[.SKINNING], m.skinning_offset)
}

// Fills entry `index` of the mesh table. On failure the ranges taken so far are freed.
@(private)
upload_mesh :: proc(self: ^Renderer, index: u32, g: geometry.Mesh) -> (ok: bool) {
  m := &write_table(self, .MESHES, MeshData)[index]
  aabb := geometry.aabb_from_vertices(g.vertices)
  m^ = {aabb_min = aabb.min, aabb_max = aabb.max}
  defer if !ok {
    free_mesh(self, m^)
    m^ = {}
  }
  defer mark_dirty(self, .MESHES, int(index))
  offset := mesh_arena_upload(self, .VERTEX, g.vertices) or_return
  m.vertex_offset, m.vertex_count = i32(offset), u32(len(g.vertices))
  m.first_index = mesh_arena_upload(self, .INDEX, g.indices) or_return
  m.index_count = u32(len(g.indices))
  m.skinning_offset = mesh_arena_upload(self, .SKINNING, g.skinnings) or_return
  if len(g.skinnings) > 0 do m.flags |= {.SKINNED}
  return true
}

// mesh_create uploads a CPU mesh (geometry.make_cube, ...) to the GPU; it lives until
// mesh_destroy or teardown. Ownership of `mesh` transfers: it is deleted.
mesh_create :: proc(self: ^Renderer, mesh: geometry.Mesh) -> (handle: MeshHandle, ok: bool) #optional_ok {
  defer geometry.mesh_destroy(mesh)
  return mesh_upload(self, mesh)
}

// mesh_create without taking the mesh.
@(private)
mesh_upload :: proc(self: ^Renderer, mesh: geometry.Mesh) -> (handle: MeshHandle, ok: bool) {
  guard(self)
  handle = MeshHandle(containers.slots_alloc(&self.slots[.MESHES]) or_return)
  if !upload_mesh(self, u32(handle), mesh) {
    log.errorf("Mesh %d upload failed", handle)
    containers.slots_free(&self.slots[.MESHES], u32(handle))
    return 0, false
  }
  return handle, true
}

// mesh_destroy frees the mesh; its handle is stale at once, and frames already submitted still
// draw it.
mesh_destroy :: proc(self: ^Renderer, handle: MeshHandle) {
  guard(self)
  containers.slots_free(&self.slots[.MESHES], u32(handle))
}

@(private)
init_builtin_meshes :: proc(self: ^Renderer) {
  self.builtin_meshes[.CUBE] = mesh_create(self, geometry.make_cube())
  self.builtin_meshes[.SPHERE] = mesh_create(self, geometry.make_sphere())
  self.builtin_meshes[.QUAD_XZ] = mesh_create(self, geometry.make_quad())
  self.builtin_meshes[.QUAD_XY] = mesh_create(self, geometry.make_billboard_quad())
  self.builtin_meshes[.CONE] = mesh_create(self, geometry.make_cone())
  self.builtin_meshes[.CYLINDER] = mesh_create(self, geometry.make_cylinder())
}
