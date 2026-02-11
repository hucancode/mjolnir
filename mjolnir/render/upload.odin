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
import "light"
import vk "vendor:vulkan"

allocate_vertices :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  vertices: []geometry.Vertex,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  vertex_count := u32(len(vertices))
  offset, ok := cont.slab_alloc(&render.vertex_slab, vertex_count)
  if !ok {
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  gpu.write(gctx, &render.vertex_buffer, vertices, int(offset)) or_return
  return BufferAllocation{offset = offset, count = vertex_count}, .SUCCESS
}

allocate_indices :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  indices: []u32,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  index_count := u32(len(indices))
  offset, ok := cont.slab_alloc(&render.index_slab, index_count)
  if !ok {
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  gpu.write(gctx, &render.index_buffer, indices, int(offset)) or_return
  return BufferAllocation{offset = offset, count = index_count}, .SUCCESS
}

allocate_vertex_skinning :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
  skinnings: []geometry.SkinningData,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  if len(skinnings) == 0 {
    return {}, .SUCCESS
  }
  skinning_count := u32(len(skinnings))
  offset, ok := cont.slab_alloc(&render.vertex_skinning_slab, skinning_count)
  if !ok {
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  gpu.write(
    gctx,
    &render.vertex_skinning_buffer,
    skinnings,
    int(offset),
  ) or_return
  return BufferAllocation{offset = offset, count = skinning_count}, .SUCCESS
}

free_vertices :: proc(render: ^Manager, allocation: BufferAllocation) {
  cont.slab_free(&render.vertex_slab, allocation.offset)
}

free_indices :: proc(render: ^Manager, allocation: BufferAllocation) {
  cont.slab_free(&render.index_slab, allocation.offset)
}

free_vertex_skinning :: proc(
  render: ^Manager,
  allocation: BufferAllocation,
) {
  cont.slab_free(&render.vertex_skinning_slab, allocation.offset)
}

allocate_mesh_geometry :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  geometry_data: geometry.Geometry,
  auto_purge: bool = false,
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
  mesh.auto_purge = auto_purge
  mesh.has_skinning = len(geometry_data.skinnings) > 0

  // Allocate geometry buffers in render module
  mesh.vertex_allocation = allocate_vertices(
    render,
    gctx,
    geometry_data.vertices,
  ) or_return
  mesh.index_allocation = allocate_indices(
    render,
    gctx,
    geometry_data.indices,
  ) or_return

  // Handle skinning data if present
  if len(geometry_data.skinnings) > 0 {
    mesh.skinning_allocation = allocate_vertex_skinning(
      render,
      gctx,
      geometry_data.skinnings,
    ) or_return
  }

  // Upload mesh metadata to GPU
  upload_mesh_data(render, handle, mesh)
  return handle, .SUCCESS
}

sync_mesh_geometry_for_handle :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  handle: d.MeshHandle,
  geometry_data: geometry.Geometry,
  auto_purge: bool = false,
) -> vk.Result {
  mesh := ensure_mesh_slot(render, handle)
  if mesh.vertex_allocation.count > 0 {
    free_vertices(render, mesh.vertex_allocation)
  }
  if mesh.index_allocation.count > 0 {
    free_indices(render, mesh.index_allocation)
  }
  if mesh.has_skinning && mesh.skinning_allocation.count > 0 {
    free_vertex_skinning(render, mesh.skinning_allocation)
  }
  mesh.aabb_min = geometry_data.aabb.min
  mesh.aabb_max = geometry_data.aabb.max
  mesh.auto_purge = auto_purge
  mesh.has_skinning = len(geometry_data.skinnings) > 0
  mesh.vertex_allocation = allocate_vertices(render, gctx, geometry_data.vertices) or_return
  mesh.index_allocation = allocate_indices(render, gctx, geometry_data.indices) or_return
  if mesh.has_skinning {
    mesh.skinning_allocation = allocate_vertex_skinning(
      render,
      gctx,
      geometry_data.skinnings,
    ) or_return
  } else {
    mesh.skinning_allocation = {}
  }
  upload_mesh_data(render, handle, mesh)
  return .SUCCESS
}

free_mesh_geometry :: proc(render: ^Manager, handle: d.MeshHandle) {
  mesh, ok := cont.free(&render.meshes, handle)
  if !ok do return
  if mesh.has_skinning && mesh.skinning_allocation.count > 0 {
    free_vertex_skinning(render, mesh.skinning_allocation)
  }
  free_vertices(render, mesh.vertex_allocation)
  free_indices(render, mesh.index_allocation)
}

register_texture_2d :: proc(
  render: ^Manager,
  handle: gpu.Texture2DHandle,
  auto_purge: bool = false,
) {
  render.texture_2d_tracking[handle] = TextureTracking {
    auto_purge = auto_purge,
  }
}

unregister_texture_2d :: proc(render: ^Manager, handle: gpu.Texture2DHandle) {
  delete_key(&render.texture_2d_tracking, handle)
}

register_texture_cube :: proc(
  render: ^Manager,
  handle: gpu.TextureCubeHandle,
  auto_purge: bool = false,
) {
  render.texture_cube_tracking[handle] = TextureTracking {
    auto_purge = auto_purge,
  }
}

unregister_texture_cube :: proc(render: ^Manager, handle: gpu.TextureCubeHandle) {
  delete_key(&render.texture_cube_tracking, handle)
}

enqueue_texture_2d_retire :: proc(render: ^Manager, handle: gpu.Texture2DHandle) {
  if _, exists := render.retired_textures_2d[handle]; exists do return
  if img := gpu.get_texture_2d(&render.texture_manager, handle); img == nil {
    return
  }
  render.retired_textures_2d[handle] = 0
}

enqueue_texture_cube_retire :: proc(
  render: ^Manager,
  handle: gpu.TextureCubeHandle,
) {
  if _, exists := render.retired_textures_cube[handle]; exists do return
  if img := gpu.get_texture_cube(&render.texture_manager, handle); img == nil {
    return
  }
  render.retired_textures_cube[handle] = 0
}

process_retired_gpu_resources :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  retired_count: int,
) {
  stale_2d: [dynamic]gpu.Texture2DHandle
  stale_cube: [dynamic]gpu.TextureCubeHandle
  defer delete(stale_2d)
  defer delete(stale_cube)
  for handle, age in render.retired_textures_2d {
    if age < d.FRAMES_IN_FLIGHT {
      render.retired_textures_2d[handle] = age + 1
    } else {
      append(&stale_2d, handle)
    }
  }
  for handle, age in render.retired_textures_cube {
    if age < d.FRAMES_IN_FLIGHT {
      render.retired_textures_cube[handle] = age + 1
    } else {
      append(&stale_cube, handle)
    }
  }
  for handle in stale_2d {
    gpu.free_texture_2d(&render.texture_manager, gctx, handle)
    delete_key(&render.retired_textures_2d, handle)
    retired_count += 1
  }
  for handle in stale_cube {
    gpu.free_texture_cube(&render.texture_manager, gctx, handle)
    delete_key(&render.retired_textures_cube, handle)
    retired_count += 1
  }
  return
}

set_texture_2d_auto_purge :: proc(
  render: ^Manager,
  handle: gpu.Texture2DHandle,
  auto_purge: bool,
) -> bool {
  meta, ok := &render.texture_2d_tracking[handle]
  if !ok do return false
  meta.auto_purge = auto_purge
  return true
}

set_texture_cube_auto_purge :: proc(
  render: ^Manager,
  handle: gpu.TextureCubeHandle,
  auto_purge: bool,
) -> bool {
  meta, ok := &render.texture_cube_tracking[handle]
  if !ok do return false
  meta.auto_purge = auto_purge
  return true
}

texture_2d_ref :: proc(render: ^Manager, handle: gpu.Texture2DHandle) -> bool {
  meta, ok := &render.texture_2d_tracking[handle]
  if !ok do return false
  meta.ref_count += 1
  return true
}

texture_2d_unref :: proc(
  render: ^Manager,
  handle: gpu.Texture2DHandle,
) -> (
  ref_count: u32,
  ok: bool,
) #optional_ok {
  meta, exists := &render.texture_2d_tracking[handle]
  if !exists do return
  if meta.ref_count == 0 {
    return 0, true
  }
  meta.ref_count -= 1
  return meta.ref_count, true
}

texture_cube_ref :: proc(render: ^Manager, handle: gpu.TextureCubeHandle) -> bool {
  meta, ok := &render.texture_cube_tracking[handle]
  if !ok do return false
  meta.ref_count += 1
  return true
}

texture_cube_unref :: proc(
  render: ^Manager,
  handle: gpu.TextureCubeHandle,
) -> (
  ref_count: u32,
  ok: bool,
) #optional_ok {
  meta, exists := &render.texture_cube_tracking[handle]
  if !exists do return
  if meta.ref_count == 0 {
    return 0, true
  }
  meta.ref_count -= 1
  return meta.ref_count, true
}

texture_2d_should_purge :: proc(
  render: ^Manager,
  handle: gpu.Texture2DHandle,
) -> bool {
  meta, ok := render.texture_2d_tracking[handle]
  if !ok do return false
  return meta.auto_purge && meta.ref_count == 0
}

texture_cube_should_purge :: proc(
  render: ^Manager,
  handle: gpu.TextureCubeHandle,
) -> bool {
  meta, ok := render.texture_cube_tracking[handle]
  if !ok do return false
  return meta.auto_purge && meta.ref_count == 0
}

create_empty_texture_2d :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  width, height: u32,
  format: vk.Format,
  usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT, .SAMPLED},
  auto_purge := false,
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
  register_texture_2d(render, handle, auto_purge)
  return handle, .SUCCESS
}

create_empty_texture_cube :: proc(
  gctx: ^gpu.GPUContext,
  render: ^Manager,
  size: u32,
  format: vk.Format = .D32_SFLOAT,
  usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
  auto_purge := false,
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
  register_texture_cube(render, handle, auto_purge)
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
  register_texture_2d(render, handle, false)
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
  register_texture_2d(render, handle, false)
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
  register_texture_2d(render, handle, false)
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
  _ = gctx
  enqueue_texture_2d_retire(render, handle)
  unregister_texture_2d(render, handle)
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

purge_unused_textures_2d :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  purged_count: int,
) {
  _ = gctx
  for &entry, i in render.texture_manager.images_2d.entries do if entry.active {
    handle := gpu.Texture2DHandle {
      index      = u32(i),
      generation = entry.generation,
    }
    if texture_2d_should_purge(render, handle) {
      enqueue_texture_2d_retire(render, handle)
      unregister_texture_2d(render, handle)
      purged_count += 1
    }
  }
  if purged_count > 0 {
    log.infof("Purged %d unused 2D textures", purged_count)
  }
  return
}

purge_unused_textures_cube :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  purged_count: int,
) {
  _ = gctx
  for &entry, i in render.texture_manager.images_cube.entries do if entry.active {
    handle := gpu.TextureCubeHandle {
      index      = u32(i),
      generation = entry.generation,
    }
    if texture_cube_should_purge(render, handle) {
      enqueue_texture_cube_retire(render, handle)
      unregister_texture_cube(render, handle)
      purged_count += 1
    }
  }
  if purged_count > 0 {
    log.infof("Purged %d unused cube textures", purged_count)
  }
  return
}

purge_unused_gpu_resources :: proc(
  render: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  total_purged: int,
) {
  total_purged += purge_unused_textures_2d(render, gctx)
  total_purged += purge_unused_textures_cube(render, gctx)
  if total_purged > 0 {
    log.infof("Total GPU resources purged: %d", total_purged)
  }
  return
}

active_texture_2d_count :: proc(render: ^Manager) -> int {
  return len(render.texture_2d_tracking)
}

active_texture_cube_count :: proc(render: ^Manager) -> int {
  return len(render.texture_cube_tracking)
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
  _ = gctx
  enqueue_texture_cube_retire(render, handle)
  unregister_texture_cube(render, handle)
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
  handle: d.NodeHandle,
  node_data: ^rd.NodeData,
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
  handle: d.SpriteHandle,
  sprite_data: ^SpriteData,
) {
  gpu.write(&render.sprite_buffer.buffer, sprite_data, int(handle.index))
}

upload_emitter_data :: proc(
  render: ^Manager,
  handle: d.EmitterHandle,
  emitter_data: ^EmitterData,
) {
  gpu.write(&render.emitter_buffer.buffer, emitter_data, int(handle.index))
}

upload_forcefield_data :: proc(
  render: ^Manager,
  handle: d.ForceFieldHandle,
  forcefield_data: ^ForceFieldData,
) {
  gpu.write(
    &render.forcefield_buffer.buffer,
    forcefield_data,
    int(handle.index),
  )
}

upload_light_data :: proc(
  render: ^Manager,
  handle: d.LightHandle,
  light_data: ^light.LightData,
) {
  gpu.write(&render.lights_buffer.buffer, light_data, int(handle.index))
}

update_light_camera :: proc(
  render: ^Manager,
  active_lights: []d.LightHandle,
  main_camera_handle: d.CameraHandle,
  frame_index: u32 = 0,
) {
  _ = frame_index
  for handle in active_lights {
    light := cont.get(render.lights, handle) or_continue
    world_matrix := gpu.get(
      &render.world_matrix_buffer.buffer,
      light.node_index,
    )
    if world_matrix == nil do continue
    light_position := world_matrix[3].xyz
    light_direction := world_matrix[2].xyz
    if light.cast_shadow {
      #partial switch light.type {
      case .POINT:
        spherical_cam := cont.get(render.spherical_cameras, light.camera_handle)
        if spherical_cam != nil {
          spherical_cam.center = light_position
        }
      case .DIRECTIONAL:
        shadow_camera := cont.get(render.cameras, light.camera_handle)
        if shadow_camera == nil do continue
        main_cam := cont.get(render.cameras, main_camera_handle)
        if main_cam == nil {
          shadow_camera.draw_list_source_handle = {}
          shadow_camera.enable_culling = true
          shadow_camera.enable_depth_pyramid = true
          far_dist: f32 = 100.0
          if ortho, ok := shadow_camera.projection.(cam.OrthographicProjection); ok {
            far_dist = ortho.far
          }
          camera_position :=
            light_position - light_direction * (far_dist * 0.5)
          target_position := light_position + light_direction
          camera_look_at := cam.camera_view_matrix // keep module alias active in this scope
          _ = camera_look_at
          // inline look-at behavior to avoid world dependency
          shadow_camera.position = camera_position
          continue
        }
        main_view := cam.camera_view_matrix(main_cam)
        limited_proj_matrix := linalg.MATRIX4F32_IDENTITY
        DIRECTIONAL_LIGHT_SHADOW_MAX_DISTANCE :: 10.0
        switch proj in main_cam.projection {
        case cam.PerspectiveProjection:
          limited_proj_matrix = linalg.matrix4_perspective(
            proj.fov,
            proj.aspect_ratio,
            proj.near,
            min(proj.far, DIRECTIONAL_LIGHT_SHADOW_MAX_DISTANCE),
          )
        case cam.OrthographicProjection:
          limited_proj_matrix = linalg.matrix_ortho3d(
            -proj.width / 2,
            proj.width / 2,
            -proj.height / 2,
            proj.height / 2,
            proj.near,
            min(proj.far, DIRECTIONAL_LIGHT_SHADOW_MAX_DISTANCE),
          )
        }
        frustum_corners := geometry.frustum_corners_world(
          main_view,
          limited_proj_matrix,
        )
        light_forward := linalg.normalize(light_direction)
        light_up := linalg.VECTOR3F32_Y_AXIS
        if math.abs(linalg.dot(light_forward, light_up)) > 0.95 {
          light_up = linalg.VECTOR3F32_Z_AXIS
        }
        light_right := linalg.normalize(linalg.cross(light_up, light_forward))
        light_up_recalc := linalg.cross(light_forward, light_right)
        light_rotation := matrix[3, 3]f32{
          light_right.x, light_right.y, light_right.z,
          light_up_recalc.x, light_up_recalc.y, light_up_recalc.z,
          light_forward.x, light_forward.y, light_forward.z,
        }
        rotated_corners: [8][3]f32
        for corner, i in frustum_corners {
          rotated_corners[i] = light_rotation * corner
        }
        aabb_min := rotated_corners[0]
        aabb_max := rotated_corners[0]
        #unroll for i in 1 ..< 8 {
          aabb_min = linalg.min(aabb_min, rotated_corners[i])
          aabb_max = linalg.max(aabb_max, rotated_corners[i])
        }
        padding_factor: f32 = 0.1
        aabb_size := aabb_max - aabb_min
        aabb_min -= aabb_size * padding_factor
        aabb_max += aabb_size * padding_factor
        aabb_size = aabb_max - aabb_min
        aabb_center_rotated := (aabb_min + aabb_max) * 0.5
        near_plane: f32 = 0.1
        camera_distance := (aabb_size.z * 0.5) + near_plane
        camera_pos_rotated := [3]f32 {
          aabb_center_rotated.x,
          aabb_center_rotated.y,
          aabb_center_rotated.z - camera_distance,
        }
        far_plane := aabb_size.z + near_plane
        light_rotation_inv := linalg.transpose(light_rotation)
        camera_position := light_rotation_inv * camera_pos_rotated
        target_position := camera_position + light_forward
        if ortho_proj, ok := &shadow_camera.projection.(cam.OrthographicProjection); ok {
          ortho_proj.width = aabb_size.x
          ortho_proj.height = aabb_size.y
          ortho_proj.near = near_plane
          ortho_proj.far = far_plane
        }
        shadow_camera.position = camera_position
        shadow_camera.draw_list_source_handle = main_camera_handle
        shadow_camera.enable_culling = false
        shadow_camera.enable_depth_pyramid = false
      case .SPOT:
        shadow_camera := cont.get(render.cameras, light.camera_handle)
        if shadow_camera != nil {
          shadow_camera.draw_list_source_handle = {}
          shadow_camera.enable_culling = true
          shadow_camera.enable_depth_pyramid = true
          target_position := light_position + light_direction
          _ = target_position
          shadow_camera.position = light_position
        }
      }
    }
  }
}

upload_mesh_data :: proc(
  render: ^Manager,
  handle: d.MeshHandle,
  mesh: ^Mesh,
) {
  prepare_mesh_data(mesh)
  upload_mesh_data_raw(render, handle, &mesh.data)
}

upload_mesh_data_raw :: proc(
  render: ^Manager,
  handle: d.MeshHandle,
  mesh_data: ^MeshData,
) {
  gpu.write(&render.mesh_data_buffer.buffer, mesh_data, int(handle.index))
}

upload_material_data :: proc(
  render: ^Manager,
  handle: d.MaterialHandle,
  material: ^Material,
) {
  if handle.index >= d.MAX_MATERIALS do return
  prepare_material_data(material)
  upload_material_data_raw(render, handle, &material.data)
}

upload_material_data_raw :: proc(
  render: ^Manager,
  handle: d.MaterialHandle,
  material_data: ^MaterialData,
) {
  if handle.index >= d.MAX_MATERIALS do return
  gpu.write(&render.material_buffer.buffer, material_data, int(handle.index))
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

upload_spherical_camera_data :: proc(
  render: ^Manager,
  camera: ^cam.SphericalCamera,
  camera_index: u32,
  frame_index: u32 = 0,
) {
  dst := gpu.get(
    &render.spherical_camera_buffer.buffers[frame_index],
    camera_index,
  )
  if dst == nil do return
  fov := f32(math.PI * 0.5)
  aspect := f32(1.0)
  dst.projection = linalg.matrix4_perspective(
    fov,
    aspect,
    camera.near,
    camera.far,
    flip_z_axis = false,
  )
  dst.position = [4]f32 {
    camera.center[0],
    camera.center[1],
    camera.center[2],
    camera.radius,
  }
  dst.near_far = [2]f32{camera.near, camera.far}
}
