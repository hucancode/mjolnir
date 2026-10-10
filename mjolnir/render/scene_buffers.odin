package render

import "bindless"
import cont "../containers"
import geom "../geometry"
import "mesh"
import "gpu"
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
  gpu.bindless_buffer_init(
    &self.internal.material_buffer,
    gctx,
    MAX_MATERIALS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.material_buffer, gctx)
  }
  gpu.bindless_buffer_init(
    &self.internal.node_data_buffer,
    gctx,
    MAX_NODES_IN_SCENE,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.node_data_buffer, gctx)
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
  gpu.bindless_buffer_init(
    &self.internal.emitter_buffer,
    gctx,
    MAX_EMITTERS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.emitter_buffer, gctx)
  }
  gpu.bindless_buffer_init(
    &self.internal.forcefield_buffer,
    gctx,
    MAX_FORCE_FIELDS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.internal.forcefield_buffer, gctx)
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
  gpu.bindless_buffer_destroy(&self.internal.material_buffer, gctx)
  gpu.bindless_buffer_destroy(&self.internal.node_data_buffer, gctx)
  gpu.bindless_buffer_destroy(&self.internal.mesh_data_buffer, gctx)
  gpu.bindless_buffer_destroy(&self.internal.emitter_buffer, gctx)
  gpu.bindless_buffer_destroy(&self.internal.forcefield_buffer, gctx)
  gpu.bindless_buffer_destroy(&self.internal.sprite_buffer, gctx)
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
  m.allocations, res = bindless.allocate_mesh(&render.mesh_manager, gctx, geometry_data)
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
upload_node_data :: proc(render: ^Manager, index: u32, node_data: ^NodeData) {
  assert(index < MAX_NODES_IN_SCENE, "node index exceeds MAX_NODES_IN_SCENE")
  gpu.write(&render.internal.node_data_buffer.buffer, node_data, int(index))
}

@(private)
upload_bone_matrices :: proc(
  render: ^Manager,
  frame_index: u32,
  offset: u32,
  matrices: []matrix[4, 4]f32,
) {
  assert(int(frame_index) < gpu.FRAMES_IN_FLIGHT, "frame_index out of range")
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

@(private)
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
  assert(int(frame_index) < gpu.FRAMES_IN_FLIGHT, "frame_index out of range")
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
