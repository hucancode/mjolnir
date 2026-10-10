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

MeshManager :: struct {
  vertex_skinning_buffer: gpu.ImmutableBindlessBuffer(mesh.SkinningData),
  vertex_buffer:          gpu.ImmutableBuffer(mesh.Vertex),
  index_buffer:           gpu.ImmutableBuffer(u32),
  vertex_skinning_slab:   cont.SlabAllocator,
  vertex_slab:            cont.SlabAllocator,
  index_slab:             cont.SlabAllocator,
}

BINDLESS_VERTEX_BUFFER_SIZE :: 128 * 1024 * 1024
BINDLESS_INDEX_BUFFER_SIZE :: 64 * 1024 * 1024
BINDLESS_SKINNING_BUFFER_SIZE :: 128 * 1024 * 1024

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

mesh_manager_init :: proc(
  manager: ^MeshManager,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  skinning_count := BINDLESS_SKINNING_BUFFER_SIZE / size_of(mesh.SkinningData)
  log.infof(
    "Creating vertex skinning buffer with capacity %d entries...",
    skinning_count,
  )
  gpu.immutable_bindless_buffer_init(
    &manager.vertex_skinning_buffer,
    gctx,
    skinning_count,
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.immutable_bindless_buffer_destroy(&manager.vertex_skinning_buffer, gctx.device)
  }
  cont.slab_init(&manager.vertex_skinning_slab, VERTEX_SLAB_CONFIG)
  defer if ret != .SUCCESS {
    cont.slab_destroy(&manager.vertex_skinning_slab)
  }

  vertex_count := BINDLESS_VERTEX_BUFFER_SIZE / size_of(mesh.Vertex)
  index_count := BINDLESS_INDEX_BUFFER_SIZE / size_of(u32)
  manager.vertex_buffer = gpu.malloc_buffer(
    gctx,
    mesh.Vertex,
    vertex_count,
    {.VERTEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.buffer_destroy(gctx.device, &manager.vertex_buffer)
  }
  manager.index_buffer = gpu.malloc_buffer(
    gctx,
    u32,
    index_count,
    {.INDEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.buffer_destroy(gctx.device, &manager.index_buffer)
  }
  cont.slab_init(&manager.vertex_slab, VERTEX_SLAB_CONFIG)
  defer if ret != .SUCCESS {
    cont.slab_destroy(&manager.vertex_slab)
  }
  cont.slab_init(&manager.index_slab, INDEX_SLAB_CONFIG)
  defer if ret != .SUCCESS {
    cont.slab_destroy(&manager.index_slab)
  }
  log.info("Vertex buffer capacity:", vertex_count, "vertices")
  log.info("Index buffer capacity:", index_count, "indices")
  return .SUCCESS
}

mesh_manager_shutdown :: proc(manager: ^MeshManager, gctx: ^gpu.GPUContext) {
  cont.slab_destroy(&manager.vertex_skinning_slab)
  gpu.immutable_bindless_buffer_destroy(&manager.vertex_skinning_buffer, gctx.device)
  gpu.buffer_destroy(gctx.device, &manager.vertex_buffer)
  gpu.buffer_destroy(gctx.device, &manager.index_buffer)
  cont.slab_destroy(&manager.vertex_slab)
  cont.slab_destroy(&manager.index_slab)
}

// Re-allocate descriptor sets for the mesh manager after ResetDescriptorPool.
mesh_manager_realloc_descriptors :: proc(
  manager: ^MeshManager,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  return gpu.immutable_bindless_buffer_realloc_descriptor(
    &manager.vertex_skinning_buffer,
    gctx,
  )
}

allocate_vertices :: proc(
  manager: ^MeshManager,
  gctx: ^gpu.GPUContext,
  vertices: []mesh.Vertex,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  vertex_count := u32(len(vertices))
  offset, ok := cont.slab_alloc(&manager.vertex_slab, vertex_count)
  if !ok {
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  gpu.write(gctx, &manager.vertex_buffer, vertices, int(offset)) or_return
  return BufferAllocation{offset = offset, count = vertex_count}, .SUCCESS
}

allocate_indices :: proc(
  manager: ^MeshManager,
  gctx: ^gpu.GPUContext,
  indices: []u32,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  index_count := u32(len(indices))
  offset, ok := cont.slab_alloc(&manager.index_slab, index_count)
  if !ok {
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  gpu.write(gctx, &manager.index_buffer, indices, int(offset)) or_return
  return BufferAllocation{offset = offset, count = index_count}, .SUCCESS
}

allocate_vertex_skinning :: proc(
  manager: ^MeshManager,
  gctx: ^gpu.GPUContext,
  skinnings: []mesh.SkinningData,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  if len(skinnings) == 0 {
    return {}, .SUCCESS
  }
  skinning_count := u32(len(skinnings))
  offset, ok := cont.slab_alloc(&manager.vertex_skinning_slab, skinning_count)
  if !ok {
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  gpu.write(
    gctx,
    &manager.vertex_skinning_buffer,
    skinnings,
    int(offset),
  ) or_return
  return BufferAllocation{offset = offset, count = skinning_count}, .SUCCESS
}

free_vertices :: proc(manager: ^MeshManager, allocation: BufferAllocation) {
  cont.slab_free(&manager.vertex_slab, allocation.offset)
}

free_indices :: proc(manager: ^MeshManager, allocation: BufferAllocation) {
  cont.slab_free(&manager.index_slab, allocation.offset)
}

free_vertex_skinning :: proc(manager: ^MeshManager, allocation: BufferAllocation) {
  cont.slab_free(&manager.vertex_skinning_slab, allocation.offset)
}

allocate_mesh :: proc(
  manager: ^MeshManager,
  gctx: ^gpu.GPUContext,
  geometry_data: mesh.Geometry,
) -> (
  allocations: MeshAllocations,
  has_skinning: bool,
  ret: vk.Result,
) {
  allocations.vertices = allocate_vertices(manager, gctx, geometry_data.vertices) or_return
  allocations.indices = allocate_indices(manager, gctx, geometry_data.indices) or_return
  has_skinning = len(geometry_data.skinnings) > 0
  if has_skinning {
    allocations.skinning = allocate_vertex_skinning(
      manager,
      gctx,
      geometry_data.skinnings,
    ) or_return
  }
  return allocations, has_skinning, .SUCCESS
}

free_mesh :: proc(
  manager: ^MeshManager,
  vertex_allocation: BufferAllocation,
  index_allocation: BufferAllocation,
  skinning_allocation: BufferAllocation,
  has_skinning: bool,
) {
  if has_skinning && skinning_allocation.count > 0 {
    free_vertex_skinning(manager, skinning_allocation)
  }
  free_vertices(manager, vertex_allocation)
  free_indices(manager, index_allocation)
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
