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

SamplerType :: enum u32 {
  NEAREST_CLAMP  = 0,
  LINEAR_CLAMP   = 1,
  NEAREST_REPEAT = 2,
  LINEAR_REPEAT  = 3,
}

BufferAllocation :: struct {
  offset: u32,
  count:  u32,
}

Color :: enum {
  WHITE,
  BLACK,
  GRAY,
  RED,
  GREEN,
  BLUE,
  YELLOW,
  CYAN,
  MAGENTA,
}

Primitive :: enum {
  CUBE,
  SPHERE,
  QUAD,
  CONE,
  CAPSULE,
  CYLINDER,
  TORUS,
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
  image_2d_buffers:                          Pool(gpu.Image),
  image_cube_buffers:                        Pool(gpu.CubeImageBuffer),
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
  bone_buffer_set_layout:                    vk.DescriptorSetLayout,
  bone_buffer_descriptor_set:                vk.DescriptorSet,
  bone_buffer:                               gpu.MutableBuffer(
    matrix[4, 4]f32,
  ),
  bone_matrix_slab:                          SlabAllocator,
  // Bindless camera buffer system (per-frame to avoid frame overlap)
  camera_buffer_set_layout:                  vk.DescriptorSetLayout,
  camera_buffer_descriptor_sets:             [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  camera_buffers:                            [MAX_FRAMES_IN_FLIGHT]gpu.MutableBuffer(CameraData),
  // Bindless spherical camera buffer system
  spherical_camera_buffer_set_layout:        vk.DescriptorSetLayout,
  spherical_camera_buffer_descriptor_sets:   [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  spherical_camera_buffers:                  [MAX_FRAMES_IN_FLIGHT]gpu.MutableBuffer(SphericalCameraData),
  // Bindless material buffer system
  material_buffer_set_layout:                vk.DescriptorSetLayout,
  material_buffer_descriptor_set:            vk.DescriptorSet,
  material_buffer:                           gpu.MutableBuffer(MaterialData),
  // Bindless world matrix buffer system
  world_matrix_buffer_set_layout:            vk.DescriptorSetLayout,
  world_matrix_descriptor_set:               vk.DescriptorSet,
  world_matrix_buffer:                       gpu.MutableBuffer(
    matrix[4, 4]f32,
  ),
  // Bindless node data buffer system
  node_data_buffer_set_layout:               vk.DescriptorSetLayout,
  node_data_descriptor_set:                  vk.DescriptorSet,
  node_data_buffer:                          gpu.MutableBuffer(NodeData),
  // Bindless mesh data buffer system
  mesh_data_buffer_set_layout:               vk.DescriptorSetLayout,
  mesh_data_descriptor_set:                  vk.DescriptorSet,
  mesh_data_buffer:                          gpu.MutableBuffer(MeshData),
  // Bindless emitter buffer system
  emitter_buffer_set_layout:                 vk.DescriptorSetLayout,
  emitter_buffer_descriptor_set:             vk.DescriptorSet,
  emitter_buffer:                            gpu.MutableBuffer(EmitterData),
  // Bindless forcefield buffer system
  forcefield_buffer_set_layout:              vk.DescriptorSetLayout,
  forcefield_buffer_descriptor_set:          vk.DescriptorSet,
  forcefield_buffer:                         gpu.MutableBuffer(ForceFieldData),
  // Bindless sprite buffer system
  sprite_buffer_set_layout:                  vk.DescriptorSetLayout,
  sprite_buffer_descriptor_set:              vk.DescriptorSet,
  sprite_buffer:                             gpu.MutableBuffer(SpriteData),
  // Bindless vertex skinning buffer system
  vertex_skinning_buffer_set_layout:         vk.DescriptorSetLayout,
  vertex_skinning_descriptor_set:            vk.DescriptorSet,
  vertex_skinning_buffer:                    gpu.ImmutableBuffer(
    geometry.SkinningData,
  ),
  vertex_skinning_slab:                      SlabAllocator,
  // Bindless lights buffer system (staged - infrequent updates)
  lights:                                    Pool(Light),
  lights_buffer_set_layout:                  vk.DescriptorSetLayout,
  lights_buffer_descriptor_set:              vk.DescriptorSet,
  lights_buffer:                             gpu.MutableBuffer(LightData),
  // Per-frame dynamic light data (position + shadow_map, synchronized per frame)
  dynamic_light_data_buffers:                [MAX_FRAMES_IN_FLIGHT]gpu.MutableBuffer(DynamicLightData),
  dynamic_light_data_set_layout:             vk.DescriptorSetLayout,
  dynamic_light_data_descriptor_sets:        [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  // Bindless texture system
  textures_set_layout:                       vk.DescriptorSetLayout,
  textures_descriptor_set:                   vk.DescriptorSet,
  // Shared pipeline layouts
  geometry_pipeline_layout:                  vk.PipelineLayout, // Used by geometry, transparency, depth renderers
  spherical_camera_pipeline_layout:          vk.PipelineLayout, // Used by spherical depth rendering (point light shadows)
  // Visibility system descriptor layouts (for shadow cameras)
  visibility_sphere_descriptor_layout:       vk.DescriptorSetLayout,
  visibility_multi_pass_descriptor_layout:   vk.DescriptorSetLayout,
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
}

init :: proc(manager: ^Manager, gctx: ^gpu.GPUContext) -> vk.Result {
  log.infof("Initializing mesh pool... ")
  cont.init(&manager.meshes, MAX_MESHES)
  log.infof("Initializing materials pool... ")
  cont.init(&manager.materials, MAX_MATERIALS)
  log.infof("Initializing image 2d buffer pool... ")
  cont.init(&manager.image_2d_buffers, MAX_TEXTURES)
  log.infof("Initializing image cube buffer pool... ")
  cont.init(&manager.image_cube_buffers, MAX_CUBE_TEXTURES)
  log.infof("Initializing cameras pool... ")
  cont.init(&manager.cameras, MAX_ACTIVE_CAMERAS)
  log.infof("Initializing spherical cameras pool... ")
  cont.init(&manager.spherical_cameras, MAX_ACTIVE_CAMERAS)
  log.infof("Initializing forcefield pool... ")
  cont.init(&manager.forcefields, MAX_FORCE_FIELDS)
  log.infof("Initializing animation clips pool... ")
  cont.init(&manager.animation_clips, 0)
  log.infof("Initializing sprites pool... ")
  cont.init(&manager.sprites, MAX_SPRITES)
  log.infof("Initializing lights pool... ")
  cont.init(&manager.lights, MAX_LIGHTS)
  log.infof("Initializing navigation mesh pool... ")
  cont.init(&manager.nav_meshes, 0)
  log.infof("Initializing navigation context pool... ")
  cont.init(&manager.nav_contexts, 0)
  log.infof("Initializing navigation system... ")
  manager.navigation_system = {}
  manager.current_frame_index = 0
  log.infof("All resource pools initialized successfully")
  init_global_samplers(gctx, manager)
  init_bone_matrix_allocator(gctx, manager) or_return
  init_camera_buffer(gctx, manager) or_return
  init_spherical_camera_buffer(gctx, manager) or_return
  init_material_buffer(gctx, manager) or_return
  init_world_matrix_buffers(gctx, manager) or_return
  init_node_data_buffer(gctx, manager) or_return
  init_mesh_data_buffer(gctx, manager) or_return
  init_vertex_skinning_buffer(gctx, manager) or_return
  init_emitter_buffer(gctx, manager) or_return
  init_forcefield_buffer(gctx, manager) or_return
  init_lights_buffer(gctx, manager) or_return
  init_dynamic_light_data_buffers(gctx, manager) or_return
  init_sprite_buffer(gctx, manager) or_return
  init_vertex_index_buffers(gctx, manager) or_return
  // Texture + samplers descriptor set
  textures_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .SAMPLED_IMAGE,
      descriptorCount = MAX_TEXTURES,
      stageFlags = {.FRAGMENT},
    },
    {
      binding = 1,
      descriptorType = .SAMPLER,
      descriptorCount = gpu.MAX_SAMPLERS,
      stageFlags = {.FRAGMENT},
    },
    {
      binding = 2,
      descriptorType = .SAMPLED_IMAGE,
      descriptorCount = MAX_CUBE_TEXTURES,
      stageFlags = {.FRAGMENT},
    },
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(textures_bindings),
      pBindings = raw_data(textures_bindings[:]),
    },
    nil,
    &manager.textures_set_layout,
  ) or_return
  layout_result := create_geometry_pipeline_layout(gctx, manager)
  if layout_result != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      manager.textures_set_layout,
      nil,
    )
    manager.textures_set_layout = 0
    return layout_result
  }
  spherical_layout_result := create_spherical_camera_pipeline_layout(
    gctx,
    manager,
  )
  if spherical_layout_result != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      manager.textures_set_layout,
      nil,
    )
    manager.textures_set_layout = 0
    vk.DestroyPipelineLayout(
      gctx.device,
      manager.geometry_pipeline_layout,
      nil,
    )
    manager.geometry_pipeline_layout = 0
    return spherical_layout_result
  }
  vk.AllocateDescriptorSets(
    gctx.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &manager.textures_set_layout,
    },
    &manager.textures_descriptor_set,
  ) or_return
  writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = manager.textures_descriptor_set,
      dstBinding = 1,
      dstArrayElement = u32(SamplerType.NEAREST_CLAMP),
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = manager.nearest_clamp_sampler},
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = manager.textures_descriptor_set,
      dstBinding = 1,
      dstArrayElement = u32(SamplerType.LINEAR_CLAMP),
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = manager.linear_clamp_sampler},
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = manager.textures_descriptor_set,
      dstBinding = 1,
      dstArrayElement = u32(SamplerType.NEAREST_REPEAT),
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = manager.nearest_repeat_sampler},
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = manager.textures_descriptor_set,
      dstBinding = 1,
      dstArrayElement = u32(SamplerType.LINEAR_REPEAT),
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = manager.linear_repeat_sampler},
    },
  }
  vk.UpdateDescriptorSets(
    gctx.device,
    len(writes),
    raw_data(writes[:]),
    0,
    nil,
  )
  init_builtin_materials(manager) or_return
  init_builtin_meshes(manager, gctx) or_return
  return .SUCCESS
}

shutdown :: proc(manager: ^Manager, gctx: ^gpu.GPUContext) {
  destroy_material_buffer(gctx, manager)
  destroy_world_matrix_buffers(gctx, manager)
  destroy_emitter_buffer(gctx, manager)
  destroy_forcefield_buffer(gctx, manager)
  destroy_lights_buffer(gctx, manager)
  destroy_dynamic_light_data_buffers(gctx, manager)
  destroy_sprite_buffer(gctx, manager)
  // Clean up lights (which may own shadow cameras with textures)
  for &entry, i in manager.lights.entries {
    if entry.generation > 0 && entry.active {
      destroy_light(
        manager,
        gctx,
        Handle{index = u32(i), generation = entry.generation},
      )
    }
  }
  delete(manager.lights.entries)
  delete(manager.lights.free_indices)
  // Clean up spherical cameras with GPU resources (frees their textures)
  for &entry in manager.spherical_cameras.entries {
    if entry.generation > 0 && entry.active {
      spherical_camera_destroy(
        &entry.item,
        gctx.device,
        gctx.command_pool,
        manager,
      )
    }
  }
  delete(manager.spherical_cameras.entries)
  delete(manager.spherical_cameras.free_indices)
  // Clean up regular cameras with GPU resources (frees their textures)
  for &entry in manager.cameras.entries {
    if entry.generation > 0 && entry.active {
      camera_destroy(&entry.item, gctx.device, gctx.command_pool, manager)
    }
  }
  delete(manager.cameras.entries)
  delete(manager.cameras.free_indices)
  // Now safe to destroy texture pools - all owned textures have been freed
  for &entry in manager.image_2d_buffers.entries {
    if entry.generation > 0 && entry.active {
      gpu.image_destroy(gctx.device, &entry.item)
    }
  }
  delete(manager.image_2d_buffers.entries)
  delete(manager.image_2d_buffers.free_indices)
  for &entry in manager.image_cube_buffers.entries {
    if entry.generation > 0 && entry.active {
      gpu.cube_depth_texture_destroy(gctx.device, &entry.item)
    }
  }
  delete(manager.image_cube_buffers.entries)
  delete(manager.image_cube_buffers.free_indices)
  for &entry in manager.meshes.entries {
    if entry.generation > 0 && entry.active {
      mesh_destroy(&entry.item, gctx, manager)
    }
  }
  delete(manager.meshes.entries)
  delete(manager.meshes.free_indices)
  // Simple cleanup for pools without GPU resources
  delete(manager.materials.entries)
  delete(manager.materials.free_indices)
  delete(manager.emitters.entries)
  delete(manager.emitters.free_indices)
  delete(manager.forcefields.entries)
  delete(manager.forcefields.free_indices)
  delete(manager.sprites.entries)
  delete(manager.sprites.free_indices)
  for &entry in manager.animation_clips.entries {
    if entry.generation > 0 && entry.active {
      animation.clip_destroy(&entry.item)
    }
  }
  delete(manager.animation_clips.entries)
  delete(manager.animation_clips.free_indices)
  // Navigation system cleanup
  for &entry in manager.nav_meshes.entries {
    if entry.generation > 0 && entry.active {
      // Clean up navigation mesh
      // TODO: detour mesh cleanup would be added here if needed
    }
  }
  delete(manager.nav_meshes.entries)
  delete(manager.nav_meshes.free_indices)
  for &entry in manager.nav_contexts.entries {
    if entry.generation > 0 && entry.active {
      // Clean up navigation contexts
      // TODO: context cleanup would be added here if needed
    }
  }
  delete(manager.nav_contexts.entries)
  delete(manager.nav_contexts.free_indices)
  // Clean up navigation system
  delete(manager.navigation_system.geometry_cache)
  delete(manager.navigation_system.dirty_tiles)
  destroy_global_samplers(gctx, manager)
  destroy_bone_matrix_allocator(gctx, manager)
  destroy_camera_buffer(gctx, manager)
  destroy_spherical_camera_buffer(gctx, manager)
  destroy_node_data_buffer(gctx, manager)
  destroy_mesh_data_buffer(gctx, manager)
  destroy_vertex_skinning_buffer(gctx, manager)
  destroy_vertex_index_buffers(gctx, manager)
  vk.DestroyPipelineLayout(gctx.device, manager.geometry_pipeline_layout, nil)
  manager.geometry_pipeline_layout = 0
  vk.DestroyPipelineLayout(
    gctx.device,
    manager.spherical_camera_pipeline_layout,
    nil,
  )
  manager.spherical_camera_pipeline_layout = 0
  vk.DestroyDescriptorSetLayout(gctx.device, manager.textures_set_layout, nil)
  manager.textures_set_layout = 0
  manager.textures_descriptor_set = 0
  // Destroy visibility descriptor set layouts
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.visibility_sphere_descriptor_layout,
    nil,
  )
  manager.visibility_sphere_descriptor_layout = 0
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.visibility_depth_reduce_descriptor_layout,
    nil,
  )
  manager.visibility_depth_reduce_descriptor_layout = 0
}

create_geometry_pipeline_layout :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX, .FRAGMENT},
    size       = size_of(u32),
  }
  set_layouts := [?]vk.DescriptorSetLayout {
    manager.camera_buffer_set_layout,
    manager.textures_set_layout,
    manager.bone_buffer_set_layout,
    manager.material_buffer_set_layout,
    manager.world_matrix_buffer_set_layout,
    manager.node_data_buffer_set_layout,
    manager.mesh_data_buffer_set_layout,
    manager.vertex_skinning_buffer_set_layout,
    manager.lights_buffer_set_layout,
    manager.sprite_buffer_set_layout,
  }
  vk.CreatePipelineLayout(
    gctx.device,
    &vk.PipelineLayoutCreateInfo {
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(set_layouts),
      pSetLayouts = raw_data(set_layouts[:]),
      pushConstantRangeCount = 1,
      pPushConstantRanges = &push_constant_range,
    },
    nil,
    &manager.geometry_pipeline_layout,
  ) or_return
  return .SUCCESS
}

create_spherical_camera_pipeline_layout :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  // Pipeline layout for spherical depth rendering (point light shadows)
  // Uses spherical_camera_buffer instead of regular camera_buffer at set 0
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX, .GEOMETRY, .FRAGMENT},
    size       = size_of(u32),
  }
  set_layouts := [?]vk.DescriptorSetLayout {
    manager.spherical_camera_buffer_set_layout, // Spherical cameras at set 0
    manager.textures_set_layout,
    manager.bone_buffer_set_layout,
    manager.material_buffer_set_layout,
    manager.world_matrix_buffer_set_layout,
    manager.node_data_buffer_set_layout,
    manager.mesh_data_buffer_set_layout,
    manager.vertex_skinning_buffer_set_layout,
    manager.lights_buffer_set_layout,
    manager.sprite_buffer_set_layout,
  }
  vk.CreatePipelineLayout(
    gctx.device,
    &vk.PipelineLayoutCreateInfo {
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(set_layouts),
      pSetLayouts = raw_data(set_layouts[:]),
      pushConstantRangeCount = 1,
      pPushConstantRanges = &push_constant_range,
    },
    nil,
    &manager.spherical_camera_pipeline_layout,
  ) or_return
  return .SUCCESS
}

init_global_samplers :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
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
    &manager.linear_repeat_sampler,
  ) or_return
  info.addressModeU = .CLAMP_TO_EDGE
  info.addressModeV = .CLAMP_TO_EDGE
  info.addressModeW = .CLAMP_TO_EDGE
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &manager.linear_clamp_sampler,
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
    &manager.nearest_repeat_sampler,
  ) or_return
  info.addressModeU = .CLAMP_TO_EDGE
  info.addressModeV = .CLAMP_TO_EDGE
  info.addressModeW = .CLAMP_TO_EDGE
  vk.CreateSampler(
    gctx.device,
    &info,
    nil,
    &manager.nearest_clamp_sampler,
  ) or_return
  return .SUCCESS
}

init_bone_matrix_allocator :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  cont.slab_init(
    &manager.bone_matrix_slab,
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
    manager.bone_matrix_slab.capacity,
  )
  manager.bone_buffer = gpu.malloc_mutable_buffer(
    gctx,
    matrix[4, 4]f32,
    int(manager.bone_matrix_slab.capacity),
    {.STORAGE_BUFFER},
  ) or_return
  skinning_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX},
    },
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(skinning_bindings),
      pBindings = raw_data(skinning_bindings[:]),
    },
    nil,
    &manager.bone_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gctx.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &manager.bone_buffer_set_layout,
    },
    &manager.bone_buffer_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = manager.bone_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = manager.bone_buffer_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
  return .SUCCESS
}

init_camera_buffer :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  log.infof(
    "Creating per-frame camera buffers with capacity %d cameras...",
    MAX_ACTIVE_CAMERAS,
  )
  // Create descriptor set layout
  camera_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX, .FRAGMENT, .COMPUTE},
    },
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(camera_bindings),
      pBindings = raw_data(camera_bindings[:]),
    },
    nil,
    &manager.camera_buffer_set_layout,
  ) or_return
  // Create per-frame buffers and descriptor sets
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    manager.camera_buffers[frame_idx] = gpu.create_mutable_buffer(
      gctx,
      CameraData,
      MAX_ACTIVE_CAMERAS,
      {.STORAGE_BUFFER},
      nil,
    ) or_return
    // Allocate descriptor set
    vk.AllocateDescriptorSets(
      gctx.device,
      &{
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = gctx.descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &manager.camera_buffer_set_layout,
      },
      &manager.camera_buffer_descriptor_sets[frame_idx],
    ) or_return
    // Update descriptor set
    buffer_info := vk.DescriptorBufferInfo {
      buffer = manager.camera_buffers[frame_idx].buffer,
      offset = 0,
      range  = vk.DeviceSize(vk.WHOLE_SIZE),
    }
    write := vk.WriteDescriptorSet {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = manager.camera_buffer_descriptor_sets[frame_idx],
      dstBinding      = 0,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo     = &buffer_info,
    }
    vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
  }
  log.infof("Camera buffers initialized successfully")
  return .SUCCESS
}

init_material_buffer :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  log.infof(
    "Creating material buffer with capacity %d materials...",
    MAX_MATERIALS,
  )
  manager.material_buffer = gpu.malloc_mutable_buffer(
    gctx,
    MaterialData,
    MAX_MATERIALS,
    {.STORAGE_BUFFER},
  ) or_return
  material_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX, .FRAGMENT},
    },
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(material_bindings),
      pBindings = raw_data(material_bindings[:]),
    },
    nil,
    &manager.material_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gctx.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &manager.material_buffer_set_layout,
    },
    &manager.material_buffer_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = manager.material_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = manager.material_buffer_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
  return .SUCCESS
}

destroy_material_buffer :: proc(gctx: ^gpu.GPUContext, manager: ^Manager) {
  gpu.mutable_buffer_destroy(gctx.device, &manager.material_buffer)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.material_buffer_set_layout,
    nil,
  )
  manager.material_buffer_set_layout = 0
}

init_world_matrix_buffers :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  log.infof(
    "Creating world matrix buffer with capacity %d nodes...",
    MAX_NODES_IN_SCENE,
  )
  manager.world_matrix_buffer = gpu.malloc_mutable_buffer(
    gctx,
    matrix[4, 4]f32,
    MAX_NODES_IN_SCENE,
    {.STORAGE_BUFFER},
  ) or_return
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX, .FRAGMENT, .COMPUTE},
    },
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &manager.world_matrix_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gctx.device,
    &vk.DescriptorSetAllocateInfo {
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &manager.world_matrix_buffer_set_layout,
    },
    &manager.world_matrix_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = manager.world_matrix_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = manager.world_matrix_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
  return .SUCCESS
}

destroy_world_matrix_buffers :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) {
  gpu.mutable_buffer_destroy(gctx.device, &manager.world_matrix_buffer)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.world_matrix_buffer_set_layout,
    nil,
  )
  manager.world_matrix_buffer_set_layout = 0
  manager.world_matrix_descriptor_set = 0
}

init_node_data_buffer :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  log.infof(
    "Creating node data buffer with capacity %d nodes...",
    MAX_NODES_IN_SCENE,
  )
  manager.node_data_buffer = gpu.malloc_mutable_buffer(
    gctx,
    NodeData,
    MAX_NODES_IN_SCENE,
    {.STORAGE_BUFFER},
  ) or_return
  node_slice := gpu.mutable_buffer_get_all(&manager.node_data_buffer)
  slice.fill(
    node_slice,
    NodeData {
      material_id = 0xFFFFFFFF,
      mesh_id = 0xFFFFFFFF,
      attachment_data_index = 0xFFFFFFFF,
    },
  )
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX, .FRAGMENT},
    },
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &manager.node_data_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gctx.device,
    &vk.DescriptorSetAllocateInfo {
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &manager.node_data_buffer_set_layout,
    },
    &manager.node_data_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = manager.node_data_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = manager.node_data_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
  return .SUCCESS
}

destroy_node_data_buffer :: proc(gctx: ^gpu.GPUContext, manager: ^Manager) {
  gpu.mutable_buffer_destroy(gctx.device, &manager.node_data_buffer)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.node_data_buffer_set_layout,
    nil,
  )
  manager.node_data_buffer_set_layout = 0
  manager.node_data_descriptor_set = 0
}

init_mesh_data_buffer :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  log.infof("Creating mesh data buffer with capacity %d meshes...", MAX_MESHES)
  manager.mesh_data_buffer = gpu.malloc_mutable_buffer(
    gctx,
    MeshData,
    MAX_MESHES,
    {.STORAGE_BUFFER},
  ) or_return
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX},
    },
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &manager.mesh_data_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gctx.device,
    &vk.DescriptorSetAllocateInfo {
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &manager.mesh_data_buffer_set_layout,
    },
    &manager.mesh_data_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = manager.mesh_data_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = manager.mesh_data_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
  return .SUCCESS
}

init_emitter_buffer :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  log.info("Creating emitter buffer for bindless access")
  manager.emitter_buffer = gpu.malloc_mutable_buffer(
    gctx,
    EmitterData,
    MAX_EMITTERS,
    {.STORAGE_BUFFER},
  ) or_return
  emitters := gpu.mutable_buffer_get_all(&manager.emitter_buffer)
  for &emitter in emitters do emitter = {}
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &manager.emitter_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gctx.device,
    &vk.DescriptorSetAllocateInfo {
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &manager.emitter_buffer_set_layout,
    },
    &manager.emitter_buffer_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = manager.emitter_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = manager.emitter_buffer_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
  return .SUCCESS
}

init_lights_buffer :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  log.info("Creating lights buffer for bindless access")
  manager.lights_buffer = gpu.malloc_mutable_buffer(
    gctx,
    LightData,
    MAX_LIGHTS,
    {.STORAGE_BUFFER},
  ) or_return
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX, .FRAGMENT},
    },
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &manager.lights_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gctx.device,
    &vk.DescriptorSetAllocateInfo {
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &manager.lights_buffer_set_layout,
    },
    &manager.lights_buffer_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = manager.lights_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = manager.lights_buffer_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
  return .SUCCESS
}

destroy_lights_buffer :: proc(gctx: ^gpu.GPUContext, manager: ^Manager) {
  gpu.mutable_buffer_destroy(gctx.device, &manager.lights_buffer)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.lights_buffer_set_layout,
    nil,
  )
  manager.lights_buffer_set_layout = 0
  manager.lights_buffer_descriptor_set = 0
}

init_dynamic_light_data_buffers :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  log.info("Creating per-frame dynamic light data buffers")
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    manager.dynamic_light_data_buffers[frame_idx] = gpu.malloc_mutable_buffer(
      gctx,
      DynamicLightData,
      MAX_LIGHTS,
      {.STORAGE_BUFFER},
    ) or_return
    dynamic_data := gpu.mutable_buffer_get_all(&manager.dynamic_light_data_buffers[frame_idx])
    for &data in dynamic_data {
      data.position = {0, 0, 0, 0}
      data.shadow_map = 0xFFFFFFFF
    }
  }
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &manager.dynamic_light_data_set_layout,
  ) or_return
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    vk.AllocateDescriptorSets(
      gctx.device,
      &vk.DescriptorSetAllocateInfo {
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = gctx.descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &manager.dynamic_light_data_set_layout,
      },
      &manager.dynamic_light_data_descriptor_sets[frame_idx],
    ) or_return
    buffer_info := vk.DescriptorBufferInfo {
      buffer = manager.dynamic_light_data_buffers[frame_idx].buffer,
      offset = 0,
      range  = vk.DeviceSize(vk.WHOLE_SIZE),
    }
    write := vk.WriteDescriptorSet {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = manager.dynamic_light_data_descriptor_sets[frame_idx],
      dstBinding      = 0,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo     = &buffer_info,
    }
    vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
  }
  return .SUCCESS
}

destroy_dynamic_light_data_buffers :: proc(gctx: ^gpu.GPUContext, manager: ^Manager) {
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &manager.dynamic_light_data_buffers[frame_idx])
  }
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.dynamic_light_data_set_layout,
    nil,
  )
  manager.dynamic_light_data_set_layout = 0
}

destroy_emitter_buffer :: proc(gctx: ^gpu.GPUContext, manager: ^Manager) {
  gpu.mutable_buffer_destroy(gctx.device, &manager.emitter_buffer)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.emitter_buffer_set_layout,
    nil,
  )
  manager.emitter_buffer_set_layout = 0
  manager.emitter_buffer_descriptor_set = 0
}

init_forcefield_buffer :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  log.info("Creating forcefield buffer for bindless access")
  manager.forcefield_buffer = gpu.malloc_mutable_buffer(
    gctx,
    ForceFieldData,
    MAX_FORCE_FIELDS,
    {.STORAGE_BUFFER},
  ) or_return
  forcefields := gpu.mutable_buffer_get_all(&manager.forcefield_buffer)
  for &forcefield in forcefields do forcefield = {}
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &manager.forcefield_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gctx.device,
    &vk.DescriptorSetAllocateInfo {
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &manager.forcefield_buffer_set_layout,
    },
    &manager.forcefield_buffer_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = manager.forcefield_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = manager.forcefield_buffer_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
  return .SUCCESS
}

destroy_forcefield_buffer :: proc(gctx: ^gpu.GPUContext, manager: ^Manager) {
  gpu.mutable_buffer_destroy(gctx.device, &manager.forcefield_buffer)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.forcefield_buffer_set_layout,
    nil,
  )
  manager.forcefield_buffer_set_layout = 0
  manager.forcefield_buffer_descriptor_set = 0
}

init_sprite_buffer :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  log.info("Creating sprite buffer for bindless access")
  manager.sprite_buffer = gpu.malloc_mutable_buffer(
    gctx,
    SpriteData,
    MAX_SPRITES,
    {.STORAGE_BUFFER},
  ) or_return
  sprites := gpu.mutable_buffer_get_all(&manager.sprite_buffer)
  for &sprite in sprites do sprite = {}
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX, .FRAGMENT},
    },
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &manager.sprite_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gctx.device,
    &vk.DescriptorSetAllocateInfo {
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &manager.sprite_buffer_set_layout,
    },
    &manager.sprite_buffer_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = manager.sprite_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = manager.sprite_buffer_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
  return .SUCCESS
}

destroy_sprite_buffer :: proc(gctx: ^gpu.GPUContext, manager: ^Manager) {
  gpu.mutable_buffer_destroy(gctx.device, &manager.sprite_buffer)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.sprite_buffer_set_layout,
    nil,
  )
  manager.sprite_buffer_set_layout = 0
  manager.sprite_buffer_descriptor_set = 0
}

destroy_mesh_data_buffer :: proc(gctx: ^gpu.GPUContext, manager: ^Manager) {
  gpu.mutable_buffer_destroy(gctx.device, &manager.mesh_data_buffer)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.mesh_data_buffer_set_layout,
    nil,
  )
  manager.mesh_data_buffer_set_layout = 0
  manager.mesh_data_descriptor_set = 0
}

init_vertex_skinning_buffer :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  skinning_count :=
    BINDLESS_SKINNING_BUFFER_SIZE / size_of(geometry.SkinningData)
  log.infof(
    "Creating vertex skinning buffer with capacity %d entries...",
    skinning_count,
  )
  manager.vertex_skinning_buffer = gpu.malloc_immutable_buffer(
    gctx,
    geometry.SkinningData,
    skinning_count,
    {.STORAGE_BUFFER},
  ) or_return
  cont.slab_init(&manager.vertex_skinning_slab, VERTEX_SLAB_CONFIG)
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX},
    },
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &manager.vertex_skinning_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gctx.device,
    &vk.DescriptorSetAllocateInfo {
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &manager.vertex_skinning_buffer_set_layout,
    },
    &manager.vertex_skinning_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = manager.vertex_skinning_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = manager.vertex_skinning_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
  return .SUCCESS
}

destroy_vertex_skinning_buffer :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) {
  cont.slab_destroy(&manager.vertex_skinning_slab)
  gpu.immutable_buffer_destroy(gctx.device, &manager.vertex_skinning_buffer)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.vertex_skinning_buffer_set_layout,
    nil,
  )
  manager.vertex_skinning_buffer_set_layout = 0
  manager.vertex_skinning_descriptor_set = 0
}

destroy_camera_buffer :: proc(gctx: ^gpu.GPUContext, manager: ^Manager) {
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &manager.camera_buffers[frame_idx])
  }
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.camera_buffer_set_layout,
    nil,
  )
  manager.camera_buffer_set_layout = 0
}

init_spherical_camera_buffer :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  log.infof(
    "Creating per-frame spherical camera buffers with capacity %d cameras...",
    MAX_ACTIVE_CAMERAS,
  )
  // Create descriptor set layout
  camera_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX, .FRAGMENT, .COMPUTE, .GEOMETRY},
    },
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(camera_bindings),
      pBindings = raw_data(camera_bindings[:]),
    },
    nil,
    &manager.spherical_camera_buffer_set_layout,
  ) or_return
  // Create per-frame buffers and descriptor sets
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    manager.spherical_camera_buffers[frame_idx] = gpu.create_mutable_buffer(
      gctx,
      SphericalCameraData,
      MAX_ACTIVE_CAMERAS,
      {.STORAGE_BUFFER},
      nil,
    ) or_return
    // Allocate descriptor set
    vk.AllocateDescriptorSets(
      gctx.device,
      &{
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = gctx.descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &manager.spherical_camera_buffer_set_layout,
      },
      &manager.spherical_camera_buffer_descriptor_sets[frame_idx],
    ) or_return
    // Update descriptor set
    buffer_info := vk.DescriptorBufferInfo {
      buffer = manager.spherical_camera_buffers[frame_idx].buffer,
      offset = 0,
      range  = vk.DeviceSize(vk.WHOLE_SIZE),
    }
    write := vk.WriteDescriptorSet {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = manager.spherical_camera_buffer_descriptor_sets[frame_idx],
      dstBinding      = 0,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo     = &buffer_info,
    }
    vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
  }
  log.infof("Spherical camera buffers initialized successfully")
  return .SUCCESS
}

destroy_spherical_camera_buffer :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) {
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &manager.spherical_camera_buffers[frame_idx])
  }
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.spherical_camera_buffer_set_layout,
    nil,
  )
  manager.spherical_camera_buffer_set_layout = 0
}

destroy_global_samplers :: proc(gctx: ^gpu.GPUContext, manager: ^Manager) {
  vk.DestroySampler(
    gctx.device,
    manager.linear_repeat_sampler,
    nil,
  );manager.linear_repeat_sampler = 0
  vk.DestroySampler(
    gctx.device,
    manager.linear_clamp_sampler,
    nil,
  );manager.linear_clamp_sampler = 0
  vk.DestroySampler(
    gctx.device,
    manager.nearest_repeat_sampler,
    nil,
  );manager.nearest_repeat_sampler = 0
  vk.DestroySampler(
    gctx.device,
    manager.nearest_clamp_sampler,
    nil,
  );manager.nearest_clamp_sampler = 0
}

set_texture_2d_descriptor :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
  index: u32,
  image_view: vk.ImageView,
) {
  if index >= MAX_TEXTURES {
    log.errorf("Index %d out of bounds for bindless textures", index)
    return
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = manager.textures_descriptor_set,
    dstBinding      = 0,
    dstArrayElement = index,
    descriptorType  = .SAMPLED_IMAGE,
    descriptorCount = 1,
    pImageInfo      = &vk.DescriptorImageInfo {
      imageView = image_view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
  }
  vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
}

set_texture_cube_descriptor :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
  index: u32,
  image_view: vk.ImageView,
) {
  if index >= MAX_CUBE_TEXTURES {
    log.errorf("Index %d out of bounds for bindless cube textures", index)
    return
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = manager.textures_descriptor_set,
    dstBinding      = 2,
    dstArrayElement = index,
    descriptorType  = .SAMPLED_IMAGE,
    descriptorCount = 1,
    pImageInfo      = &vk.DescriptorImageInfo {
      imageView = image_view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
  }
  vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
}

destroy_bone_matrix_allocator :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) {
  gpu.mutable_buffer_destroy(gctx.device, &manager.bone_buffer)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    manager.bone_buffer_set_layout,
    nil,
  )
  manager.bone_buffer_set_layout = 0
  manager.bone_buffer_descriptor_set = 0
  cont.slab_destroy(&manager.bone_matrix_slab)
}

init_vertex_index_buffers :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  vertex_count := BINDLESS_VERTEX_BUFFER_SIZE / size_of(geometry.Vertex)
  index_count := BINDLESS_INDEX_BUFFER_SIZE / size_of(u32)
  manager.vertex_buffer = gpu.malloc_immutable_buffer(
    gctx,
    geometry.Vertex,
    vertex_count,
    {.VERTEX_BUFFER},
  ) or_return
  manager.index_buffer = gpu.malloc_immutable_buffer(
    gctx,
    u32,
    index_count,
    {.INDEX_BUFFER},
  ) or_return
  cont.slab_init(&manager.vertex_slab, VERTEX_SLAB_CONFIG)
  cont.slab_init(&manager.index_slab, INDEX_SLAB_CONFIG)
  log.info("Bindless buffer system initialized")
  log.info("Vertex buffer capacity:", vertex_count, "vertices")
  log.info("Index buffer capacity:", index_count, "indices")
  return .SUCCESS
}

destroy_vertex_index_buffers :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) {
  gpu.immutable_buffer_destroy(gctx.device, &manager.vertex_buffer)
  gpu.immutable_buffer_destroy(gctx.device, &manager.index_buffer)
  cont.slab_destroy(&manager.vertex_slab)
  cont.slab_destroy(&manager.index_slab)
}

manager_allocate_vertices :: proc(
  manager: ^Manager,
  gctx: ^gpu.GPUContext,
  vertices: []geometry.Vertex,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  vertex_count := u32(len(vertices))
  offset, ok := cont.slab_alloc(&manager.vertex_slab, vertex_count)
  if !ok {
    log.error("Failed to allocate vertices from slab allocator")
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  ret = gpu.write(gctx, &manager.vertex_buffer, vertices, int(offset))
  if ret != .SUCCESS {
    log.error("Failed to write vertex data to GPU buffer")
    return {}, ret
  }
  return BufferAllocation{offset = offset, count = vertex_count}, .SUCCESS
}

manager_allocate_indices :: proc(
  manager: ^Manager,
  gctx: ^gpu.GPUContext,
  indices: []u32,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  index_count := u32(len(indices))
  offset, ok := cont.slab_alloc(&manager.index_slab, index_count)
  if !ok {
    log.error("Failed to allocate indices from slab allocator")
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  ret = gpu.write(gctx, &manager.index_buffer, indices, int(offset))
  if ret != .SUCCESS {
    log.error("Failed to write index data to GPU buffer")
    return {}, ret
  }
  return BufferAllocation{offset = offset, count = index_count}, .SUCCESS
}

manager_allocate_vertex_skinning :: proc(
  manager: ^Manager,
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
  offset, ok := cont.slab_alloc(&manager.vertex_skinning_slab, skinning_count)
  if !ok {
    log.error("Failed to allocate vertex skinning data from slab allocator")
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  ret = gpu.write(
    gctx,
    &manager.vertex_skinning_buffer,
    skinnings,
    int(offset),
  )
  if ret != .SUCCESS {
    log.error("Failed to write vertex skinning data to GPU buffer")
    return {}, ret
  }
  return BufferAllocation{offset = offset, count = skinning_count}, .SUCCESS
}

manager_free_vertex_skinning :: proc(
  manager: ^Manager,
  allocation: BufferAllocation,
) {
  if allocation.count == 0 {
    return
  }
  cont.slab_free(&manager.vertex_skinning_slab, allocation.offset)
}

manager_free_vertices :: proc(
  manager: ^Manager,
  allocation: BufferAllocation,
) {
  cont.slab_free(&manager.vertex_slab, allocation.offset)
}

manager_free_indices :: proc(manager: ^Manager, allocation: BufferAllocation) {
  cont.slab_free(&manager.index_slab, allocation.offset)
}

create_animation_clip :: proc(
  manager: ^Manager,
  name: string,
  duration: f32,
  channels: []animation.Channel,
) -> (
  handle: Handle,
  clip: ^animation.Clip,
  ret: vk.Result,
) {
  ok: bool
  handle, clip, ok = cont.alloc(&manager.animation_clips)
  if !ok {
    log.error("Failed to allocate animation clip")
    return Handle{}, nil, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  clip.name = name
  clip.duration = duration
  clip.channels = channels
  ret = .SUCCESS
  return
}

create_animation_clip_handle :: proc(
  manager: ^Manager,
  name: string,
  duration: f32,
  channels: []animation.Channel,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_animation_clip(manager, name, duration, channels)
  return h, ret == .SUCCESS
}

init_builtin_materials :: proc(manager: ^Manager) -> vk.Result {
  log.info("Creating builtin materials...")
  colors := [len(Color)][4]f32 {
    {1.0, 1.0, 1.0, 1.0}, // WHITE
    {0.0, 0.0, 0.0, 1.0}, // BLACK
    {0.3, 0.3, 0.3, 1.0}, // GRAY
    {1.0, 0.0, 0.0, 1.0}, // RED
    {0.0, 1.0, 0.0, 1.0}, // GREEN
    {0.0, 0.0, 1.0, 1.0}, // BLUE
    {1.0, 1.0, 0.0, 1.0}, // YELLOW
    {0.0, 1.0, 1.0, 1.0}, // CYAN
    {1.0, 0.0, 1.0, 1.0}, // MAGENTA
  }
  for color, i in colors {
    manager.builtin_materials[i], _, _ = create_material(
      manager,
      {},
      .PBR,
      {},
      {},
      {},
      {},
      {},
      0.0,
      1.0,
      0.0,
      color,
    )
  }
  log.info("Builtin materials created successfully")
  return .SUCCESS
}

init_builtin_meshes :: proc(manager: ^Manager, gctx: ^gpu.GPUContext) -> vk.Result {
  log.info("Creating builtin meshes...")
  manager.builtin_meshes[Primitive.CUBE], _ = create_mesh_handle(
    gctx,
    manager,
    geometry.make_cube(),
  )
  manager.builtin_meshes[Primitive.SPHERE], _ = create_mesh_handle(
    gctx,
    manager,
    geometry.make_sphere(),
  )
  manager.builtin_meshes[Primitive.QUAD], _ = create_mesh_handle(
    gctx,
    manager,
    geometry.make_quad(),
  )
  manager.builtin_meshes[Primitive.CONE], _ = create_mesh_handle(
    gctx,
    manager,
    geometry.make_cone(),
  )
  manager.builtin_meshes[Primitive.CAPSULE], _ = create_mesh_handle(
    gctx,
    manager,
    geometry.make_capsule(),
  )
  manager.builtin_meshes[Primitive.CYLINDER], _ = create_mesh_handle(
    gctx,
    manager,
    geometry.make_cylinder(),
  )
  manager.builtin_meshes[Primitive.TORUS], _ = create_mesh_handle(
    gctx,
    manager,
    geometry.make_torus(),
  )
  log.info("Builtin meshes created successfully")
  return .SUCCESS
}
