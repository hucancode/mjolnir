package render

import cont "../containers"
import d "data"
import "../geometry"
import "../gpu"
import rd "data"
import cam "camera"
import "core:log"
import "core:math"
import "core:math/linalg"
import light "lighting"
import vk "vendor:vulkan"

allocate_vertices :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  vertices: []geometry.Vertex,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  return gpu.allocate_vertices(&render.mesh_manager, gctx, vertices)
}

allocate_indices :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  indices: []u32,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  return gpu.allocate_indices(&render.mesh_manager, gctx, indices)
}

allocate_vertex_skinning :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  skinnings: []geometry.SkinningData,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  return gpu.allocate_vertex_skinning(&render.mesh_manager, gctx, skinnings)
}

free_vertices :: proc(render: ^Manager, allocation: BufferAllocation) {
  gpu.free_vertices(&render.mesh_manager, allocation)
}

free_indices :: proc(render: ^Manager, allocation: BufferAllocation) {
  gpu.free_indices(&render.mesh_manager, allocation)
}

free_vertex_skinning :: proc(
  render: ^Manager,
  allocation: BufferAllocation,
) {
  gpu.free_vertex_skinning(&render.mesh_manager, allocation)
}

allocate_mesh_geometry :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  geometry_data: geometry.Geometry,
) -> (
  handle: d.MeshHandle,
  ret: vk.Result,
) {
  mesh: ^Mesh
  ok: bool
  handle, mesh, ok = cont.alloc(&render.meshes, d.MeshHandle)
  if !ok do return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  mesh.aabb_min = geometry_data.aabb.min
  mesh.aabb_max = geometry_data.aabb.max
  mesh.flags = {}
  mesh.index_count = u32(len(geometry_data.indices))
  vertex_allocation := allocate_vertices(render, gctx, geometry_data.vertices) or_return
  index_allocation := allocate_indices(render, gctx, geometry_data.indices) or_return
  mesh.first_index = index_allocation.offset
  mesh.vertex_offset = i32(vertex_allocation.offset)
  mesh.skinning_offset = 0
  if len(geometry_data.skinnings) > 0 {
    skinning_allocation := allocate_vertex_skinning(
      render,
      gctx,
      geometry_data.skinnings,
    ) or_return
    mesh.skinning_offset = skinning_allocation.offset
    mesh.flags |= {.SKINNED}
  }
  upload_mesh_data(render, handle, mesh)
  return handle, .SUCCESS
}

sync_mesh_geometry_for_handle :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  handle: d.MeshHandle,
  geometry_data: geometry.Geometry,
) -> vk.Result {
  mesh := ensure_mesh_slot(render, handle)
  if mesh.index_count > 0 {
    free_vertices(render, BufferAllocation{offset = u32(mesh.vertex_offset), count = 1})
    free_indices(render, BufferAllocation{offset = mesh.first_index, count = 1})
    if .SKINNED in mesh.flags {
      free_vertex_skinning(render, BufferAllocation{offset = mesh.skinning_offset, count = 1})
    }
  }
  mesh.aabb_min = geometry_data.aabb.min
  mesh.aabb_max = geometry_data.aabb.max
  mesh.flags = {}
  mesh.index_count = u32(len(geometry_data.indices))
  vertex_allocation := allocate_vertices(render, gctx, geometry_data.vertices) or_return
  index_allocation := allocate_indices(render, gctx, geometry_data.indices) or_return
  mesh.first_index = index_allocation.offset
  mesh.vertex_offset = i32(vertex_allocation.offset)
  mesh.skinning_offset = 0
  if len(geometry_data.skinnings) > 0 {
    skinning_allocation := allocate_vertex_skinning(
      render,
      gctx,
      geometry_data.skinnings,
    ) or_return
    mesh.skinning_offset = skinning_allocation.offset
    mesh.flags |= {.SKINNED}
  }
  upload_mesh_data(render, handle, mesh)
  return .SUCCESS
}

free_mesh_geometry :: proc(render: ^Manager, handle: d.MeshHandle) {
  mesh, ok := cont.free(&render.meshes, handle)
  if !ok do return
  if mesh.index_count > 0 {
    free_vertices(render, BufferAllocation{offset = u32(mesh.vertex_offset), count = 1})
    free_indices(render, BufferAllocation{offset = mesh.first_index, count = 1})
  }
  if .SKINNED in mesh.flags {
    free_vertex_skinning(render, BufferAllocation{offset = mesh.skinning_offset, count = 1})
  }
}

create_empty_texture_2d :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  width, height: u32,
  format: vk.Format,
  usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT, .SAMPLED},
) -> (
  handle: gpu.Texture2DHandle,
  ret: vk.Result,
) {
  gpu_handle, gpu_ret := gpu.allocate_texture_2d(
    &render.texture_manager,
    gctx,
    width,
    height,
    format,
    usage,
  )
  if gpu_ret != .SUCCESS {
    return {}, gpu_ret
  }
  handle = transmute(gpu.Texture2DHandle)gpu_handle
  return handle, .SUCCESS
}

create_empty_texture_cube :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  size: u32,
  format: vk.Format = .D32_SFLOAT,
  usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
) -> (
  handle: gpu.TextureCubeHandle,
  ret: vk.Result,
) {
  gpu_handle, gpu_ret := gpu.allocate_texture_cube(
    &render.texture_manager,
    gctx,
    size,
    format,
    usage,
  )
  if gpu_ret != .SUCCESS {
    return {}, gpu_ret
  }
  handle = transmute(gpu.TextureCubeHandle)gpu_handle
  return handle, .SUCCESS
}

create_texture_from_path :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  path: string,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
  usage: vk.ImageUsageFlags = {.SAMPLED},
  is_hdr := false,
) -> (
  handle: gpu.Texture2DHandle,
  ret: vk.Result,
) {
  gpu_handle, gpu_ret := gpu.create_texture_2d_from_path(
    gctx,
    &render.texture_manager,
    path,
    format,
    generate_mips,
    usage,
    is_hdr,
  )
  if gpu_ret != .SUCCESS {
    return {}, gpu_ret
  }
  handle = transmute(gpu.Texture2DHandle)gpu_handle
  return handle, .SUCCESS
}

create_texture_from_data :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  data: []u8,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (
  handle: gpu.Texture2DHandle,
  ret: vk.Result,
) {
  gpu_handle, gpu_ret := gpu.create_texture_2d_from_data(
    gctx,
    &render.texture_manager,
    data,
    format,
    generate_mips,
  )
  if gpu_ret != .SUCCESS {
    return {}, gpu_ret
  }
  handle = transmute(gpu.Texture2DHandle)gpu_handle
  return handle, .SUCCESS
}

create_texture_from_pixels :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  pixels: []u8,
  width, height: int,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (
  handle: gpu.Texture2DHandle,
  ret: vk.Result,
) {
  gpu_handle, gpu_ret := gpu.allocate_texture_2d_with_data(
    &render.texture_manager,
    gctx,
    raw_data(pixels),
    vk.DeviceSize(len(pixels)),
    u32(width),
    u32(height),
    format,
    {.SAMPLED},
    generate_mips,
  )
  if gpu_ret != .SUCCESS {
    return {}, gpu_ret
  }
  handle = transmute(gpu.Texture2DHandle)gpu_handle
  return handle, .SUCCESS
}

create_texture :: proc {
  create_empty_texture_2d,
  create_texture_from_path,
  create_texture_from_data,
  create_texture_from_pixels,
}

create_cube_texture :: proc {
  create_empty_texture_cube,
}

destroy_texture :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  handle: gpu.Texture2DHandle,
) {
  gpu.free_texture_2d(&render.texture_manager, gctx, handle)
}

set_texture_2d_descriptor :: proc(
  gctx: ^gpu.GPUContext,
  textures_descriptor_set: vk.DescriptorSet,
  texture_index: u32,
  image_view: vk.ImageView,
) {
  if texture_index >= d.MAX_TEXTURES {
    log.warnf("Index %d out of bounds for bindless textures", texture_index)
    return
  }
  if textures_descriptor_set == 0 {
    log.error("textures_descriptor_set is not initialized")
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
  if texture_index >= d.MAX_CUBE_TEXTURES {
    log.warnf(
      "Index %d out of bounds for bindless cube textures",
      texture_index,
    )
    return
  }
  if textures_descriptor_set == 0 {
    log.error("textures_descriptor_set is not initialized")
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

get_texture_2d :: proc(
  render: ^Manager,
  handle: gpu.Texture2DHandle,
) -> ^gpu.Image {
  return gpu.get_texture_2d(&render.texture_manager, handle)
}

get_texture_cube :: proc(
  render: ^Manager,
  handle: gpu.TextureCubeHandle,
) -> ^gpu.CubeImage {
  return gpu.get_texture_cube(&render.texture_manager, handle)
}

destroy_cube_texture :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  handle: gpu.TextureCubeHandle,
) {
  gpu.free_texture_cube(&render.texture_manager, gctx, handle)
}

upload_node_transform :: proc(
  render: ^Manager,
  handle: d.NodeHandle,
  world_matrix: ^matrix[4, 4]f32,
) {
  gpu.write(
    &render.world_matrix_buffer.buffer,
    world_matrix,
    int(handle.index),
  )
}

upload_node_data :: proc(
  render: ^Manager,
  handle: NodeHandle,
  node_data: ^NodeData,
) {
  gpu.write(&render.node_data_buffer.buffer, node_data, int(handle.index))
}

upload_bone_matrices :: proc(
  render: ^Manager,
  frame_index: u32,
  offset: u32,
  matrices: []matrix[4, 4]f32,
) {
  frame_buffer := &render.bone_buffer.buffers[frame_index]
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
  gpu.write(&render.sprite_buffer.buffer, sprite_data, int(index))
}

upload_emitter_data :: proc(
  render: ^Manager,
  index: u32,
  emitter: ^Emitter,
) {
  gpu.write(&render.emitter_buffer.buffer, emitter, int(index))
}

upload_forcefield_data :: proc(
  render: ^Manager,
  handle: d.ForceFieldHandle,
  forcefield: ^ForceField,
) {
  gpu.write(
    &render.forcefield_buffer.buffer,
    forcefield,
    int(handle.index),
  )
}

upload_light_data :: proc(
  render: ^Manager,
  index: u32,
  light_data: ^d.Light,
) {
  gpu.write(&render.lights_buffer.buffer, light_data, int(index))
  light.shadow_invalidate_light(&render.shadow, index)
}

upload_mesh_data :: proc(
  render: ^Manager,
  handle: d.MeshHandle,
  mesh: ^Mesh,
) {
  upload_mesh_data_raw(render, handle, mesh)
}

upload_mesh_data_raw :: proc(
  render: ^Manager,
  handle: d.MeshHandle,
  mesh_data: ^Mesh,
) {
  gpu.write(&render.mesh_data_buffer.buffer, mesh_data, int(handle.index))
}

upload_material_data :: proc(
  render: ^Manager,
  index: u32,
  material: ^Material,
) {
  gpu.write(&render.material_buffer.buffer, material, int(index))
}

allocate_bone_matrix_range :: proc(render: ^Manager, bone_count: u32) -> u32 {
  if bone_count == 0 do return 0xFFFFFFFF
  return cont.slab_alloc(&render.bone_matrix_slab, bone_count)
}

free_bone_matrix_range :: proc(render: ^Manager, offset: u32) {
  if offset == 0xFFFFFFFF do return
  cont.slab_free(&render.bone_matrix_slab, offset)
}

ensure_bone_matrix_range_for_node :: proc(
  render: ^Manager,
  handle: d.NodeHandle,
  bone_count: u32,
) -> u32 {
  if existing, ok := render.bone_matrix_offsets[handle]; ok {
    return existing
  }
  offset := allocate_bone_matrix_range(render, bone_count)
  if offset == 0xFFFFFFFF do return 0xFFFFFFFF
  render.bone_matrix_offsets[handle] = offset
  return offset
}

release_bone_matrix_range_for_node :: proc(
  render: ^Manager,
  handle: d.NodeHandle,
) {
  if offset, ok := render.bone_matrix_offsets[handle]; ok {
    free_bone_matrix_range(render, offset)
    delete_key(&render.bone_matrix_offsets, handle)
  }
}

// Upload camera CPU data to GPU per-frame buffer
// Takes single CPU camera data and copies to the specified frame index
upload_camera_data :: proc(
  render: ^Manager,
  cameras: ^d.Pool(cam.Camera),
  camera_index: u32,
  frame_index: u32,
) {
  camera := &cameras.entries[camera_index].item
  camera_data: cam.CameraData
  camera_data.view = cam.camera_view_matrix(camera)
  camera_data.projection = cam.camera_projection_matrix(camera)
  near, far := cam.camera_get_near_far(camera)
  camera_data.viewport_params = [4]f32 {
    f32(camera.extent[0]),
    f32(camera.extent[1]),
    near,
    far,
  }
  camera_data.position = [4]f32 {
    camera.position[0],
    camera.position[1],
    camera.position[2],
    1.0,
  }
  frustum := geometry.make_frustum(camera_data.projection * camera_data.view)
  camera_data.frustum_planes = frustum.planes
  gpu.write(
    &render.camera_buffer.buffers[frame_index],
    &camera_data,
    int(camera_index),
  )
}
