package bindless

import cont "../../containers"
import "../gpu"
import "../mesh"
import "core:log"
import vk "vendor:vulkan"

MeshHandle :: distinct cont.Handle

BufferAllocation :: struct {
  offset: u32,
  count:  u32,
}

MeshAllocations :: struct {
  vertices: BufferAllocation,
  indices:  BufferAllocation,
  skinning: BufferAllocation,
}

// Skinning data is a storage buffer read by the vertex shader through
// skinning_set; vertices and indices are bound as vertex/index buffers.
MeshManager :: struct {
  vertex_skinning_buffer: gpu.ImmutableBuffer(mesh.SkinningData),
  skinning_set_layout:    vk.DescriptorSetLayout,
  skinning_set:           vk.DescriptorSet,
  vertex_buffer:          gpu.ImmutableBuffer(mesh.Vertex),
  index_buffer:           gpu.ImmutableBuffer(u32),
  vertex_skinning_slab:   cont.SlabAllocator,
  vertex_slab:            cont.SlabAllocator,
  index_slab:             cont.SlabAllocator,
}

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

INDEX_SLAB_CONFIG :: [cont.MAX_SLAB_CLASSES]struct {
  block_size, block_count: u32,
} {
  {block_size = 128, block_count = 2048},
  {block_size = 512, block_count = 1024},
  {block_size = 2048, block_count = 512},
  {block_size = 8192, block_count = 256},
  {block_size = 32768, block_count = 128},
  {block_size = 131072, block_count = 32},
  {block_size = 524288, block_count = 8},
  {block_size = 2097152, block_count = 4},
}

// Buffer capacities come from the slab configs, so a slab can never hand out
// an offset past the end of its buffer.
mesh_manager_init :: proc(
  manager: ^MeshManager,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  cont.slab_init(&manager.vertex_skinning_slab, VERTEX_SLAB_CONFIG)
  cont.slab_init(&manager.vertex_slab, VERTEX_SLAB_CONFIG)
  cont.slab_init(&manager.index_slab, INDEX_SLAB_CONFIG)
  defer if ret != .SUCCESS do mesh_manager_shutdown(manager, gctx)
  manager.vertex_skinning_buffer = gpu.malloc_buffer(
    gctx,
    mesh.SkinningData,
    int(manager.vertex_skinning_slab.capacity),
    {.STORAGE_BUFFER},
  ) or_return
  manager.skinning_set_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.VERTEX}},
  ) or_return
  manager.skinning_set = gpu.create_descriptor_set(
    gctx,
    &manager.skinning_set_layout,
    {.STORAGE_BUFFER, gpu.buffer_info(&manager.vertex_skinning_buffer)},
  ) or_return
  manager.vertex_buffer = gpu.malloc_buffer(
    gctx,
    mesh.Vertex,
    int(manager.vertex_slab.capacity),
    {.VERTEX_BUFFER},
  ) or_return
  manager.index_buffer = gpu.malloc_buffer(
    gctx,
    u32,
    int(manager.index_slab.capacity),
    {.INDEX_BUFFER},
  ) or_return
  log.info("Vertex buffer capacity:", manager.vertex_slab.capacity, "vertices")
  log.info("Index buffer capacity:", manager.index_slab.capacity, "indices")
  return .SUCCESS
}

mesh_manager_shutdown :: proc(manager: ^MeshManager, gctx: ^gpu.GPUContext) {
  cont.slab_destroy(&manager.vertex_skinning_slab)
  gpu.free_descriptor_sets(gctx, manager.skinning_set)
  vk.DestroyDescriptorSetLayout(gctx.device, manager.skinning_set_layout, nil)
  gpu.buffer_destroy(gctx.device, &manager.vertex_skinning_buffer)
  gpu.buffer_destroy(gctx.device, &manager.vertex_buffer)
  gpu.buffer_destroy(gctx.device, &manager.index_buffer)
  cont.slab_destroy(&manager.vertex_slab)
  cont.slab_destroy(&manager.index_slab)
}

@(private)
upload :: proc(
  gctx: ^gpu.GPUContext,
  slab: ^cont.SlabAllocator,
  buffer: ^$B,
  data: []$T,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  if len(data) == 0 do return {}, .SUCCESS
  count := u32(len(data))
  offset, ok := cont.slab_alloc(slab, count)
  if !ok do return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  gpu.write(gctx, buffer, data, int(offset)) or_return
  return {offset = offset, count = count}, .SUCCESS
}

// Upload a geometry's vertices, indices and skinning. On failure the
// allocations made so far are returned for free_mesh.
allocate_mesh :: proc(
  manager: ^MeshManager,
  gctx: ^gpu.GPUContext,
  geometry_data: mesh.Geometry,
) -> (
  allocations: MeshAllocations,
  ret: vk.Result,
) {
  allocations.vertices = upload(
    gctx,
    &manager.vertex_slab,
    &manager.vertex_buffer,
    geometry_data.vertices,
  ) or_return
  allocations.indices = upload(
    gctx,
    &manager.index_slab,
    &manager.index_buffer,
    geometry_data.indices,
  ) or_return
  allocations.skinning = upload(
    gctx,
    &manager.vertex_skinning_slab,
    &manager.vertex_skinning_buffer,
    geometry_data.skinnings,
  ) or_return
  return allocations, .SUCCESS
}

free_mesh :: proc(manager: ^MeshManager, allocations: MeshAllocations) {
  if allocations.vertices.count > 0 do cont.slab_free(&manager.vertex_slab, allocations.vertices.offset)
  if allocations.indices.count > 0 do cont.slab_free(&manager.index_slab, allocations.indices.offset)
  if allocations.skinning.count > 0 do cont.slab_free(&manager.vertex_skinning_slab, allocations.skinning.offset)
}

VERTEX_BINDING_DESCRIPTION := [?]vk.VertexInputBindingDescription {
  {binding = 0, stride = size_of(mesh.Vertex), inputRate = .VERTEX},
}

VERTEX_ATTRIBUTE_DESCRIPTIONS := [?]vk.VertexInputAttributeDescription {
  {
    binding = 0,
    location = 0,
    format = .R32G32B32_SFLOAT,
    offset = u32(offset_of(mesh.Vertex, position)),
  },
  {
    binding = 0,
    location = 1,
    format = .R32G32B32_SFLOAT,
    offset = u32(offset_of(mesh.Vertex, normal)),
  },
  {
    binding = 0,
    location = 2,
    format = .R32G32B32A32_SFLOAT,
    offset = u32(offset_of(mesh.Vertex, color)),
  },
  {
    binding = 0,
    location = 3,
    format = .R32G32_SFLOAT,
    offset = u32(offset_of(mesh.Vertex, uv)),
  },
  {
    binding = 0,
    location = 4,
    format = .R32G32B32A32_SFLOAT,
    offset = u32(offset_of(mesh.Vertex, tangent)),
  },
}

// Position-only view of mesh.Vertex for depth and light-volume passes.
POSITION_ATTRIBUTE_DESCRIPTIONS := [?]vk.VertexInputAttributeDescription {
  {
    binding = 0,
    location = 0,
    format = .R32G32B32_SFLOAT,
    offset = u32(offset_of(mesh.Vertex, position)),
  },
}
