package render

import alg "../algebra"
import cont "../containers"
import d "data"
import geo "../geometry"
import "../gpu"
import "ui"
import "camera"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import cam "camera"
import "debug_draw"
import "debug_ui"
import "geometry"
import "light"
import "lighting"
import "particles"
import "post_process"
import "transparency"
import vk "vendor:vulkan"
import "visibility"
import rd "data"

FRAMES_IN_FLIGHT :: d.FRAMES_IN_FLIGHT

TextureTracking :: struct {
  ref_count:  u32,
  auto_purge: bool,
}

Manager :: struct {
  geometry:                geometry.Renderer,
  lighting:                lighting.Renderer,
  transparency:            transparency.Renderer,
  particles:               particles.Renderer,
  debug_draw:              debug_draw.Renderer,
  debug_draw_ik:           bool,
  post_process:            post_process.Renderer,
  debug_ui:                debug_ui.Renderer,
  ui_system:               ui.System,
  ui:                      ui.Renderer,
  main_camera:             d.CameraHandle,
  cameras:                 d.Pool(camera.Camera),
  spherical_cameras:       d.Pool(camera.SphericalCamera),
  lights:                  d.Pool(light.Light),
  materials:               d.Pool(Material),
  meshes:                  d.Pool(Mesh),
  emitters:                d.Pool(Emitter),
  forcefields:             d.Pool(ForceField),
  sprites:                 d.Pool(Sprite),
  visibility:              visibility.System,
  textures_set_layout:     vk.DescriptorSetLayout,
  textures_descriptor_set: vk.DescriptorSet,
  general_pipeline_layout: vk.PipelineLayout,
  sprite_pipeline_layout:  vk.PipelineLayout,
  sphere_pipeline_layout:  vk.PipelineLayout,
  linear_repeat_sampler:   vk.Sampler,
  linear_clamp_sampler:    vk.Sampler,
  nearest_repeat_sampler:  vk.Sampler,
  nearest_clamp_sampler:   vk.Sampler,
  bone_buffer:             gpu.PerFrameBindlessBuffer(
    matrix[4, 4]f32,
    FRAMES_IN_FLIGHT,
  ),
  camera_buffer:           gpu.PerFrameBindlessBuffer(
    cam.CameraData,
    FRAMES_IN_FLIGHT,
  ),
  spherical_camera_buffer: gpu.PerFrameBindlessBuffer(
    cam.SphericalCameraData,
    FRAMES_IN_FLIGHT,
  ),
  material_buffer:         gpu.BindlessBuffer(MaterialData),
  world_matrix_buffer:     gpu.BindlessBuffer(matrix[4, 4]f32),
  node_data_buffer:        gpu.BindlessBuffer(rd.NodeData),
  mesh_data_buffer:        gpu.BindlessBuffer(MeshData),
  emitter_buffer:          gpu.BindlessBuffer(EmitterData),
  forcefield_buffer:       gpu.BindlessBuffer(ForceFieldData),
  sprite_buffer:           gpu.BindlessBuffer(SpriteData),
  lights_buffer:           gpu.BindlessBuffer(light.LightData),
  vertex_skinning_buffer:  gpu.ImmutableBindlessBuffer(geo.SkinningData),
  vertex_buffer:           gpu.ImmutableBuffer(geo.Vertex),
  index_buffer:            gpu.ImmutableBuffer(u32),
  bone_matrix_slab:        cont.SlabAllocator,
  bone_matrix_offsets:     map[d.NodeHandle]u32,
  vertex_skinning_slab:    cont.SlabAllocator,
  vertex_slab:             cont.SlabAllocator,
  index_slab:              cont.SlabAllocator,
  texture_manager:         gpu.TextureManager,
  texture_2d_tracking:     map[gpu.Texture2DHandle]TextureTracking,
  texture_cube_tracking:   map[gpu.TextureCubeHandle]TextureTracking,
  retired_textures_2d:     map[gpu.Texture2DHandle]u32,
  retired_textures_cube:   map[gpu.TextureCubeHandle]u32,
  // Camera GPU resources (indexed by camera handle.index)
  cameras_gpu:             [d.MAX_CAMERAS]camera.CameraGPU,
  spherical_cameras_gpu:   [d.MAX_CAMERAS]camera.SphericalCameraGPU,
}

@(private)
init_scene_buffers :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  gpu.bindless_buffer_init(
    &self.material_buffer,
    gctx,
    d.MAX_MATERIALS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.material_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.world_matrix_buffer,
    gctx,
    d.MAX_NODES_IN_SCENE,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.world_matrix_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.node_data_buffer,
    gctx,
    d.MAX_NODES_IN_SCENE,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.node_data_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.mesh_data_buffer,
    gctx,
    d.MAX_MESHES,
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.mesh_data_buffer, gctx.device)
  }
  gpu.bindless_buffer_init(
    &self.emitter_buffer,
    gctx,
    d.MAX_EMITTERS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.emitter_buffer, gctx.device)
  }
  emitters := gpu.get_all(&self.emitter_buffer.buffer)
  for &emitter in emitters do emitter = {}
  gpu.bindless_buffer_init(
    &self.forcefield_buffer,
    gctx,
    d.MAX_FORCE_FIELDS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.forcefield_buffer, gctx.device)
  }
  forcefields := gpu.get_all(&self.forcefield_buffer.buffer)
  for &forcefield in forcefields do forcefield = {}
  gpu.bindless_buffer_init(
    &self.sprite_buffer,
    gctx,
    d.MAX_SPRITES,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.sprite_buffer, gctx.device)
  }
  sprites := gpu.get_all(&self.sprite_buffer.buffer)
  for &sprite in sprites do sprite = {}
  gpu.bindless_buffer_init(
    &self.lights_buffer,
    gctx,
    d.MAX_LIGHTS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&self.lights_buffer, gctx.device)
  }
  return .SUCCESS
}

@(private)
shutdown_scene_buffers :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.bindless_buffer_destroy(&self.material_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.world_matrix_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.node_data_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.mesh_data_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.emitter_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.forcefield_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.sprite_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.lights_buffer, gctx.device)
}

@(private)
init_geometry_buffers :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  // Initialize vertex skinning buffer
  skinning_count := d.BINDLESS_SKINNING_BUFFER_SIZE / size_of(geo.SkinningData)
  log.infof(
    "Creating vertex skinning buffer with capacity %d entries...",
    skinning_count,
  )
  gpu.immutable_bindless_buffer_init(
    &self.vertex_skinning_buffer,
    gctx,
    skinning_count,
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.immutable_bindless_buffer_destroy(
      &self.vertex_skinning_buffer,
      gctx.device,
    )
  }
  cont.slab_init(&self.vertex_skinning_slab, d.VERTEX_SLAB_CONFIG)
  defer if ret != .SUCCESS {
    cont.slab_destroy(&self.vertex_skinning_slab)
  }

  // Initialize vertex and index buffers
  vertex_count := d.BINDLESS_VERTEX_BUFFER_SIZE / size_of(geo.Vertex)
  index_count := d.BINDLESS_INDEX_BUFFER_SIZE / size_of(u32)
  self.vertex_buffer = gpu.malloc_buffer(
    gctx,
    geo.Vertex,
    vertex_count,
    {.VERTEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.buffer_destroy(gctx.device, &self.vertex_buffer)
  }
  self.index_buffer = gpu.malloc_buffer(
    gctx,
    u32,
    index_count,
    {.INDEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.buffer_destroy(gctx.device, &self.index_buffer)
  }
  cont.slab_init(&self.vertex_slab, d.VERTEX_SLAB_CONFIG)
  defer if ret != .SUCCESS {
    cont.slab_destroy(&self.vertex_slab)
  }
  cont.slab_init(&self.index_slab, d.INDEX_SLAB_CONFIG)
  defer if ret != .SUCCESS {
    cont.slab_destroy(&self.index_slab)
  }

  log.info("Vertex buffer capacity:", vertex_count, "vertices")
  log.info("Index buffer capacity:", index_count, "indices")
  return .SUCCESS
}

@(private)
destroy_geometry_buffers :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  cont.slab_destroy(&self.vertex_skinning_slab)
  gpu.immutable_bindless_buffer_destroy(
    &self.vertex_skinning_buffer,
    gctx.device,
  )
  gpu.buffer_destroy(gctx.device, &self.vertex_buffer)
  gpu.buffer_destroy(gctx.device, &self.index_buffer)
  cont.slab_destroy(&self.vertex_slab)
  cont.slab_destroy(&self.index_slab)
}

@(private)
sync_existing_resource_data :: proc(
  self: ^Manager,
) {
  for &entry, i in self.materials.entries do if entry.active {
    handle := d.MaterialHandle {
      index      = u32(i),
      generation = entry.generation,
    }
    upload_material_data(self, handle, &entry.item)
  }
  for &entry, i in self.meshes.entries do if entry.active {
    handle := d.MeshHandle {
      index      = u32(i),
      generation = entry.generation,
    }
    upload_mesh_data(self, handle, &entry.item)
  }
}


@(private)
init_bone_buffer :: proc(self: ^Manager, gctx: ^gpu.GPUContext) -> vk.Result {
  cont.slab_init(
    &self.bone_matrix_slab,
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
    &self.bone_buffer,
    gctx,
    int(self.bone_matrix_slab.capacity),
    {.VERTEX},
  ) or_return
  self.bone_matrix_offsets = make(map[d.NodeHandle]u32)
  return .SUCCESS
}

@(private)
shutdown_bone_buffer :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  delete(self.bone_matrix_offsets)
  gpu.per_frame_bindless_buffer_destroy(&self.bone_buffer, gctx.device)
  cont.slab_destroy(&self.bone_matrix_slab)
}

@(private)
init_camera_buffers :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  gpu.per_frame_bindless_buffer_init(
    &self.camera_buffer,
    gctx,
    d.MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  gpu.per_frame_bindless_buffer_init(
    &self.spherical_camera_buffer,
    gctx,
    d.MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE, .GEOMETRY},
  ) or_return
  return .SUCCESS
}

@(private)
shutdown_camera_buffers :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.per_frame_bindless_buffer_destroy(&self.camera_buffer, gctx.device)
  gpu.per_frame_bindless_buffer_destroy(
    &self.spherical_camera_buffer,
    gctx.device,
  )
}

@(private)
shutdown_camera_resources :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  for i in 0 ..< d.MAX_CAMERAS {
    camera.destroy_gpu(gctx, &self.cameras_gpu[i], &self.texture_manager)
    camera.destroy_spherical_gpu(
      gctx,
      &self.spherical_cameras_gpu[i],
      &self.texture_manager,
    )
  }
}

@(private)
init_bindless_layouts :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  info := vk.SamplerCreateInfo {
    sType        = .SAMPLER_CREATE_INFO,
    magFilter    = .LINEAR,
    minFilter    = .LINEAR,
    addressModeU = .REPEAT,
    addressModeV = .REPEAT,
    addressModeW = .REPEAT,
    mipmapMode   = .LINEAR,
    maxLod       = 1000,
  }
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.linear_repeat_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.linear_repeat_sampler, nil)
    self.linear_repeat_sampler = 0
  }
  info.addressModeU, info.addressModeV, info.addressModeW =
    .CLAMP_TO_EDGE, .CLAMP_TO_EDGE, .CLAMP_TO_EDGE
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.linear_clamp_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.linear_clamp_sampler, nil)
    self.linear_clamp_sampler = 0
  }
  info.magFilter, info.minFilter = .NEAREST, .NEAREST
  info.addressModeU, info.addressModeV, info.addressModeW =
    .REPEAT, .REPEAT, .REPEAT
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.nearest_repeat_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.nearest_repeat_sampler, nil)
    self.nearest_repeat_sampler = 0
  }
  info.addressModeU, info.addressModeV, info.addressModeW =
    .CLAMP_TO_EDGE, .CLAMP_TO_EDGE, .CLAMP_TO_EDGE
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.nearest_clamp_sampler,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroySampler(gctx.device, self.nearest_clamp_sampler, nil)
    self.nearest_clamp_sampler = 0
  }
  self.textures_set_layout = gpu.create_descriptor_set_layout_array(
    gctx,
    {.SAMPLED_IMAGE, d.MAX_TEXTURES, {.FRAGMENT}},
    {.SAMPLER, gpu.MAX_SAMPLERS, {.FRAGMENT}},
    {.SAMPLED_IMAGE, d.MAX_CUBE_TEXTURES, {.FRAGMENT}},
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(gctx.device, self.textures_set_layout, nil)
    self.textures_set_layout = 0
  }
  self.general_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(u32),
    },
    self.camera_buffer.set_layout,
    self.textures_set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.world_matrix_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.vertex_skinning_buffer.set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.general_pipeline_layout, nil)
    self.general_pipeline_layout = 0
  }
  self.sprite_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(u32),
    },
    self.camera_buffer.set_layout,
    self.textures_set_layout,
    self.world_matrix_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.sprite_buffer.set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.sprite_pipeline_layout, nil)
    self.sprite_pipeline_layout = 0
  }
  self.sphere_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .GEOMETRY, .FRAGMENT},
      size = size_of(u32),
    },
    self.spherical_camera_buffer.set_layout,
    self.textures_set_layout,
    self.bone_buffer.set_layout,
    self.material_buffer.set_layout,
    self.world_matrix_buffer.set_layout,
    self.node_data_buffer.set_layout,
    self.mesh_data_buffer.set_layout,
    self.vertex_skinning_buffer.set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.sphere_pipeline_layout, nil)
    self.sphere_pipeline_layout = 0
  }
  gpu.allocate_descriptor_set(
    gctx,
    &self.textures_descriptor_set,
    &self.textures_set_layout,
  ) or_return
  gpu.update_descriptor_set_array(
    gctx,
    self.textures_descriptor_set,
    1,
    {.SAMPLER, vk.DescriptorImageInfo{sampler = self.nearest_clamp_sampler}},
    {.SAMPLER, vk.DescriptorImageInfo{sampler = self.linear_clamp_sampler}},
    {.SAMPLER, vk.DescriptorImageInfo{sampler = self.nearest_repeat_sampler}},
    {.SAMPLER, vk.DescriptorImageInfo{sampler = self.linear_repeat_sampler}},
  )
  // Initialize texture manager
  gpu.texture_manager_init(
    &self.texture_manager,
    self.textures_descriptor_set,
  ) or_return
  return .SUCCESS
}

@(private)
shutdown_bindless_layouts :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.texture_manager_shutdown(&self.texture_manager, gctx)
  vk.DestroyPipelineLayout(gctx.device, self.general_pipeline_layout, nil)
  vk.DestroyPipelineLayout(gctx.device, self.sprite_pipeline_layout, nil)
  vk.DestroyPipelineLayout(gctx.device, self.sphere_pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(gctx.device, self.textures_set_layout, nil)
  vk.DestroySampler(gctx.device, self.linear_repeat_sampler, nil)
  vk.DestroySampler(gctx.device, self.linear_clamp_sampler, nil)
  vk.DestroySampler(gctx.device, self.nearest_repeat_sampler, nil)
  vk.DestroySampler(gctx.device, self.nearest_clamp_sampler, nil)
  self.general_pipeline_layout = 0
  self.sprite_pipeline_layout = 0
  self.sphere_pipeline_layout = 0
  self.textures_set_layout = 0
  self.textures_descriptor_set = 0
  self.linear_repeat_sampler = 0
  self.linear_clamp_sampler = 0
  self.nearest_repeat_sampler = 0
  self.nearest_clamp_sampler = 0
}

@(private)
ensure_camera_slot :: proc(
  self: ^Manager,
  handle: d.CameraHandle,
) -> ^camera.Camera {
  for u32(len(self.cameras.entries)) <= handle.index {
    append(&self.cameras.entries, cont.Entry(camera.Camera) {})
  }
  entry := &self.cameras.entries[handle.index]
  entry.generation = handle.generation
  entry.active = true
  if i, ok := slice.linear_search(self.cameras.free_indices[:], handle.index); ok {
    unordered_remove(&self.cameras.free_indices, i)
  }
  return &entry.item
}

@(private)
ensure_spherical_camera_slot :: proc(
  self: ^Manager,
  handle: d.SphereCameraHandle,
) -> ^camera.SphericalCamera {
  for u32(len(self.spherical_cameras.entries)) <= handle.index {
    append(
      &self.spherical_cameras.entries,
      cont.Entry(camera.SphericalCamera) {},
    )
  }
  entry := &self.spherical_cameras.entries[handle.index]
  entry.generation = handle.generation
  entry.active = true
  if i, ok := slice.linear_search(
    self.spherical_cameras.free_indices[:],
    handle.index,
  ); ok {
    unordered_remove(&self.spherical_cameras.free_indices, i)
  }
  return &entry.item
}

@(private)
ensure_light_slot :: proc(
  self: ^Manager,
  handle: d.LightHandle,
) -> ^light.Light {
  for u32(len(self.lights.entries)) <= handle.index {
    append(&self.lights.entries, cont.Entry(light.Light) {})
  }
  entry := &self.lights.entries[handle.index]
  entry.generation = handle.generation
  entry.active = true
  if i, ok := slice.linear_search(self.lights.free_indices[:], handle.index); ok {
    unordered_remove(&self.lights.free_indices, i)
  }
  return &entry.item
}

@(private)
ensure_material_slot :: proc(
  self: ^Manager,
  handle: d.MaterialHandle,
) -> ^Material {
  for u32(len(self.materials.entries)) <= handle.index {
    append(&self.materials.entries, cont.Entry(Material) {})
  }
  entry := &self.materials.entries[handle.index]
  entry.generation = handle.generation
  entry.active = true
  if i, ok := slice.linear_search(
    self.materials.free_indices[:],
    handle.index,
  ); ok {
    unordered_remove(&self.materials.free_indices, i)
  }
  return &entry.item
}

@(private)
ensure_mesh_slot :: proc(self: ^Manager, handle: d.MeshHandle) -> ^Mesh {
  for u32(len(self.meshes.entries)) <= handle.index {
    append(&self.meshes.entries, cont.Entry(Mesh) {})
  }
  entry := &self.meshes.entries[handle.index]
  entry.generation = handle.generation
  entry.active = true
  if i, ok := slice.linear_search(self.meshes.free_indices[:], handle.index); ok {
    unordered_remove(&self.meshes.free_indices, i)
  }
  return &entry.item
}

@(private)
ensure_sprite_slot :: proc(self: ^Manager, handle: d.SpriteHandle) -> ^Sprite {
  for u32(len(self.sprites.entries)) <= handle.index {
    append(&self.sprites.entries, cont.Entry(Sprite) {})
  }
  entry := &self.sprites.entries[handle.index]
  entry.generation = handle.generation
  entry.active = true
  if i, ok := slice.linear_search(self.sprites.free_indices[:], handle.index); ok {
    unordered_remove(&self.sprites.free_indices, i)
  }
  return &entry.item
}

@(private)
ensure_emitter_slot :: proc(
  self: ^Manager,
  handle: d.EmitterHandle,
) -> ^Emitter {
  for u32(len(self.emitters.entries)) <= handle.index {
    append(&self.emitters.entries, cont.Entry(Emitter) {})
  }
  entry := &self.emitters.entries[handle.index]
  entry.generation = handle.generation
  entry.active = true
  if i, ok := slice.linear_search(
    self.emitters.free_indices[:],
    handle.index,
  ); ok {
    unordered_remove(&self.emitters.free_indices, i)
  }
  return &entry.item
}

@(private)
ensure_forcefield_slot :: proc(
  self: ^Manager,
  handle: d.ForceFieldHandle,
) -> ^ForceField {
  for u32(len(self.forcefields.entries)) <= handle.index {
    append(&self.forcefields.entries, cont.Entry(ForceField) {})
  }
  entry := &self.forcefields.entries[handle.index]
  entry.generation = handle.generation
  entry.active = true
  if i, ok := slice.linear_search(
    self.forcefields.free_indices[:],
    handle.index,
  ); ok {
    unordered_remove(&self.forcefields.free_indices, i)
  }
  return &entry.item
}

sync_camera_from_world :: proc(
  self: ^Manager,
  handle: d.CameraHandle,
  world_camera: ^camera.Camera,
) {
  dst := ensure_camera_slot(self, handle)
  dst.position = world_camera.position
  dst.rotation = world_camera.rotation
  dst.projection = world_camera.projection
  dst.extent = world_camera.extent
  dst.enabled_passes = world_camera.enabled_passes
  dst.enable_culling = world_camera.enable_culling
  dst.enable_depth_pyramid = world_camera.enable_depth_pyramid
  dst.draw_list_source_handle = world_camera.draw_list_source_handle
}

sync_spherical_camera_from_world :: proc(
  self: ^Manager,
  handle: d.SphereCameraHandle,
  world_camera: ^camera.SphericalCamera,
) {
  dst := ensure_spherical_camera_slot(self, handle)
  dst^ = world_camera^
}

sync_light_from_world :: proc(
  self: ^Manager,
  handle: d.LightHandle,
  world_light: ^light.Light,
) {
  dst := ensure_light_slot(self, handle)
  dst^ = world_light^
  upload_light_data(self, handle, &dst.data)
}

sync_material_from_world :: proc(
  self: ^Manager,
  handle: d.MaterialHandle,
  world_material: ^Material,
) {
  dst := ensure_material_slot(self, handle)
  dst^ = world_material^
  upload_material_data(self, handle, dst)
}

sync_mesh_from_world :: proc(
  self: ^Manager,
  handle: d.MeshHandle,
  world_mesh: ^Mesh,
) {
  dst := ensure_mesh_slot(self, handle)
  dst^ = world_mesh^
  upload_mesh_data(self, handle, dst)
}

sync_sprite_from_world :: proc(
  self: ^Manager,
  handle: d.SpriteHandle,
  world_sprite: ^Sprite,
) {
  dst := ensure_sprite_slot(self, handle)
  dst^ = world_sprite^
  upload_sprite_data(self, handle, &dst.data)
}

sync_emitter_from_world :: proc(
  self: ^Manager,
  handle: d.EmitterHandle,
  world_emitter: ^Emitter,
) {
  dst := ensure_emitter_slot(self, handle)
  dst^ = world_emitter^
  upload_emitter_data(self, handle, &dst.data)
}

sync_forcefield_from_world :: proc(
  self: ^Manager,
  handle: d.ForceFieldHandle,
  world_forcefield: ^ForceField,
) {
  dst := ensure_forcefield_slot(self, handle)
  dst^ = world_forcefield^
  upload_forcefield_data(self, handle, &dst.data)
}

clear_mesh :: proc(self: ^Manager, handle: d.MeshHandle) {
  if u32(len(self.meshes.entries)) <= handle.index do return
  entry := &self.meshes.entries[handle.index]
  if !entry.active || entry.generation != handle.generation do return
  free_mesh_geometry(self, handle)
  zero_mesh_data: MeshData
  upload_mesh_data_raw(self, handle, &zero_mesh_data)
}

clear_material :: proc(self: ^Manager, handle: d.MaterialHandle) {
  if u32(len(self.materials.entries)) <= handle.index do return
  entry := &self.materials.entries[handle.index]
  if !entry.active || entry.generation != handle.generation do return
  entry.active = false
  append(&self.materials.free_indices, handle.index)
  zero_material_data: MaterialData
  upload_material_data_raw(self, handle, &zero_material_data)
}

clear_sprite :: proc(self: ^Manager, handle: d.SpriteHandle) {
  if u32(len(self.sprites.entries)) <= handle.index do return
  entry := &self.sprites.entries[handle.index]
  if !entry.active || entry.generation != handle.generation do return
  entry.active = false
  append(&self.sprites.free_indices, handle.index)
  zero_sprite_data: SpriteData
  upload_sprite_data(self, handle, &zero_sprite_data)
}

clear_emitter :: proc(self: ^Manager, handle: d.EmitterHandle) {
  if u32(len(self.emitters.entries)) <= handle.index do return
  entry := &self.emitters.entries[handle.index]
  if !entry.active || entry.generation != handle.generation do return
  entry.active = false
  append(&self.emitters.free_indices, handle.index)
  zero_emitter_data: EmitterData
  upload_emitter_data(self, handle, &zero_emitter_data)
}

clear_forcefield :: proc(self: ^Manager, handle: d.ForceFieldHandle) {
  if u32(len(self.forcefields.entries)) <= handle.index do return
  entry := &self.forcefields.entries[handle.index]
  if !entry.active || entry.generation != handle.generation do return
  entry.active = false
  append(&self.forcefields.free_indices, handle.index)
  zero_forcefield_data: ForceFieldData
  upload_forcefield_data(self, handle, &zero_forcefield_data)
}

record_compute_commands :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  compute_buffer: vk.CommandBuffer,
) -> vk.Result {
  // Compute for frame N prepares data for frame N+1
  // Buffer indices with d.FRAMES_IN_FLIGHT=2: frame N uses buffer [N], produces data for buffer [N+1]
  next_frame_index := alg.next(frame_index, d.FRAMES_IN_FLIGHT)
  for &entry, cam_index in self.cameras.entries do if entry.active {
    cam_cpu := &entry.item
    cam_gpu := &self.cameras_gpu[cam_index]
    upload_camera_data(self, &self.cameras, u32(cam_index), frame_index)
    // Only build pyramid if enabled for this camera
    if cam_cpu.enable_depth_pyramid {
      visibility.build_pyramid(&self.visibility, gctx, compute_buffer, cam_gpu, u32(cam_index), frame_index) // Build pyramid[N]
    }
    // Only perform culling if enabled for this camera
    if cam_cpu.enable_culling {
      visibility.perform_culling(&self.visibility, gctx, compute_buffer, cam_gpu, u32(cam_index), next_frame_index, {.VISIBLE}, {}) // Write draw_list[N+1]
    }
  }
  for &entry, cam_index in self.spherical_cameras.entries do if entry.active {
    cam_cpu := &entry.item
    cam_gpu := &self.spherical_cameras_gpu[cam_index]
    upload_spherical_camera_data(self, cam_cpu, u32(cam_index), frame_index)
    visibility.perform_sphere_culling(&self.visibility, gctx, compute_buffer, cam_gpu, u32(cam_index), next_frame_index, {.VISIBLE}, {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME}) // Write draw_list[N+1]
  }
  particles.simulate(
    &self.particles,
    compute_buffer,
    self.world_matrix_buffer.descriptor_set,
  )
  return .SUCCESS
}

init :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  swapchain_extent: vk.Extent2D,
  swapchain_format: vk.Format,
  dpi_scale: f32,
) -> (
  ret: vk.Result,
) {
  cont.init(&self.cameras, d.MAX_CAMERAS)
  cont.init(&self.spherical_cameras, d.MAX_CAMERAS)
  cont.init(&self.lights, d.MAX_LIGHTS)
  cont.init(&self.materials, d.MAX_MATERIALS)
  cont.init(&self.meshes, d.MAX_MESHES)
  cont.init(&self.emitters, d.MAX_EMITTERS)
  cont.init(&self.forcefields, d.MAX_FORCE_FIELDS)
  cont.init(&self.sprites, d.MAX_SPRITES)
  // Initialize texture tracking maps
  self.texture_2d_tracking = make(map[gpu.Texture2DHandle]TextureTracking)
  self.texture_cube_tracking = make(map[gpu.TextureCubeHandle]TextureTracking)
  self.retired_textures_2d = make(map[gpu.Texture2DHandle]u32)
  self.retired_textures_cube = make(map[gpu.TextureCubeHandle]u32)
  init_geometry_buffers(self, gctx) or_return
  defer if ret != .SUCCESS {
    destroy_geometry_buffers(self, gctx)
  }
  init_bone_buffer(self, gctx) or_return
  defer if ret != .SUCCESS {
    shutdown_bone_buffer(self, gctx)
  }
  init_camera_buffers(self, gctx) or_return
  defer if ret != .SUCCESS {
    shutdown_camera_buffers(self, gctx)
  }
  init_scene_buffers(self, gctx) or_return
  defer if ret != .SUCCESS {
    shutdown_scene_buffers(self, gctx)
  }
  sync_existing_resource_data(self)
  init_bindless_layouts(self, gctx) or_return
  defer if ret != .SUCCESS {
    shutdown_bindless_layouts(self, gctx)
  }
  camera_handle, camera_cpu, ok := cont.alloc(&self.cameras, d.CameraHandle)
  if !ok {
    return .ERROR_INITIALIZATION_FAILED
  }
  defer if ret != .SUCCESS {
    cont.free(&self.cameras, camera_handle)
  }
  camera_cpu.position = {3, 4, 3}
  camera_cpu.rotation = linalg.QUATERNIONF32_IDENTITY
  camera_cpu.projection = camera.PerspectiveProjection {
    fov          = math.PI * 0.5,
    aspect_ratio = f32(swapchain_extent.width) / f32(swapchain_extent.height),
    near         = 0.1,
    far          = 100.0,
  }
  camera_cpu.extent = {swapchain_extent.width, swapchain_extent.height}
  camera_cpu.enabled_passes = {
    .SHADOW,
    .GEOMETRY,
    .LIGHTING,
    .TRANSPARENCY,
    .PARTICLES,
    .DEBUG_DRAW,
    .POST_PROCESS,
  }
  camera_cpu.enable_culling = true
  camera_cpu.enable_depth_pyramid = true
  camera_cpu.draw_list_source_handle = {}
  // Initialize GPU resources for the camera
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  camera.init_gpu(
    gctx,
    camera_gpu,
    &self.texture_manager,
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
    vk.Format.D32_SFLOAT,
    camera_cpu.enabled_passes,
    camera_cpu.enable_depth_pyramid,
    d.MAX_NODES_IN_SCENE,
  ) or_return
  self.main_camera = camera_handle
  visibility.init(
    &self.visibility,
    gctx,
    swapchain_extent.width,
    swapchain_extent.height,
    self.general_pipeline_layout,
    self.sphere_pipeline_layout,
  ) or_return
  camera.allocate_descriptors(
    gctx,
    camera_gpu,
    &self.texture_manager,
    &self.visibility.normal_cam_descriptor_layout,
    &self.visibility.depth_reduce_descriptor_layout,
    &self.node_data_buffer,
    &self.mesh_data_buffer,
    &self.world_matrix_buffer,
    &self.camera_buffer,
  ) or_return
  lighting.init(
    &self.lighting,
    gctx,
    &self.texture_manager,
    self.camera_buffer.set_layout,
    self.lights_buffer.set_layout,
    self.world_matrix_buffer.set_layout,
    self.spherical_camera_buffer.set_layout,
    self.textures_set_layout,
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
    vk.Format.D32_SFLOAT,
  ) or_return
  geometry.init(
    &self.geometry,
    gctx,
    swapchain_extent.width,
    swapchain_extent.height,
    self.general_pipeline_layout,
  ) or_return
  particles.init(
    &self.particles,
    gctx,
    &self.texture_manager,
    self.camera_buffer.set_layout,
    self.emitter_buffer.set_layout,
    self.forcefield_buffer.set_layout,
    self.world_matrix_buffer.set_layout,
    self.emitter_buffer.descriptor_set,
    self.forcefield_buffer.descriptor_set,
    self.textures_set_layout,
  ) or_return
  transparency.init(
    &self.transparency,
    gctx,
    swapchain_extent.width,
    swapchain_extent.height,
    self.general_pipeline_layout,
    self.sprite_pipeline_layout,
  ) or_return
  post_process.init(
    &self.post_process,
    gctx,
    &self.texture_manager,
    swapchain_format,
    swapchain_extent.width,
    swapchain_extent.height,
    self.textures_set_layout,
  ) or_return
  debug_ui.init(
    &self.debug_ui,
    gctx,
    &self.texture_manager,
    swapchain_format,
    swapchain_extent.width,
    swapchain_extent.height,
    dpi_scale,
    self.textures_set_layout,
  ) or_return
  debug_draw.init(
    &self.debug_draw,
    gctx,
    self.camera_buffer.set_layout,
  ) or_return
  ui.init_ui_system(&self.ui_system)
  ui.init_renderer(
    &self.ui,
    &self.ui_system,
    gctx,
    &self.texture_manager,
    self.textures_set_layout,
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
  ) or_return
  return .SUCCESS
}

shutdown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  ui.shutdown(&self.ui, gctx, &self.texture_manager)
  ui.shutdown_ui_system(&self.ui_system)
  debug_ui.shutdown(&self.debug_ui, gctx)
  debug_draw.shutdown(&self.debug_draw, gctx)
  post_process.shutdown(&self.post_process, gctx, &self.texture_manager)
  particles.shutdown(&self.particles, gctx)
  transparency.shutdown(&self.transparency, gctx)
  lighting.shutdown(&self.lighting, gctx, &self.texture_manager)
  geometry.shutdown(&self.geometry, gctx)
  visibility.shutdown(&self.visibility, gctx)
  shutdown_camera_resources(self, gctx)
  shutdown_bindless_layouts(self, gctx)
  shutdown_scene_buffers(self, gctx)
  shutdown_camera_buffers(self, gctx)
  shutdown_bone_buffer(self, gctx)
  destroy_geometry_buffers(self, gctx)
  // Cleanup texture tracking maps
  delete(self.texture_2d_tracking)
  delete(self.texture_cube_tracking)
  delete(self.retired_textures_2d)
  delete(self.retired_textures_cube)
  delete(self.cameras.entries)
  delete(self.cameras.free_indices)
  delete(self.spherical_cameras.entries)
  delete(self.spherical_cameras.free_indices)
  delete(self.lights.entries)
  delete(self.lights.free_indices)
  delete(self.materials.entries)
  delete(self.materials.free_indices)
  delete(self.meshes.entries)
  delete(self.meshes.free_indices)
  delete(self.emitters.entries)
  delete(self.emitters.free_indices)
  delete(self.forcefields.entries)
  delete(self.forcefields.free_indices)
  delete(self.sprites.entries)
  delete(self.sprites.free_indices)
}

resize :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  extent: vk.Extent2D,
  color_format: vk.Format,
  dpi_scale: f32,
) -> vk.Result {
  lighting.recreate_images(
    &self.lighting,
    extent.width,
    extent.height,
    color_format,
    vk.Format.D32_SFLOAT,
  ) or_return
  post_process.recreate_images(
    gctx,
    &self.post_process,
    &self.texture_manager,
    extent.width,
    extent.height,
    color_format,
  ) or_return
  return .SUCCESS
}

render_camera_depth :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  for &entry, cam_index in self.cameras.entries do if entry.active {
    cam_cpu := &entry.item
    cam_gpu := &self.cameras_gpu[cam_index]
    // Look up draw list source if specified (allows sharing culling between cameras)
    draw_list_source_gpu: ^camera.CameraGPU = nil
    if source := cam_cpu.draw_list_source_handle; source.generation > 0 {
      draw_list_source_gpu = &self.cameras_gpu[source.index]
    }
    visibility.render_depth(&self.visibility, gctx, command_buffer, cam_gpu, cam_cpu, &self.texture_manager, u32(cam_index), frame_index, {.VISIBLE}, {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME}, self.textures_descriptor_set, self.bone_buffer.descriptor_sets[frame_index], self.material_buffer.descriptor_set, self.world_matrix_buffer.descriptor_set, self.node_data_buffer.descriptor_set, self.mesh_data_buffer.descriptor_set, self.vertex_skinning_buffer.descriptor_set, self.vertex_buffer.buffer, self.index_buffer.buffer, draw_list_source_gpu)
  }
  for &entry, cam_index in self.spherical_cameras.entries do if entry.active {
    cam_cpu := &entry.item
    cam_gpu := &self.spherical_cameras_gpu[cam_index]
    visibility.render_sphere_depth(&self.visibility, gctx, command_buffer, cam_gpu, cam_cpu, &self.texture_manager, u32(cam_index), frame_index, {.VISIBLE}, {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME}, self.sphere_pipeline_layout, self.textures_descriptor_set, self.spherical_camera_buffer.descriptor_sets[frame_index], self.bone_buffer.descriptor_sets[frame_index], self.material_buffer.descriptor_set, self.world_matrix_buffer.descriptor_set, self.node_data_buffer.descriptor_set, self.mesh_data_buffer.descriptor_set, self.vertex_skinning_buffer.descriptor_set, self.vertex_buffer.buffer, self.index_buffer.buffer)
  }
  return .SUCCESS
}

record_geometry_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  camera_handle: d.CameraHandle,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu := cont.get(self.cameras, camera_handle)
  if camera_cpu == nil do return .ERROR_UNKNOWN
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  geometry.begin_pass(
    camera_gpu,
    camera_cpu,
    &self.texture_manager,
    command_buffer,
    frame_index,
  )
  geometry.render(
    &self.geometry,
    camera_gpu,
    camera_handle,
    frame_index,
    command_buffer,
    self.general_pipeline_layout,
    self.textures_descriptor_set,
    self.bone_buffer.descriptor_sets[frame_index],
    self.material_buffer.descriptor_set,
    self.world_matrix_buffer.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.mesh_data_buffer.descriptor_set,
    self.vertex_skinning_buffer.descriptor_set,
    self.vertex_buffer.buffer,
    self.index_buffer.buffer,
    camera_gpu.opaque_draw_commands[frame_index].buffer,
    camera_gpu.opaque_draw_count[frame_index].buffer,
  )
  geometry.end_pass(
    camera_gpu,
    &self.texture_manager,
    command_buffer,
    frame_index,
  )
  return .SUCCESS
}

record_lighting_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  active_lights: []d.LightHandle,
  camera_handle: d.CameraHandle,
  color_format: vk.Format,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu := cont.get(self.cameras, camera_handle)
  if camera_cpu == nil do return .ERROR_UNKNOWN
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  lighting.begin_ambient_pass(
    &self.lighting,
    camera_gpu,
    camera_cpu,
    &self.texture_manager,
    command_buffer,
    frame_index,
  )
  lighting.render_ambient(
    &self.lighting,
    camera_handle,
    camera_gpu,
    command_buffer,
    frame_index,
  )
  lighting.end_ambient_pass(command_buffer)
  lighting.begin_pass(
    &self.lighting,
    camera_gpu,
    camera_cpu,
    &self.texture_manager,
    command_buffer,
    self.lights_buffer.descriptor_set,
    self.world_matrix_buffer.descriptor_set,
    self.spherical_camera_buffer.descriptor_sets[frame_index],
    frame_index,
  )
  lighting.render(
    &self.lighting,
    camera_handle,
    camera_gpu,
    &self.cameras_gpu,
    &self.spherical_cameras_gpu,
    command_buffer,
    self.cameras,
    self.lights,
    active_lights,
    &self.world_matrix_buffer,
    frame_index,
  )
  lighting.end_pass(command_buffer)
  return .SUCCESS
}

record_particles_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  camera_handle: d.CameraHandle,
  color_format: vk.Format,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu, ok := cont.get(self.cameras, camera_handle)
  if !ok do return .ERROR_UNKNOWN
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  particles.begin_pass(
    &self.particles,
    command_buffer,
    camera_gpu,
    camera_cpu,
    &self.texture_manager,
    frame_index,
  )
  particles.render(
    &self.particles,
    command_buffer,
    camera_gpu,
    camera_handle.index,
    frame_index,
    self.textures_descriptor_set,
  )
  particles.end_pass(command_buffer)
  return .SUCCESS
}

record_transparency_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  camera_handle: d.CameraHandle,
  color_format: vk.Format,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu, ok := cont.get(self.cameras, camera_handle)
  if !ok do return .ERROR_UNKNOWN
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  // Barrier: Wait for compute to finish before reading draw commands
  gpu.buffer_barrier(
    command_buffer,
    camera_gpu.transparent_draw_commands[frame_index].buffer,
    vk.DeviceSize(
      camera_gpu.transparent_draw_commands[frame_index].bytes_count,
    ),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    camera_gpu.transparent_draw_count[frame_index].buffer,
    vk.DeviceSize(camera_gpu.transparent_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    camera_gpu.sprite_draw_commands[frame_index].buffer,
    vk.DeviceSize(camera_gpu.sprite_draw_commands[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    camera_gpu.sprite_draw_count[frame_index].buffer,
    vk.DeviceSize(camera_gpu.sprite_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  transparency.begin_pass(
    &self.transparency,
    camera_gpu,
    camera_cpu,
    &self.texture_manager,
    command_buffer,
    frame_index,
  )
  transparency.render(
    &self.transparency,
    camera_gpu,
    self.transparency.transparent_pipeline,
    self.general_pipeline_layout,
    self.sprite_pipeline_layout,
    self.textures_descriptor_set,
    self.bone_buffer.descriptor_sets[frame_index],
    self.material_buffer.descriptor_set,
    self.world_matrix_buffer.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.mesh_data_buffer.descriptor_set,
    self.sprite_buffer.descriptor_set,
    self.vertex_skinning_buffer.descriptor_set,
    self.vertex_buffer.buffer,
    self.index_buffer.buffer,
    camera_handle,
    frame_index,
    command_buffer,
    camera_gpu.transparent_draw_commands[frame_index].buffer,
    camera_gpu.transparent_draw_count[frame_index].buffer,
  )
  transparency.render(
    &self.transparency,
    camera_gpu,
    self.transparency.sprite_pipeline,
    self.general_pipeline_layout,
    self.sprite_pipeline_layout,
    self.textures_descriptor_set,
    self.bone_buffer.descriptor_sets[frame_index],
    self.material_buffer.descriptor_set,
    self.world_matrix_buffer.descriptor_set,
    self.node_data_buffer.descriptor_set,
    self.mesh_data_buffer.descriptor_set,
    self.sprite_buffer.descriptor_set,
    self.vertex_skinning_buffer.descriptor_set,
    self.vertex_buffer.buffer,
    self.index_buffer.buffer,
    camera_handle,
    frame_index,
    command_buffer,
    camera_gpu.sprite_draw_commands[frame_index].buffer,
    camera_gpu.sprite_draw_count[frame_index].buffer,
  )
  transparency.end_pass(&self.transparency, command_buffer)
  return .SUCCESS
}

record_debug_draw_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  destroy_line_strip_mesh_ctx: rawptr,
  destroy_line_strip_mesh: proc(ctx: rawptr, handle: d.MeshHandle),
  camera_handle: d.CameraHandle,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu, ok := cont.get(self.cameras, camera_handle)
  if !ok do return .ERROR_UNKNOWN
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  debug_draw.update(
    &self.debug_draw,
    destroy_line_strip_mesh_ctx,
    destroy_line_strip_mesh,
  )
  debug_draw.begin_pass(
    &self.debug_draw,
    camera_gpu,
    camera_cpu,
    &self.texture_manager,
    command_buffer,
    frame_index,
  )
  debug_draw.render(
    &self.debug_draw,
    camera_gpu,
    camera_handle,
    command_buffer,
    self.meshes,
    frame_index,
    self.vertex_buffer.buffer,
    self.index_buffer.buffer,
  )
  debug_draw.end_pass(&self.debug_draw, command_buffer)
  return .SUCCESS
}

record_post_process_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  camera_handle: d.CameraHandle,
  color_format: vk.Format,
  swapchain_extent: vk.Extent2D,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera_cpu, ok := cont.get(self.cameras, camera_handle)
  if !ok do return .ERROR_UNKNOWN
  camera_gpu := &self.cameras_gpu[camera_handle.index]
  if final_image := gpu.get_texture_2d(
    &self.texture_manager,
    camera_gpu.attachments[.FINAL_IMAGE][frame_index],
  ); final_image != nil {
    gpu.image_barrier(
      command_buffer,
      final_image.image,
      .COLOR_ATTACHMENT_OPTIMAL,
      .SHADER_READ_ONLY_OPTIMAL,
      {.COLOR_ATTACHMENT_WRITE},
      {.SHADER_READ},
      {.COLOR_ATTACHMENT_OUTPUT},
      {.FRAGMENT_SHADER},
      {.COLOR},
    )
  }
  gpu.image_barrier(
    command_buffer,
    swapchain_image,
    .UNDEFINED,
    .COLOR_ATTACHMENT_OPTIMAL,
    {},
    {.COLOR_ATTACHMENT_WRITE},
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.COLOR},
  )
  post_process.begin_pass(&self.post_process, command_buffer, swapchain_extent)
  post_process.render(
    &self.post_process,
    command_buffer,
    swapchain_extent,
    swapchain_view,
    camera_gpu,
    &self.texture_manager,
    frame_index,
  )
  post_process.end_pass(&self.post_process, command_buffer)
  return .SUCCESS
}

record_ui_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  swapchain_view: vk.ImageView,
  swapchain_extent: vk.Extent2D,
  command_buffer: vk.CommandBuffer,
) {
  // UI rendering pass - renders on top of post-processed image
  rendering_attachment_info := vk.RenderingAttachmentInfo {
    sType       = .RENDERING_ATTACHMENT_INFO,
    imageView   = swapchain_view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }

  rendering_info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {extent = swapchain_extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &rendering_attachment_info,
  }

  vk.CmdBeginRendering(command_buffer, &rendering_info)

  // Set viewport and scissor
  viewport := vk.Viewport {
    x        = 0,
    y        = f32(swapchain_extent.height),
    width    = f32(swapchain_extent.width),
    height   = -f32(swapchain_extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    offset = {0, 0},
    extent = swapchain_extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

  // Bind pipeline and descriptor sets
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.ui.pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    self.ui.pipeline_layout,
    0,
    1,
    &self.ui.projection_descriptor_set,
    0,
    nil,
  )
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    self.ui.pipeline_layout,
    1,
    1,
    &self.textures_descriptor_set,
    0,
    nil,
  )

  // Render UI
  ui.compute_layout_all(&self.ui_system)
  ui.render(
    &self.ui,
    &self.ui_system,
    gctx,
    &self.texture_manager,
    command_buffer,
    swapchain_extent.width,
    swapchain_extent.height,
    frame_index,
  )

  vk.CmdEndRendering(command_buffer)
}

get_camera_attachment :: proc(
  self: ^Manager,
  camera_handle: d.CameraHandle,
  attachment_type: camera.AttachmentType,
  frame_index: u32 = 0,
) -> gpu.Texture2DHandle {
  return camera.get_attachment(
    &self.cameras_gpu[camera_handle.index],
    attachment_type,
    frame_index,
  )
}
