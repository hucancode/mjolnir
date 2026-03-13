package render

import cont "../containers"
import geom "../geometry"
import "../gpu"
import rd "data"
import particles_compute "particles_compute"
import vk "vendor:vulkan"

// DataManager owns all scene/frame GPU buffers: bindless scene data, per-frame
// bone/camera buffers, and particle simulation buffers. It has no knowledge of
// renderers, pipelines, or the frame graph — those live in Manager.
DataManager :: struct {
  // Per-frame buffers
  bone_buffer:                  gpu.PerFrameBindlessBuffer(
    matrix[4, 4]f32,
    FRAMES_IN_FLIGHT,
  ),
  camera_buffer:                gpu.PerFrameBindlessBuffer(
    rd.Camera,
    FRAMES_IN_FLIGHT,
  ),
  // Scene data buffers
  material_buffer:              gpu.BindlessBuffer(Material),
  node_data_buffer:             gpu.BindlessBuffer(Node),
  mesh_data_buffer:             gpu.BindlessBuffer(Mesh),
  emitter_buffer:               gpu.BindlessBuffer(Emitter),
  forcefield_buffer:            gpu.BindlessBuffer(ForceField),
  sprite_buffer:                gpu.BindlessBuffer(Sprite),
  // Bone matrix management
  bone_matrix_slab:             cont.SlabAllocator,
  bone_matrix_offsets:          map[u32]u32,
  // Particle buffers (allocated in setup, freed in teardown)
  particle_buffer:              gpu.MutableBuffer(rd.Particle),
  compact_particle_buffer:      gpu.MutableBuffer(rd.Particle),
  particle_draw_command_buffer: gpu.MutableBuffer(vk.DrawIndirectCommand),
}

// data_manager_init initialises long-lived GPU buffers (survive teardown/setup cycles).
data_manager_init :: proc(
  dm: ^DataManager,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  cont.slab_init(
    &dm.bone_matrix_slab,
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
    &dm.bone_buffer,
    gctx,
    int(dm.bone_matrix_slab.capacity),
    {.VERTEX},
  ) or_return
  dm.bone_matrix_offsets = make(map[u32]u32)
  defer if ret != .SUCCESS {
    delete(dm.bone_matrix_offsets)
    gpu.per_frame_bindless_buffer_destroy(&dm.bone_buffer, gctx.device)
    cont.slab_destroy(&dm.bone_matrix_slab)
  }
  gpu.per_frame_bindless_buffer_init(
    &dm.camera_buffer,
    gctx,
    rd.MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.per_frame_bindless_buffer_destroy(&dm.camera_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &dm.material_buffer,
    gctx,
    rd.MAX_MATERIALS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&dm.material_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &dm.node_data_buffer,
    gctx,
    rd.MAX_NODES_IN_SCENE,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&dm.node_data_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &dm.mesh_data_buffer,
    gctx,
    rd.MAX_MESHES,
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&dm.mesh_data_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &dm.emitter_buffer,
    gctx,
    rd.MAX_EMITTERS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&dm.emitter_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &dm.forcefield_buffer,
    gctx,
    rd.MAX_FORCE_FIELDS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&dm.forcefield_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &dm.sprite_buffer,
    gctx,
    rd.MAX_SPRITES,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&dm.sprite_buffer, gctx.device)
  }
  return .SUCCESS
}

// data_manager_setup reallocates descriptor sets (after ResetDescriptorPool) and
// creates the particle simulation buffers.
data_manager_setup :: proc(
  dm: ^DataManager,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  // Re-allocate descriptor sets for scene buffers
  gpu.bindless_buffer_realloc_descriptor(&dm.material_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&dm.node_data_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&dm.mesh_data_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&dm.emitter_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&dm.forcefield_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&dm.sprite_buffer, gctx) or_return
  gpu.per_frame_bindless_buffer_realloc_descriptors(
    &dm.bone_buffer,
    gctx,
  ) or_return
  gpu.per_frame_bindless_buffer_realloc_descriptors(
    &dm.camera_buffer,
    gctx,
  ) or_return
  // Allocate particle buffers
  dm.particle_buffer = gpu.create_mutable_buffer(
    gctx,
    particles_compute.Particle,
    particles_compute.MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_DST},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &dm.particle_buffer)
  }
  dm.compact_particle_buffer = gpu.create_mutable_buffer(
    gctx,
    particles_compute.Particle,
    particles_compute.MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_SRC},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &dm.compact_particle_buffer)
  }
  dm.particle_draw_command_buffer = gpu.create_mutable_buffer(
    gctx,
    vk.DrawIndirectCommand,
    1,
    {.STORAGE_BUFFER, .INDIRECT_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &dm.particle_draw_command_buffer)
  }
  return .SUCCESS
}

// data_manager_teardown destroys particle buffers and zeros descriptor set handles
// (the pool itself is reset by the caller afterwards).
data_manager_teardown :: proc(dm: ^DataManager, gctx: ^gpu.GPUContext) {
  gpu.mutable_buffer_destroy(gctx.device, &dm.particle_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &dm.compact_particle_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &dm.particle_draw_command_buffer)
  // Zero all descriptor set handles (freed in bulk by ResetDescriptorPool)
  dm.material_buffer.descriptor_set = 0
  dm.node_data_buffer.descriptor_set = 0
  dm.mesh_data_buffer.descriptor_set = 0
  dm.emitter_buffer.descriptor_set = 0
  dm.forcefield_buffer.descriptor_set = 0
  dm.sprite_buffer.descriptor_set = 0
  for &ds in dm.bone_buffer.descriptor_sets do ds = 0
  for &ds in dm.camera_buffer.descriptor_sets do ds = 0
}

// data_manager_shutdown destroys long-lived GPU buffers and frees CPU state.
data_manager_shutdown :: proc(dm: ^DataManager, gctx: ^gpu.GPUContext) {
  gpu.bindless_buffer_destroy(&dm.material_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&dm.node_data_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&dm.mesh_data_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&dm.emitter_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&dm.forcefield_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&dm.sprite_buffer, gctx.device)
  gpu.per_frame_bindless_buffer_destroy(&dm.camera_buffer, gctx.device)
  delete(dm.bone_matrix_offsets)
  gpu.per_frame_bindless_buffer_destroy(&dm.bone_buffer, gctx.device)
  cont.slab_destroy(&dm.bone_matrix_slab)
}

// ── Upload procs ──────────────────────────────────────────────────────────────

upload_node_data :: proc(dm: ^DataManager, index: u32, node_data: ^Node) {
  gpu.write(&dm.node_data_buffer.buffer, node_data, int(index))
}

upload_bone_matrices :: proc(
  dm: ^DataManager,
  frame_index: u32,
  offset: u32,
  matrices: []matrix[4, 4]f32,
) {
  frame_buffer := &dm.bone_buffer.buffers[frame_index]
  if frame_buffer.mapped == nil do return
  l := int(offset)
  r := l + len(matrices)
  gpu_slice := gpu.get_all(frame_buffer)
  copy(gpu_slice[l:r], matrices[:])
}

upload_sprite_data :: proc(
  dm: ^DataManager,
  index: u32,
  sprite_data: ^Sprite,
) {
  gpu.write(&dm.sprite_buffer.buffer, sprite_data, int(index))
}

upload_emitter_data :: proc(dm: ^DataManager, index: u32, emitter: ^Emitter) {
  gpu.write(&dm.emitter_buffer.buffer, emitter, int(index))
}

upload_forcefield_data :: proc(
  dm: ^DataManager,
  index: u32,
  forcefield: ^ForceField,
) {
  gpu.write(&dm.forcefield_buffer.buffer, forcefield, int(index))
}

upload_mesh_data :: proc(dm: ^DataManager, index: u32, mesh: ^Mesh) {
  gpu.write(&dm.mesh_data_buffer.buffer, mesh, int(index))
}

upload_material_data :: proc(
  dm: ^DataManager,
  index: u32,
  material: ^Material,
) {
  gpu.write(&dm.material_buffer.buffer, material, int(index))
}

upload_camera_data :: proc(
  dm: ^DataManager,
  camera_index: u32,
  view, projection: matrix[4, 4]f32,
  position: [3]f32,
  extent: [2]u32,
  near, far: f32,
  frame_index: u32,
) {
  camera_data: rd.Camera
  camera_data.view = view
  camera_data.projection = projection
  camera_data.viewport_extent = {f32(extent[0]), f32(extent[1])}
  camera_data.near = near
  camera_data.far = far
  camera_data.position = [4]f32{position.x, position.y, position.z, 1.0}
  frustum := geom.make_frustum(camera_data.projection * camera_data.view)
  camera_data.frustum_planes = frustum.planes
  gpu.write(
    &dm.camera_buffer.buffers[frame_index],
    &camera_data,
    int(camera_index),
  )
}

// ── Bone matrix management ────────────────────────────────────────────────────

ensure_bone_matrix_range_for_node :: proc(
  dm: ^DataManager,
  handle: u32,
  bone_count: u32,
) -> u32 {
  if existing, ok := dm.bone_matrix_offsets[handle]; ok {
    return existing
  }
  offset := cont.slab_alloc(&dm.bone_matrix_slab, bone_count)
  if offset == 0xFFFFFFFF do return 0xFFFFFFFF
  dm.bone_matrix_offsets[handle] = offset
  return offset
}

release_bone_matrix_range_for_node :: proc(dm: ^DataManager, handle: u32) {
  if offset, ok := dm.bone_matrix_offsets[handle]; ok {
    cont.slab_free(&dm.bone_matrix_slab, offset)
    delete_key(&dm.bone_matrix_offsets, handle)
  }
}

// ── Mesh geometry management ──────────────────────────────────────────────────

sync_mesh_geometry_for_handle :: proc(
  gctx: ^gpu.GPUContext,
  dm: ^DataManager,
  mesh_manager: ^gpu.MeshManager,
  handle: u32,
  geometry_data: geom.Geometry,
) -> vk.Result {
  mesh := gpu.mutable_buffer_get(&dm.mesh_data_buffer.buffer, handle)
  if mesh.index_count > 0 {
    gpu.free_vertices(
      mesh_manager,
      BufferAllocation{offset = u32(mesh.vertex_offset), count = 1},
    )
    gpu.free_indices(
      mesh_manager,
      BufferAllocation{offset = mesh.first_index, count = 1},
    )
    if .SKINNED in mesh.flags {
      gpu.free_vertex_skinning(
        mesh_manager,
        BufferAllocation{offset = mesh.skinning_offset, count = 1},
      )
    }
  }
  mesh.aabb_min = geometry_data.aabb.min
  mesh.aabb_max = geometry_data.aabb.max
  mesh.flags = {}
  mesh.index_count = u32(len(geometry_data.indices))
  vertex_allocation := gpu.allocate_vertices(
    mesh_manager,
    gctx,
    geometry_data.vertices,
  ) or_return
  index_allocation := gpu.allocate_indices(
    mesh_manager,
    gctx,
    geometry_data.indices,
  ) or_return
  mesh.first_index = index_allocation.offset
  mesh.vertex_offset = i32(vertex_allocation.offset)
  mesh.skinning_offset = 0
  if len(geometry_data.skinnings) > 0 {
    skinning_allocation := gpu.allocate_vertex_skinning(
      mesh_manager,
      gctx,
      geometry_data.skinnings,
    ) or_return
    mesh.skinning_offset = skinning_allocation.offset
    mesh.flags |= {.SKINNED}
  }
  return .SUCCESS
}

free_mesh_geometry :: proc(
  dm: ^DataManager,
  mesh_manager: ^gpu.MeshManager,
  handle: u32,
) {
  mesh := gpu.mutable_buffer_get(&dm.mesh_data_buffer.buffer, handle)
  if mesh.index_count > 0 {
    gpu.free_vertices(
      mesh_manager,
      BufferAllocation{offset = u32(mesh.vertex_offset), count = 1},
    )
    gpu.free_indices(
      mesh_manager,
      BufferAllocation{offset = mesh.first_index, count = 1},
    )
  }
  if .SKINNED in mesh.flags {
    gpu.free_vertex_skinning(
      mesh_manager,
      BufferAllocation{offset = mesh.skinning_offset, count = 1},
    )
  }
  mesh^ = {}
}

// ── Texture descriptor helpers ────────────────────────────────────────────────

set_texture_2d_descriptor :: proc(
  gctx: ^gpu.GPUContext,
  textures_descriptor_set: vk.DescriptorSet,
  texture_index: u32,
  image_view: vk.ImageView,
) {
  if texture_index >= gpu.MAX_TEXTURES {
    return
  }
  if textures_descriptor_set == 0 {
    return
  }
  gpu.update_descriptor_set_array_offset(
    gctx,
    textures_descriptor_set,
    0,
    texture_index,
    {
      .SAMPLED_IMAGE,
      vk.DescriptorImageInfo {
        imageView = image_view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    },
  )
}

set_texture_cube_descriptor :: proc(
  gctx: ^gpu.GPUContext,
  textures_descriptor_set: vk.DescriptorSet,
  texture_index: u32,
  image_view: vk.ImageView,
) {
  if texture_index >= gpu.MAX_CUBE_TEXTURES {
    return
  }
  if textures_descriptor_set == 0 {
    return
  }
  gpu.update_descriptor_set_array_offset(
    gctx,
    textures_descriptor_set,
    2,
    texture_index,
    {
      .SAMPLED_IMAGE,
      vk.DescriptorImageInfo {
        imageView = image_view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    },
  )
}
