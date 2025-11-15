package resources

import "../animation"
import cont "../containers"
import "../geometry"
import "../gpu"
import "core:log"
import "core:slice"
import vk "vendor:vulkan"

Handle :: cont.Handle
Pool :: cont.Pool
SlabAllocator :: cont.SlabAllocator

ResourceMetadata :: struct {
  ref_count:  u32, // Reference count for resource lifetime tracking
  auto_purge: bool, // true = purge when ref_count==0, false = self managed lifecycle, never purged automatically
}

SamplerType :: enum u32 {
  NEAREST_CLAMP  = 0,
  LINEAR_CLAMP   = 1,
  NEAREST_REPEAT = 2,
  LINEAR_REPEAT  = 3,
}

Manager :: struct {
  // Global samplers
  linear_repeat_sampler:                     vk.Sampler,
  linear_clamp_sampler:                      vk.Sampler,
  nearest_repeat_sampler:                    vk.Sampler,
  nearest_clamp_sampler:                     vk.Sampler,
  // Builtin materials
  builtin_materials:                         [len(Color)]Handle,
  // Builtin meshes
  builtin_meshes:                            [len(Primitive)]Handle,
  // Resource pools
  meshes:                                    Pool(Mesh),
  materials:                                 Pool(Material),
  images_2d:                                 Pool(gpu.Image),
  images_cube:                               Pool(gpu.CubeImage),
  cameras:                                   Pool(Camera),
  spherical_cameras:                         Pool(SphericalCamera),
  emitters:                                  Pool(Emitter),
  forcefields:                               Pool(ForceField),
  animation_clips:                           Pool(animation.Clip),
  sprites:                                   Pool(Sprite),
  // Navigation system resources
  nav_meshes:                                Pool(NavMesh),
  nav_contexts:                              Pool(NavContext),
  navigation_system:                         NavigationSystem,
  // Bone matrix system
  bone_buffer:                               gpu.BindlessBuffer(
    matrix[4, 4]f32,
  ),
  bone_matrix_slab:                          SlabAllocator,
  // Bindless camera buffer system (per-frame to avoid frame overlap)
  camera_buffer:                             gpu.PerFrameBindlessBuffer(
    CameraData,
    FRAMES_IN_FLIGHT,
  ),
  // Bindless spherical camera buffer system
  spherical_camera_buffer:                   gpu.PerFrameBindlessBuffer(
    SphericalCameraData,
    FRAMES_IN_FLIGHT,
  ),
  // Bindless material buffer system
  material_buffer:                           gpu.BindlessBuffer(MaterialData),
  // Bindless world matrix buffer system
  world_matrix_buffer:                       gpu.BindlessBuffer(
    matrix[4, 4]f32,
  ),
  // Bindless node data buffer system
  node_data_buffer:                          gpu.BindlessBuffer(NodeData),
  // Bindless mesh data buffer system
  mesh_data_buffer:                          gpu.BindlessBuffer(MeshData),
  // Bindless emitter buffer system
  emitter_buffer:                            gpu.BindlessBuffer(EmitterData),
  // Bindless forcefield buffer system
  forcefield_buffer:                         gpu.BindlessBuffer(
    ForceFieldData,
  ),
  // Bindless sprite buffer system
  sprite_buffer:                             gpu.BindlessBuffer(SpriteData),
  // Bindless vertex skinning buffer system
  vertex_skinning_buffer:                    gpu.ImmutableBuffer(
    geometry.SkinningData,
  ),
  vertex_skinning_buffer_set_layout:         vk.DescriptorSetLayout,
  vertex_skinning_descriptor_set:            vk.DescriptorSet,
  vertex_skinning_slab:                      SlabAllocator,
  // Bindless lights buffer system (staged - infrequent updates)
  lights:                                    Pool(Light),
  lights_buffer:                             gpu.BindlessBuffer(LightData),
  // Per-frame dynamic light data (position + shadow_map, synchronized per frame)
  dynamic_light_data_buffer:                 gpu.PerFrameBindlessBuffer(
    DynamicLightData,
    FRAMES_IN_FLIGHT,
  ),
  // Bindless texture system
  textures_set_layout:                       vk.DescriptorSetLayout,
  textures_descriptor_set:                   vk.DescriptorSet,
  // Shared pipeline layouts
  geometry_pipeline_layout:                  vk.PipelineLayout, // Used by geometry, transparency, depth renderers
  spherical_camera_pipeline_layout:          vk.PipelineLayout, // Used by spherical depth rendering (point light shadows)
  // Visibility system descriptor layouts (for shadow cameras)
  visibility_sphere_descriptor_layout:       vk.DescriptorSetLayout,
  visibility_descriptor_layout:              vk.DescriptorSetLayout,
  visibility_depth_reduce_descriptor_layout: vk.DescriptorSetLayout,
  // Bindless vertex/index buffer system
  vertex_buffer:                             gpu.ImmutableBuffer(
    geometry.Vertex,
  ),
  index_buffer:                              gpu.ImmutableBuffer(u32),
  vertex_slab:                               SlabAllocator,
  index_slab:                                SlabAllocator,
  // Frame-scoped bookkeeping
  current_frame_index:                       u32,
  // Animation tracking
  animatable_sprites:                        [dynamic]Handle,
  // Rendering tracking
  active_lights:                             [dynamic]Handle,
}

init :: proc(self: ^Manager, gctx: ^gpu.GPUContext) -> (ret: vk.Result) {
  log.infof("Initializing mesh pool... ")
  cont.init(&self.meshes, MAX_MESHES)
  log.infof("Initializing materials pool... ")
  cont.init(&self.materials, MAX_MATERIALS)
  log.infof("Initializing image 2d buffer pool... ")
  cont.init(&self.images_2d, MAX_TEXTURES)
  log.infof("Initializing image cube buffer pool... ")
  cont.init(&self.images_cube, MAX_CUBE_TEXTURES)
  log.infof("Initializing cameras pool... ")
  cont.init(&self.cameras, MAX_ACTIVE_CAMERAS)
  log.infof("Initializing spherical cameras pool... ")
  cont.init(&self.spherical_cameras, MAX_ACTIVE_CAMERAS)
  log.infof("Initializing forcefield pool... ")
  cont.init(&self.forcefields, MAX_FORCE_FIELDS)
  log.infof("Initializing animation clips pool... ")
  cont.init(&self.animation_clips, 0)
  log.infof("Initializing sprites pool... ")
  cont.init(&self.sprites, MAX_SPRITES)
  log.infof("Initializing lights pool... ")
  cont.init(&self.lights, MAX_LIGHTS)
  log.infof("Initializing navigation mesh pool... ")
  cont.init(&self.nav_meshes, 0)
  log.infof("Initializing navigation context pool... ")
  cont.init(&self.nav_contexts, 0)
  log.infof("Initializing navigation system... ")
  self.navigation_system = {}
  self.current_frame_index = 0
  log.infof("All resource pools initialized successfully")
  init_global_samplers(self, gctx)
  log.info("Initializing bindless buffer systems...")
  init_bone_matrix_allocator(self, gctx) or_return
  defer if ret != .SUCCESS do destroy_bone_matrix_allocator(self, gctx)
  gpu.per_frame_bindless_buffer_init(
    &self.camera_buffer,
    gctx,
    MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS do gpu.per_frame_bindless_buffer_destroy(&self.camera_buffer, gctx.device)
  gpu.per_frame_bindless_buffer_init(
    &self.spherical_camera_buffer,
    gctx,
    MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE, .GEOMETRY},
  ) or_return
  defer if ret != .SUCCESS do gpu.per_frame_bindless_buffer_destroy(&self.spherical_camera_buffer, gctx.device)
  gpu.bindless_buffer_init(
    &self.material_buffer,
    gctx,
    MAX_MATERIALS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS do gpu.bindless_buffer_destroy(&self.material_buffer, gctx.device)
  gpu.bindless_buffer_init(
    &self.world_matrix_buffer,
    gctx,
    MAX_NODES_IN_SCENE,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS do gpu.bindless_buffer_destroy(&self.world_matrix_buffer, gctx.device)
  init_node_data_buffer(self, gctx) or_return
  defer if ret != .SUCCESS do destroy_node_data_buffer(self, gctx)
  gpu.bindless_buffer_init(
    &self.mesh_data_buffer,
    gctx,
    MAX_MESHES,
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS do gpu.bindless_buffer_destroy(&self.mesh_data_buffer, gctx.device)
  init_vertex_skinning_buffer(self, gctx) or_return
  defer if ret != .SUCCESS do destroy_vertex_skinning_buffer(self, gctx)
  gpu.bindless_buffer_init(
    &self.emitter_buffer,
    gctx,
    MAX_EMITTERS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS do gpu.bindless_buffer_destroy(&self.emitter_buffer, gctx.device)
  emitters := gpu.get_all(&self.emitter_buffer.buffer)
  for &emitter in emitters do emitter = {}
  gpu.bindless_buffer_init(
    &self.forcefield_buffer,
    gctx,
    MAX_FORCE_FIELDS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS do gpu.bindless_buffer_destroy(&self.forcefield_buffer, gctx.device)
  forcefields := gpu.get_all(&self.forcefield_buffer.buffer)
  for &forcefield in forcefields do forcefield = {}
  gpu.bindless_buffer_init(
    &self.lights_buffer,
    gctx,
    MAX_LIGHTS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS do gpu.bindless_buffer_destroy(&self.lights_buffer, gctx.device)
  gpu.per_frame_bindless_buffer_init(
    &self.dynamic_light_data_buffer,
    gctx,
    MAX_LIGHTS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS do gpu.per_frame_bindless_buffer_destroy(&self.dynamic_light_data_buffer, gctx.device)
  for frame_idx in 0 ..< FRAMES_IN_FLIGHT {
    dynamic_data := gpu.get_all(
      &self.dynamic_light_data_buffer.buffers[frame_idx],
    )
    for &data in dynamic_data {
      data.position = {0, 0, 0, 0}
      data.shadow_map = 0xFFFFFFFF
    }
  }
  gpu.bindless_buffer_init(
    &self.sprite_buffer,
    gctx,
    MAX_SPRITES,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS do gpu.bindless_buffer_destroy(&self.sprite_buffer, gctx.device)
  sprites := gpu.get_all(&self.sprite_buffer.buffer)
  for &sprite in sprites do sprite = {}
  init_vertex_index_buffers(self, gctx) or_return
  defer if ret != .SUCCESS do destroy_vertex_index_buffers(self, gctx)
  log.info("Bindless buffer systems initialized successfully")
  self.textures_set_layout = gpu.create_descriptor_set_layout_array(
    gctx,
    {.SAMPLED_IMAGE, MAX_TEXTURES, {.FRAGMENT}},
    {.SAMPLER, gpu.MAX_SAMPLERS, {.FRAGMENT}},
    {.SAMPLED_IMAGE, MAX_CUBE_TEXTURES, {.FRAGMENT}},
  ) or_return
  self.geometry_pipeline_layout = gpu.create_pipeline_layout(
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
    self.vertex_skinning_buffer_set_layout,
    self.lights_buffer.set_layout,
    self.sprite_buffer.set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.geometry_pipeline_layout, nil)
    self.geometry_pipeline_layout = 0
  }
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(gctx.device, self.textures_set_layout, nil)
    self.textures_set_layout = 0
  }
  // Pipeline layout for spherical depth rendering (point light shadows)
  self.spherical_camera_pipeline_layout = gpu.create_pipeline_layout(
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
    self.vertex_skinning_buffer_set_layout,
    self.lights_buffer.set_layout,
    self.sprite_buffer.set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(
      gctx.device,
      self.spherical_camera_pipeline_layout,
      nil,
    )
    self.spherical_camera_pipeline_layout = 0
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
  init_builtin_materials(self) or_return
  init_builtin_meshes(self, gctx) or_return
  return .SUCCESS
}

shutdown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.bindless_buffer_destroy(&self.material_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.world_matrix_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.emitter_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.forcefield_buffer, gctx.device)
  gpu.bindless_buffer_destroy(&self.lights_buffer, gctx.device)
  gpu.per_frame_bindless_buffer_destroy(
    &self.dynamic_light_data_buffer,
    gctx.device,
  )
  gpu.bindless_buffer_destroy(&self.sprite_buffer, gctx.device)
  // Clean up lights (which may own shadow cameras with textures)
  for &entry, i in self.lights.entries do if entry.generation > 0 && entry.active {
    destroy_light(self, gctx, Handle{index = u32(i), generation = entry.generation})
  }
  delete(self.lights.entries)
  delete(self.lights.free_indices)
  for &entry in self.spherical_cameras.entries do if entry.generation > 0 && entry.active {
    spherical_camera_destroy(&entry.item, gctx, self)
  }
  delete(self.spherical_cameras.entries)
  delete(self.spherical_cameras.free_indices)
  for &entry in self.cameras.entries do if entry.generation > 0 && entry.active {
    camera_destroy(&entry.item, gctx, self)
  }
  delete(self.cameras.entries)
  delete(self.cameras.free_indices)
  for &entry in self.images_2d.entries do if entry.generation > 0 && entry.active {
    gpu.image_destroy(gctx.device, &entry.item)
  }
  delete(self.images_2d.entries)
  delete(self.images_2d.free_indices)
  for &entry in self.images_cube.entries do if entry.generation > 0 && entry.active {
    gpu.cube_depth_texture_destroy(gctx.device, &entry.item)
  }
  delete(self.images_cube.entries)
  delete(self.images_cube.free_indices)
  for &entry in self.meshes.entries do if entry.generation > 0 && entry.active {
    mesh_destroy(&entry.item, self)
  }
  delete(self.meshes.entries)
  delete(self.meshes.free_indices)
  // Simple cleanup for pools without GPU resources
  delete(self.materials.entries)
  delete(self.materials.free_indices)
  delete(self.emitters.entries)
  delete(self.emitters.free_indices)
  delete(self.forcefields.entries)
  delete(self.forcefields.free_indices)
  delete(self.sprites.entries)
  delete(self.sprites.free_indices)
  delete(self.animatable_sprites)
  delete(self.active_lights)
  for &entry in self.animation_clips.entries do if entry.generation > 0 && entry.active {
    animation.clip_destroy(&entry.item)
  }
  delete(self.animation_clips.entries)
  delete(self.animation_clips.free_indices)
  // Navigation system cleanup
  for &entry in self.nav_meshes.entries do if entry.generation > 0 && entry.active {
    // Clean up navigation mesh
    // TODO: detour mesh cleanup would be added here if needed
  }
  delete(self.nav_meshes.entries)
  delete(self.nav_meshes.free_indices)
  for &entry in self.nav_contexts.entries do if entry.generation > 0 && entry.active {
    // Clean up navigation contexts
    // TODO: context cleanup would be added here if needed
  }
  delete(self.nav_contexts.entries)
  delete(self.nav_contexts.free_indices)
  // Clean up navigation system
  delete(self.navigation_system.geometry_cache)
  delete(self.navigation_system.dirty_tiles)
  destroy_global_samplers(self, gctx)
  destroy_bone_matrix_allocator(self, gctx)
  gpu.per_frame_bindless_buffer_destroy(&self.camera_buffer, gctx.device)
  gpu.per_frame_bindless_buffer_destroy(
    &self.spherical_camera_buffer,
    gctx.device,
  )
  destroy_node_data_buffer(self, gctx)
  gpu.bindless_buffer_destroy(&self.mesh_data_buffer, gctx.device)
  destroy_vertex_skinning_buffer(self, gctx)
  destroy_vertex_index_buffers(self, gctx)
  vk.DestroyPipelineLayout(gctx.device, self.geometry_pipeline_layout, nil)
  self.geometry_pipeline_layout = 0
  vk.DestroyPipelineLayout(
    gctx.device,
    self.spherical_camera_pipeline_layout,
    nil,
  )
  self.spherical_camera_pipeline_layout = 0
  vk.DestroyDescriptorSetLayout(gctx.device, self.textures_set_layout, nil)
  self.textures_set_layout = 0
  self.textures_descriptor_set = 0
  // Destroy visibility descriptor set layouts
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    self.visibility_sphere_descriptor_layout,
    nil,
  )
  self.visibility_sphere_descriptor_layout = 0
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    self.visibility_descriptor_layout,
    nil,
  )
  self.visibility_descriptor_layout = 0
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    self.visibility_depth_reduce_descriptor_layout,
    nil,
  )
  self.visibility_depth_reduce_descriptor_layout = 0
}

@(private)
init_global_samplers :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
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
  info.addressModeU = .CLAMP_TO_EDGE
  info.addressModeV = .CLAMP_TO_EDGE
  info.addressModeW = .CLAMP_TO_EDGE
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.linear_clamp_sampler,
  ) or_return
  info.magFilter = .NEAREST
  info.minFilter = .NEAREST
  info.addressModeU = .REPEAT
  info.addressModeV = .REPEAT
  info.addressModeW = .REPEAT
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.nearest_repeat_sampler,
  ) or_return
  info.addressModeU = .CLAMP_TO_EDGE
  info.addressModeV = .CLAMP_TO_EDGE
  info.addressModeW = .CLAMP_TO_EDGE
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &self.nearest_clamp_sampler,
  ) or_return
  return .SUCCESS
}

@(private)
init_bone_matrix_allocator :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  cont.slab_init(
    &self.bone_matrix_slab,
    {
      {32, 64}, // 64 bytes * 32   bones * 64   blocks = 128K bytes
      {64, 128}, // 64 bytes * 64   bones * 128  blocks = 512K bytes
      {128, 8192}, // 64 bytes * 128  bones * 8192 blocks = 64M bytes
      {256, 4096}, // 64 bytes * 256  bones * 4096 blocks = 64M bytes
      {512, 256}, // 64 bytes * 512  bones * 256  blocks = 8M bytes
      {1024, 128}, // 64 bytes * 1024 bones * 256  blocks = 8M bytes
      {2048, 32}, // 64 bytes * 2048 bones * 32   blocks = 4M bytes
      {4096, 16}, // 64 bytes * 4096 bones * 16   blocks = 4M bytes
      // Total size: ~153M bytes for bone matrices
      // This could roughly fit 12000 animated characters with 128 bones each
    },
  )
  log.infof(
    "Creating bone matrix buffer with capacity %d matrices...",
    self.bone_matrix_slab.capacity,
  )
  self.bone_buffer.buffer = gpu.malloc_mutable_buffer(
    gctx,
    matrix[4, 4]f32,
    int(self.bone_matrix_slab.capacity),
    {.STORAGE_BUFFER},
  ) or_return
  self.bone_buffer.set_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.VERTEX}},
  ) or_return
  self.bone_buffer.descriptor_set = gpu.create_descriptor_set(
    gctx,
    &self.bone_buffer.set_layout,
    {.STORAGE_BUFFER, gpu.buffer_info(&self.bone_buffer.buffer)},
  ) or_return
  return .SUCCESS
}


@(private)
init_node_data_buffer :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  log.infof(
    "Creating node data buffer with capacity %d nodes...",
    MAX_NODES_IN_SCENE,
  )
  self.node_data_buffer.buffer = gpu.malloc_mutable_buffer(
    gctx,
    NodeData,
    MAX_NODES_IN_SCENE,
    {.STORAGE_BUFFER},
  ) or_return
  node_slice := gpu.get_all(&self.node_data_buffer.buffer)
  slice.fill(
    node_slice,
    NodeData {
      material_id = 0xFFFFFFFF,
      mesh_id = 0xFFFFFFFF,
      attachment_data_index = 0xFFFFFFFF,
    },
  )
  self.node_data_buffer.set_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.VERTEX, .FRAGMENT}},
  ) or_return
  self.node_data_buffer.descriptor_set = gpu.create_descriptor_set(
    gctx,
    &self.node_data_buffer.set_layout,
    {.STORAGE_BUFFER, gpu.buffer_info(&self.node_data_buffer.buffer)},
  ) or_return
  return .SUCCESS
}

@(private)
destroy_node_data_buffer :: proc(manager: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.mutable_buffer_destroy(gctx.device, &manager.node_data_buffer.buffer)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.node_data_buffer.set_layout,
    nil,
  )
  manager.node_data_buffer.set_layout = 0
  manager.node_data_buffer.descriptor_set = 0
}


@(private)
init_vertex_skinning_buffer :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  skinning_count :=
    BINDLESS_SKINNING_BUFFER_SIZE / size_of(geometry.SkinningData)
  log.infof(
    "Creating vertex skinning buffer with capacity %d entries...",
    skinning_count,
  )
  self.vertex_skinning_buffer = gpu.malloc_buffer(
    gctx,
    geometry.SkinningData,
    skinning_count,
    {.STORAGE_BUFFER},
  ) or_return
  cont.slab_init(&self.vertex_skinning_slab, VERTEX_SLAB_CONFIG)
  self.vertex_skinning_buffer_set_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.VERTEX}},
  ) or_return
  self.vertex_skinning_descriptor_set = gpu.create_descriptor_set(
    gctx,
    &self.vertex_skinning_buffer_set_layout,
    {.STORAGE_BUFFER, gpu.buffer_info(&self.vertex_skinning_buffer)},
  ) or_return
  return .SUCCESS
}

@(private)
destroy_vertex_skinning_buffer :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  cont.slab_destroy(&self.vertex_skinning_slab)
  gpu.buffer_destroy(gctx.device, &self.vertex_skinning_buffer)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    self.vertex_skinning_buffer_set_layout,
    nil,
  )
  self.vertex_skinning_buffer_set_layout = 0
  self.vertex_skinning_descriptor_set = 0
}


@(private)
destroy_global_samplers :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  vk.DestroySampler(
    gctx.device,
    self.linear_repeat_sampler,
    nil,
  );self.linear_repeat_sampler = 0
  vk.DestroySampler(
    gctx.device,
    self.linear_clamp_sampler,
    nil,
  );self.linear_clamp_sampler = 0
  vk.DestroySampler(
    gctx.device,
    self.nearest_repeat_sampler,
    nil,
  );self.nearest_repeat_sampler = 0
  vk.DestroySampler(
    gctx.device,
    self.nearest_clamp_sampler,
    nil,
  );self.nearest_clamp_sampler = 0
}

@(private)
destroy_bone_matrix_allocator :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.bindless_buffer_destroy(&self.bone_buffer, gctx.device)
  cont.slab_destroy(&self.bone_matrix_slab)
}

@(private)
init_vertex_index_buffers :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  vertex_count := BINDLESS_VERTEX_BUFFER_SIZE / size_of(geometry.Vertex)
  index_count := BINDLESS_INDEX_BUFFER_SIZE / size_of(u32)
  self.vertex_buffer = gpu.malloc_buffer(
    gctx,
    geometry.Vertex,
    vertex_count,
    {.VERTEX_BUFFER},
  ) or_return
  self.index_buffer = gpu.malloc_buffer(
    gctx,
    u32,
    index_count,
    {.INDEX_BUFFER},
  ) or_return
  cont.slab_init(&self.vertex_slab, VERTEX_SLAB_CONFIG)
  cont.slab_init(&self.index_slab, INDEX_SLAB_CONFIG)
  log.info("Bindless buffer system initialized")
  log.info("Vertex buffer capacity:", vertex_count, "vertices")
  log.info("Index buffer capacity:", index_count, "indices")
  return .SUCCESS
}

@(private)
destroy_vertex_index_buffers :: proc(
  manager: ^Manager,
  gctx: ^gpu.GPUContext,
) {
  gpu.buffer_destroy(gctx.device, &manager.vertex_buffer)
  gpu.buffer_destroy(gctx.device, &manager.index_buffer)
  cont.slab_destroy(&manager.vertex_slab)
  cont.slab_destroy(&manager.index_slab)
}
