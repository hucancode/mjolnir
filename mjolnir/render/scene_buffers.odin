package render

import cont "../containers"
import "mesh"
import "gpu"
import vk "vendor:vulkan"

// Starting bone size classes, about 16 MB per frame in flight. Every class
// doubles when one runs out (grow_bones); classes with no blocks never grow.
@(private)
BONE_SLAB_CONFIG :: [cont.MAX_SLAB_CLASSES]struct {
  block_size, block_count: u32,
} {
  {block_size = 32, block_count = 256},
  {block_size = 64, block_count = 256},
  {block_size = 128, block_count = 1024},
  {block_size = 256, block_count = 256},
  {block_size = 512, block_count = 32},
  {block_size = 1024, block_count = 8},
  {block_size = 0, block_count = 0},
  {block_size = 0, block_count = 0},
}

// Allocate every per-resource bindless buffer + the bone slab. Paired with
// destroy_scene_buffers. Called once during render.init before any subsystem
// pipelines (which take these buffer set layouts as descriptor inputs).
@(private)
init_scene_buffers :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  cont.slab_init(&self.internal.bone_matrix_slab, BONE_SLAB_CONFIG)
  gpu.per_frame_bindless_buffer_init(
    &self.internal.bone_buffer,
    gctx,
    int(self.internal.bone_matrix_slab.capacity),
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.per_frame_bindless_buffer_destroy(&self.internal.bone_buffer, gctx)
    cont.slab_destroy(&self.internal.bone_matrix_slab)
  }
  gpu.per_frame_bindless_buffer_init(
    &self.internal.camera_buffer,
    gctx,
    MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.per_frame_bindless_buffer_destroy(&self.internal.camera_buffer, gctx)
  }
  gpu.per_frame_bindless_buffer_init(
    &self.internal.material_buffer,
    gctx,
    MAX_MATERIALS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.per_frame_bindless_buffer_destroy(&self.internal.material_buffer, gctx)
  }
  gpu.per_frame_bindless_buffer_init(
    &self.internal.node_data_buffer,
    gctx,
    MAX_NODES_IN_SCENE,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.per_frame_bindless_buffer_destroy(&self.internal.node_data_buffer, gctx)
  }
  gpu.bindless_buffer_init(
    &self.internal.mesh_data_buffer,
    gctx,
    MAX_MESHES,
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.mesh_data_buffer, gctx)
  }
  gpu.per_frame_bindless_buffer_init(
    &self.internal.emitter_buffer,
    gctx,
    MAX_EMITTERS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.per_frame_bindless_buffer_destroy(&self.internal.emitter_buffer, gctx)
  }
  gpu.per_frame_bindless_buffer_init(
    &self.internal.forcefield_buffer,
    gctx,
    MAX_FORCE_FIELDS,
    {.COMPUTE},
  ) or_return
  return .SUCCESS
}

@(private)
destroy_scene_buffers :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.per_frame_bindless_buffer_destroy(&self.internal.material_buffer, gctx)
  gpu.per_frame_bindless_buffer_destroy(&self.internal.node_data_buffer, gctx)
  gpu.bindless_buffer_destroy(&self.internal.mesh_data_buffer, gctx)
  gpu.per_frame_bindless_buffer_destroy(&self.internal.emitter_buffer, gctx)
  gpu.per_frame_bindless_buffer_destroy(&self.internal.forcefield_buffer, gctx)
  gpu.per_frame_bindless_buffer_destroy(&self.internal.camera_buffer, gctx)
  gpu.per_frame_bindless_buffer_destroy(&self.internal.bone_buffer, gctx)
  cont.slab_destroy(&self.internal.bone_matrix_slab)
}

// Upload a mesh's CPU geometry into the mesh manager and describe it in
// mesh_data_buffer at `index`. Its allocations are freed by mesh_retire.
@(private)
upload_mesh :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  index: u32,
  m: ^Mesh,
  geometry_data: mesh.Geometry,
) -> vk.Result {
  res: vk.Result
  m.allocations, res = allocate_mesh(&render.mesh_manager, gctx, geometry_data)
  if res != .SUCCESS do return res
  aabb := mesh.aabb_from_vertices(geometry_data.vertices)
  data := MeshData {
    aabb_min        = aabb.min,
    aabb_max        = aabb.max,
    index_count     = u32(len(geometry_data.indices)),
    first_index     = m.allocations.indices.offset,
    vertex_offset   = i32(m.allocations.vertices.offset),
    skinning_offset = m.allocations.skinning.offset,
  }
  if m.allocations.skinning.count > 0 do data.flags |= {.SKINNED}
  gpu.write(&render.internal.mesh_data_buffer.buffer, &data, int(index))
  return .SUCCESS
}

@(private)
upload_bone_matrices :: proc(
  render: ^Manager,
  frame_index: u32,
  offset: u32,
  matrices: []matrix[4, 4]f32,
) {
  assert(int(frame_index) < gpu.FRAMES_IN_FLIGHT, "frame_index out of range")
  frame_buffer := &render.internal.bone_buffer.buffers[frame_index]
  if frame_buffer.mapped == nil do return
  l := int(offset)
  r := l + len(matrices)
  gpu_slice := gpu.get_all(frame_buffer)
  assert(r <= len(gpu_slice), "bone matrix range exceeds the bone buffer")
  copy(gpu_slice[l:r], matrices[:])
}
