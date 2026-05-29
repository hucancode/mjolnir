package render

import cont "../containers"
import geom "../geometry"
import "../gpu"
import vk "vendor:vulkan"

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
  cont.slab_init(
    &self.internal.bone_matrix_slab,
    {
      {32, 64},
      {64, 128},
      {128, 4096},
      {256, 1792},
      {512, 0},
      {1024, 0},
      {2048, 0},
      {4096, 0},
    },
  )
  gpu.per_frame_bindless_buffer_init(
    &self.internal.bone_buffer,
    gctx,
    int(self.internal.bone_matrix_slab.capacity),
    {.VERTEX},
  ) or_return
  self.internal.bone_matrix_offsets = make(map[u32]u32)
  defer if ret != .SUCCESS {
    delete(self.internal.bone_matrix_offsets)
    gpu.per_frame_bindless_buffer_destroy(&self.internal.bone_buffer, gctx.device)
    cont.slab_destroy(&self.internal.bone_matrix_slab)
  }
  gpu.per_frame_bindless_buffer_init(
    &self.internal.camera_buffer,
    gctx,
    MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.per_frame_bindless_buffer_destroy(&self.internal.camera_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.internal.material_buffer,
    gctx,
    MAX_MATERIALS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.material_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.internal.node_data_buffer,
    gctx,
    MAX_NODES_IN_SCENE,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.node_data_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.internal.mesh_data_buffer,
    gctx,
    MAX_MESHES,
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.mesh_data_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.internal.emitter_buffer,
    gctx,
    MAX_EMITTERS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.emitter_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.internal.forcefield_buffer,
    gctx,
    MAX_FORCE_FIELDS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.forcefield_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.internal.sprite_buffer,
    gctx,
    MAX_SPRITES,
    {.VERTEX, .FRAGMENT},
  ) or_return
  return .SUCCESS
}

@(private)
destroy_scene_buffers :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.bindless_buffer_destroy(&self.internal.material_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.internal.node_data_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.internal.mesh_data_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.internal.emitter_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.internal.forcefield_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.internal.sprite_buffer, gctx.device)
  gpu.per_frame_bindless_buffer_destroy(&self.internal.camera_buffer, gctx.device)
  delete(self.internal.bone_matrix_offsets)
  gpu.per_frame_bindless_buffer_destroy(&self.internal.bone_buffer, gctx.device)
  cont.slab_destroy(&self.internal.bone_matrix_slab)
}

// Re-bind all scene buffer descriptor sets after the descriptor pool is reset
// (happens during full teardown -> setup cycles around the swapchain).
@(private)
realloc_scene_descriptors :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  gpu.bindless_buffer_realloc_descriptor(&self.internal.material_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.internal.node_data_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.internal.mesh_data_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.internal.emitter_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.internal.forcefield_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&self.internal.sprite_buffer, gctx) or_return
  gpu.per_frame_bindless_buffer_realloc_descriptors(&self.internal.bone_buffer, gctx) or_return
  gpu.per_frame_bindless_buffer_realloc_descriptors(&self.internal.camera_buffer, gctx) or_return
  gpu.mesh_manager_realloc_descriptors(&self.mesh_manager, gctx) or_return
  return .SUCCESS
}

// Zero descriptor set handles after a pool reset so a future realloc rebinds
// them cleanly. The actual VkDescriptorSet objects were freed in bulk by
// ResetDescriptorPool.
@(private)
clear_scene_descriptor_handles :: proc(self: ^Manager) {
  self.internal.material_buffer.descriptor_set = 0
  self.internal.node_data_buffer.descriptor_set = 0
  self.internal.mesh_data_buffer.descriptor_set = 0
  self.internal.emitter_buffer.descriptor_set = 0
  self.internal.forcefield_buffer.descriptor_set = 0
  self.internal.sprite_buffer.descriptor_set = 0
  for &ds in self.internal.bone_buffer.descriptor_sets do ds = 0
  for &ds in self.internal.camera_buffer.descriptor_sets do ds = 0
  self.mesh_manager.vertex_skinning_buffer.descriptor_set = 0
}

ensure_bone_matrix_range_for_node :: proc(
  render: ^Manager,
  handle: u32,
  bone_count: u32,
) -> u32 {
  if existing, ok := render.internal.bone_matrix_offsets[handle]; ok {
    return existing
  }
  offset := cont.slab_alloc(&render.internal.bone_matrix_slab, bone_count)
  if offset == 0xFFFFFFFF do return 0xFFFFFFFF
  render.internal.bone_matrix_offsets[handle] = offset
  return offset
}

release_bone_matrix_range_for_node :: proc(render: ^Manager, handle: u32) {
  if offset, ok := render.internal.bone_matrix_offsets[handle]; ok {
    cont.slab_free(&render.internal.bone_matrix_slab, offset)
    delete_key(&render.internal.bone_matrix_offsets, handle)
  }
}

sync_mesh_geometry_for_handle :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  handle: u32,
  geometry_data: geom.Geometry,
) -> vk.Result {
  mesh := gpu.mutable_buffer_get(&render.internal.mesh_data_buffer.buffer, handle)
  if mesh.index_count > 0 {
    gpu.free_vertices(
      &render.mesh_manager,
      BufferAllocation{offset = u32(mesh.vertex_offset), count = 1},
    )
    gpu.free_indices(
      &render.mesh_manager,
      BufferAllocation{offset = mesh.first_index, count = 1},
    )
    if .SKINNED in mesh.flags {
      gpu.free_vertex_skinning(
        &render.mesh_manager,
        BufferAllocation{offset = mesh.skinning_offset, count = 1},
      )
    }
  }
  mesh.aabb_min = geometry_data.aabb.min
  mesh.aabb_max = geometry_data.aabb.max
  mesh.flags = {}
  mesh.index_count = u32(len(geometry_data.indices))
  vertex_allocation := gpu.allocate_vertices(
    &render.mesh_manager,
    gctx,
    geometry_data.vertices,
  ) or_return
  index_allocation := gpu.allocate_indices(
    &render.mesh_manager,
    gctx,
    geometry_data.indices,
  ) or_return
  mesh.first_index = index_allocation.offset
  mesh.vertex_offset = i32(vertex_allocation.offset)
  mesh.skinning_offset = 0
  if len(geometry_data.skinnings) > 0 {
    skinning_allocation := gpu.allocate_vertex_skinning(
      &render.mesh_manager,
      gctx,
      geometry_data.skinnings,
    ) or_return
    mesh.skinning_offset = skinning_allocation.offset
    mesh.flags |= {.SKINNED}
  }
  return .SUCCESS
}

mesh_destroy :: proc(render: ^Manager, handle: u32) {
  mesh := gpu.mutable_buffer_get(&render.internal.mesh_data_buffer.buffer, handle)
  if mesh.index_count > 0 {
    gpu.free_vertices(
      &render.mesh_manager,
      BufferAllocation{offset = u32(mesh.vertex_offset), count = 1},
    )
    gpu.free_indices(
      &render.mesh_manager,
      BufferAllocation{offset = mesh.first_index, count = 1},
    )
  }
  if .SKINNED in mesh.flags {
    gpu.free_vertex_skinning(
      &render.mesh_manager,
      BufferAllocation{offset = mesh.skinning_offset, count = 1},
    )
  }
  mesh^ = {}
}

upload_node_data :: proc(render: ^Manager, index: u32, node_data: ^Node) {
  assert(index < MAX_NODES_IN_SCENE, "node index exceeds MAX_NODES_IN_SCENE")
  gpu.write(&render.internal.node_data_buffer.buffer, node_data, int(index))
}

upload_bone_matrices :: proc(
  render: ^Manager,
  frame_index: u32,
  offset: u32,
  matrices: []matrix[4, 4]f32,
) {
  assert(int(frame_index) < FRAMES_IN_FLIGHT, "frame_index out of range")
  assert(
    int(offset) + len(matrices) <= int(render.internal.bone_matrix_slab.capacity),
    "bone matrix range exceeds slab capacity",
  )
  frame_buffer := &render.internal.bone_buffer.buffers[frame_index]
  if frame_buffer.mapped == nil do return
  l := int(offset)
  r := l + len(matrices)
  gpu_slice := gpu.get_all(frame_buffer)
  copy(gpu_slice[l:r], matrices[:])
}

upload_sprite_data :: proc(
  render: ^Manager,
  index: u32,
  sprite_data: ^Sprite,
) {
  assert(index < MAX_SPRITES, "sprite index exceeds MAX_SPRITES")
  gpu.write(&render.internal.sprite_buffer.buffer, sprite_data, int(index))
}

upload_emitter_data :: proc(render: ^Manager, index: u32, emitter: ^Emitter) {
  assert(index < MAX_EMITTERS, "emitter index exceeds MAX_EMITTERS")
  gpu.write(&render.internal.emitter_buffer.buffer, emitter, int(index))
}

upload_forcefield_data :: proc(
  render: ^Manager,
  index: u32,
  forcefield: ^ForceField,
) {
  assert(index < MAX_FORCE_FIELDS, "forcefield index exceeds MAX_FORCE_FIELDS")
  gpu.write(&render.internal.forcefield_buffer.buffer, forcefield, int(index))
}

upload_mesh_data :: proc(render: ^Manager, index: u32, mesh: ^Mesh) {
  assert(index < MAX_MESHES, "mesh index exceeds MAX_MESHES")
  gpu.write(&render.internal.mesh_data_buffer.buffer, mesh, int(index))
}

upload_material_data :: proc(
  render: ^Manager,
  index: u32,
  material: ^Material,
) {
  assert(index < MAX_MATERIALS, "material index exceeds MAX_MATERIALS")
  gpu.write(&render.internal.material_buffer.buffer, material, int(index))
}

upload_camera_data :: proc(
  render: ^Manager,
  camera_index: u32,
  view, projection: matrix[4, 4]f32,
  position: [3]f32,
  extent: [2]u32,
  near, far: f32,
  frame_index: u32,
) {
  assert(camera_index < MAX_ACTIVE_CAMERAS, "camera index exceeds MAX_ACTIVE_CAMERAS")
  assert(int(frame_index) < FRAMES_IN_FLIGHT, "frame_index out of range")
  camera_data: CameraGPU
  camera_data.view = view
  camera_data.projection = projection
  camera_data.viewport_extent = {f32(extent[0]), f32(extent[1])}
  camera_data.near = near
  camera_data.far = far
  camera_data.position = [4]f32{position.x, position.y, position.z, 1.0}
  frustum := geom.make_frustum(camera_data.projection * camera_data.view)
  camera_data.frustum_planes = frustum.planes
  gpu.write(
    &render.internal.camera_buffer.buffers[frame_index],
    &camera_data,
    int(camera_index),
  )
}
