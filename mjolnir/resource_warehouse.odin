package mjolnir

import "animation"
import "core:c"
import "core:log"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "geometry"
import "gpu"
import "resource"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

BufferAllocation :: struct {
  offset: u32,
  count:  u32,
}

ResourceWarehouse :: struct {
  // Global samplers
  linear_repeat_sampler:        vk.Sampler,
  linear_clamp_sampler:         vk.Sampler,
  nearest_repeat_sampler:       vk.Sampler,
  nearest_clamp_sampler:        vk.Sampler,

  // Resource pools
  meshes:                       resource.Pool(Mesh),
  materials:                    resource.Pool(Material),
  image_2d_buffers:             resource.Pool(gpu.ImageBuffer),
  image_cube_buffers:           resource.Pool(gpu.CubeImageBuffer),
  cameras:                      resource.Pool(geometry.Camera),
  render_targets:               resource.Pool(RenderTarget),
  emitters:                     resource.Pool(Emitter),
  animation_clips:              resource.Pool(animation.Clip),

  // Navigation system resources
  nav_meshes:                   resource.Pool(NavMesh),
  nav_contexts:                 resource.Pool(NavContext),
  navigation_system:            NavigationSystem,

  // Bone matrix system
  bone_buffer_set_layout:       vk.DescriptorSetLayout,
  bone_buffer_descriptor_sets:  [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  bone_buffers:                 [MAX_FRAMES_IN_FLIGHT]gpu.DataBuffer(matrix[4, 4]f32),
  bone_matrix_slab:             resource.SlabAllocator,

  // Bindless camera buffer system
  camera_buffer_set_layout:     vk.DescriptorSetLayout,
  camera_buffer_descriptor_set: vk.DescriptorSet,
  camera_buffer:                gpu.DataBuffer(CameraUniform),

  // Bindless material buffer system
  material_buffer_set_layout:     vk.DescriptorSetLayout,
  material_buffer_descriptor_set: vk.DescriptorSet,
  material_buffer:                gpu.DataBuffer(MaterialData),

  // Bindless world matrix buffer system
  world_matrix_buffer_set_layout:   vk.DescriptorSetLayout,
  world_matrix_descriptor_sets:     [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  world_matrix_buffers:             [MAX_FRAMES_IN_FLIGHT]gpu.DataBuffer(matrix[4, 4]f32),

  // Bindless node data buffer system
  node_data_buffer_set_layout:    vk.DescriptorSetLayout,
  node_data_descriptor_set:       vk.DescriptorSet,
  node_data_buffer:               gpu.DataBuffer(NodeData),

  // Bindless mesh data buffer system
  mesh_data_buffer_set_layout:    vk.DescriptorSetLayout,
  mesh_data_descriptor_set:       vk.DescriptorSet,
  mesh_data_buffer:               gpu.DataBuffer(MeshData),

  // Bindless emitter buffer system
  emitter_buffer_set_layout:      vk.DescriptorSetLayout,
  emitter_buffer_descriptor_set:  vk.DescriptorSet,
  emitter_buffer:                 gpu.DataBuffer(EmitterData),

  // Bindless vertex skinning buffer system
  vertex_skinning_buffer_set_layout: vk.DescriptorSetLayout,
  vertex_skinning_descriptor_set:    vk.DescriptorSet,
  vertex_skinning_buffer:            gpu.DataBuffer(geometry.SkinningData),
  vertex_skinning_slab:              resource.SlabAllocator,
  vertex_skinning_data:              []geometry.SkinningData,

  // Bindless texture system
  textures_set_layout:          vk.DescriptorSetLayout,
  textures_descriptor_set:      vk.DescriptorSet,

  // Shared pipeline layout used by geometry-style renderers
  geometry_pipeline_layout:     vk.PipelineLayout,

  // Bindless vertex/index buffer system
  vertex_buffer:                gpu.DataBuffer(geometry.Vertex),
  index_buffer:                 gpu.DataBuffer(u32),
  vertex_slab:                  resource.SlabAllocator,
  index_slab:                   resource.SlabAllocator,
  vertex_data:                  []geometry.Vertex,
  index_data:                   []u32,
}

resource_init :: proc(
  warehouse: ^ResourceWarehouse,
  gpu_context: ^gpu.GPUContext,
) -> vk.Result {
  log.infof("Initializing mesh pool... ")
  resource.pool_init(&warehouse.meshes)
  log.infof("Initializing materials pool... ")
  resource.pool_init(&warehouse.materials)
  log.infof("Initializing image 2d buffer pool... ")
  resource.pool_init(&warehouse.image_2d_buffers)
  log.infof("Initializing image cube buffer pool... ")
  resource.pool_init(&warehouse.image_cube_buffers)
  log.infof("Initializing cameras pool... ")
  resource.pool_init(&warehouse.cameras)
  log.infof("Initializing render target pool... ")
  resource.pool_init(&warehouse.render_targets)
  log.infof("Initializing emitter pool... ")
  resource.pool_init(&warehouse.emitters)
  log.infof("Initializing animation clips pool... ")
  resource.pool_init(&warehouse.animation_clips)
  log.infof("Initializing navigation mesh pool... ")
  resource.pool_init(&warehouse.nav_meshes)
  log.infof("Initializing navigation context pool... ")
  resource.pool_init(&warehouse.nav_contexts)
  log.infof("Initializing navigation system... ")
  warehouse.navigation_system = {}
  log.infof("All resource pools initialized successfully")
  init_global_samplers(gpu_context, warehouse)
  init_bone_matrix_allocator(gpu_context, warehouse) or_return
  init_camera_buffer(gpu_context, warehouse) or_return
  init_material_buffer(gpu_context, warehouse) or_return
  init_world_matrix_buffers(gpu_context, warehouse) or_return
  init_node_data_buffer(gpu_context, warehouse) or_return
  init_mesh_data_buffer(gpu_context, warehouse) or_return
  init_vertex_skinning_buffer(gpu_context, warehouse) or_return
  init_emitter_buffer(gpu_context, warehouse) or_return
  init_bindless_buffers(gpu_context, warehouse) or_return
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
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(textures_bindings),
      pBindings = raw_data(textures_bindings[:]),
    },
    nil,
    &warehouse.textures_set_layout,
  ) or_return
  layout_result := create_geometry_pipeline_layout(gpu_context, warehouse)
  if layout_result != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gpu_context.device,
      warehouse.textures_set_layout,
      nil,
    )
    warehouse.textures_set_layout = 0
    return layout_result
  }
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &warehouse.textures_set_layout,
    },
    &warehouse.textures_descriptor_set,
  ) or_return
  writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = warehouse.textures_descriptor_set,
      dstBinding = 1,
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = warehouse.nearest_clamp_sampler},
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = warehouse.textures_descriptor_set,
      dstBinding = 1,
      dstArrayElement = 1,
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = warehouse.linear_clamp_sampler},
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = warehouse.textures_descriptor_set,
      dstBinding = 1,
      dstArrayElement = 2,
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = warehouse.nearest_repeat_sampler},
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = warehouse.textures_descriptor_set,
      dstBinding = 1,
      dstArrayElement = 3,
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = warehouse.linear_repeat_sampler},
    },
  }
  vk.UpdateDescriptorSets(
    gpu_context.device,
    len(writes),
    raw_data(writes[:]),
    0,
    nil,
  )
  return .SUCCESS
}

resource_deinit :: proc(
  warehouse: ^ResourceWarehouse,
  gpu_context: ^gpu.GPUContext,
) {
  deinit_material_buffer(gpu_context, warehouse)
  deinit_world_matrix_buffers(gpu_context, warehouse)
  deinit_emitter_buffer(gpu_context, warehouse)
  // Manually clean up each pool since callbacks can't capture gpu_context
  for &entry in warehouse.image_2d_buffers.entries {
    if entry.generation > 0 && entry.active {
      gpu.image_buffer_deinit(gpu_context, &entry.item)
    }
  }
  delete(warehouse.image_2d_buffers.entries)
  delete(warehouse.image_2d_buffers.free_indices)

  for &entry in warehouse.image_cube_buffers.entries {
    if entry.generation > 0 && entry.active {
      gpu.cube_depth_texture_deinit(gpu_context, &entry.item)
    }
  }
  delete(warehouse.image_cube_buffers.entries)
  delete(warehouse.image_cube_buffers.free_indices)

  for &entry in warehouse.meshes.entries {
    if entry.generation > 0 && entry.active {
      mesh_deinit(&entry.item, gpu_context, warehouse)
    }
  }
  delete(warehouse.meshes.entries)
  delete(warehouse.meshes.free_indices)
  // Simple cleanup for pools without GPU resources
  delete(warehouse.materials.entries)
  delete(warehouse.materials.free_indices)
  delete(warehouse.cameras.entries)
  delete(warehouse.cameras.free_indices)
  delete(warehouse.emitters.entries)
  delete(warehouse.emitters.free_indices)
  for &entry in warehouse.animation_clips.entries {
    if entry.generation > 0 && entry.active {
      animation.clip_deinit(&entry.item)
    }
  }
  delete(warehouse.animation_clips.entries)
  delete(warehouse.animation_clips.free_indices)
  // Navigation system cleanup
  for &entry in warehouse.nav_meshes.entries {
    if entry.generation > 0 && entry.active {
      // Clean up navigation mesh
      // TODO: detour mesh cleanup would be added here if needed
    }
  }
  delete(warehouse.nav_meshes.entries)
  delete(warehouse.nav_meshes.free_indices)

  for &entry in warehouse.nav_contexts.entries {
    if entry.generation > 0 && entry.active {
      // Clean up navigation contexts
      // TODO: context cleanup would be added here if needed
    }
  }
  delete(warehouse.nav_contexts.entries)
  delete(warehouse.nav_contexts.free_indices)

  // Clean up navigation system
  delete(warehouse.navigation_system.geometry_cache)
  delete(warehouse.navigation_system.dirty_tiles)
  deinit_global_samplers(gpu_context, warehouse)
  deinit_bone_matrix_allocator(gpu_context, warehouse)
  deinit_camera_buffer(gpu_context, warehouse)
  deinit_node_data_buffer(gpu_context, warehouse)
  deinit_mesh_data_buffer(gpu_context, warehouse)
  deinit_vertex_skinning_buffer(gpu_context, warehouse)
  deinit_bindless_buffers(gpu_context, warehouse)
  vk.DestroyPipelineLayout(
    gpu_context.device,
    warehouse.geometry_pipeline_layout,
    nil,
  )
  warehouse.geometry_pipeline_layout = 0
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    warehouse.textures_set_layout,
    nil,
  )
  warehouse.textures_set_layout = 0
  warehouse.textures_descriptor_set = 0
}

create_emitter_handle :: proc(
  warehouse: ^ResourceWarehouse,
  config: Emitter,
) -> Handle {
  handle, emitter := resource.alloc(&warehouse.emitters)
  emitter^ = config
  emitter.dirty = true
  return handle
}

destroy_emitter_handle :: proc(
  warehouse: ^ResourceWarehouse,
  handle: Handle,
) -> bool {
  _, freed := resource.free(&warehouse.emitters, handle)
  return freed
}

create_geometry_pipeline_layout :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX, .FRAGMENT},
    size       = size_of(PushConstant),
  }
  set_layouts := [?]vk.DescriptorSetLayout {
    warehouse.camera_buffer_set_layout,
    warehouse.textures_set_layout,
    warehouse.bone_buffer_set_layout,
    warehouse.material_buffer_set_layout,
    warehouse.world_matrix_buffer_set_layout,
    warehouse.node_data_buffer_set_layout,
    warehouse.mesh_data_buffer_set_layout,
    warehouse.vertex_skinning_buffer_set_layout,
  }
  vk.CreatePipelineLayout(
    gpu_context.device,
    &vk.PipelineLayoutCreateInfo {
      sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount         = len(set_layouts),
      pSetLayouts            = raw_data(set_layouts[:]),
      pushConstantRangeCount = 1,
      pPushConstantRanges    = &push_constant_range,
    },
    nil,
    &warehouse.geometry_pipeline_layout,
  ) or_return
  return .SUCCESS
}

init_global_samplers :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
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
    gpu_context.device,
    &info,
    nil,
    &warehouse.linear_repeat_sampler,
  ) or_return
  info.addressModeU = .CLAMP_TO_EDGE
  info.addressModeV = .CLAMP_TO_EDGE
  info.addressModeW = .CLAMP_TO_EDGE
  vk.CreateSampler(
    gpu_context.device,
    &info,
    nil,
    &warehouse.linear_clamp_sampler,
  ) or_return
  info.magFilter = .NEAREST
  info.minFilter = .NEAREST
  info.addressModeU = .REPEAT
  info.addressModeV = .REPEAT
  info.addressModeW = .REPEAT
  vk.CreateSampler(
    gpu_context.device,
    &info,
    nil,
    &warehouse.nearest_repeat_sampler,
  ) or_return
  info.addressModeU = .CLAMP_TO_EDGE
  info.addressModeV = .CLAMP_TO_EDGE
  info.addressModeW = .CLAMP_TO_EDGE
  vk.CreateSampler(
    gpu_context.device,
    &info,
    nil,
    &warehouse.nearest_clamp_sampler,
  ) or_return
  return .SUCCESS
}

init_bone_matrix_allocator :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  resource.slab_allocator_init(
    &warehouse.bone_matrix_slab,
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
    "Creating bone matrices array with capacity %d matrices per frame, %d frames...",
    warehouse.bone_matrix_slab.capacity,
    MAX_FRAMES_IN_FLIGHT,
  )
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    warehouse.bone_buffers[frame_idx] = gpu.create_host_visible_buffer(
      gpu_context,
      matrix[4, 4]f32,
      int(warehouse.bone_matrix_slab.capacity),
      {.STORAGE_BUFFER},
      nil,
    ) or_return
  }
  skinning_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX},
    },
  }
  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(skinning_bindings),
      pBindings = raw_data(skinning_bindings[:]),
    },
    nil,
    &warehouse.bone_buffer_set_layout,
  ) or_return
  layouts : [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT do layouts[i] = warehouse.bone_buffer_set_layout
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gpu_context.descriptor_pool,
      descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
      pSetLayouts = raw_data(layouts[:]),
    },
    raw_data(warehouse.bone_buffer_descriptor_sets[:]),
  ) or_return
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    buffer_info := vk.DescriptorBufferInfo {
      buffer = warehouse.bone_buffers[frame_idx].buffer,
      offset = 0,
      range  = vk.DeviceSize(vk.WHOLE_SIZE),
    }
    write := vk.WriteDescriptorSet {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = warehouse.bone_buffer_descriptor_sets[frame_idx],
      dstBinding      = 0,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo     = &buffer_info,
    }
    vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
  }

  return .SUCCESS
}

init_camera_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  log.infof(
    "Creating camera buffer with capacity %d cameras...",
    MAX_ACTIVE_CAMERAS,
  )

  // Create camera buffer
  warehouse.camera_buffer = gpu.create_host_visible_buffer(
    gpu_context,
    CameraUniform,
    MAX_ACTIVE_CAMERAS,
    {.STORAGE_BUFFER},
    nil,
  ) or_return

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
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(camera_bindings),
      pBindings = raw_data(camera_bindings[:]),
    },
    nil,
    &warehouse.camera_buffer_set_layout,
  ) or_return

  // Allocate descriptor set
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &warehouse.camera_buffer_set_layout,
    },
    &warehouse.camera_buffer_descriptor_set,
  ) or_return

  // Update descriptor set
  buffer_info := vk.DescriptorBufferInfo {
    buffer = warehouse.camera_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }

  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = warehouse.camera_buffer_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }

  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)

  log.infof("Camera buffer initialized successfully")
  return .SUCCESS
}

init_material_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  log.infof(
    "Creating material buffer with capacity %d materials...",
    MAX_MATERIALS,
  )
  warehouse.material_buffer = gpu.create_host_visible_buffer(
    gpu_context,
    MaterialData,
    MAX_MATERIALS,
    {.STORAGE_BUFFER},
    nil,
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
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(material_bindings),
      pBindings = raw_data(material_bindings[:]),
    },
    nil,
    &warehouse.material_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &warehouse.material_buffer_set_layout,
    },
    &warehouse.material_buffer_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = warehouse.material_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = warehouse.material_buffer_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
  return .SUCCESS
}

deinit_material_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) {
  gpu.data_buffer_deinit(gpu_context, &warehouse.material_buffer)
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    warehouse.material_buffer_set_layout,
    nil,
  )
  warehouse.material_buffer_set_layout = 0
}

init_world_matrix_buffers :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  log.infof(
    "Creating world matrix buffers with capacity %d nodes...",
    WORLD_MATRIX_CAPACITY,
  )
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    warehouse.world_matrix_buffers[frame_idx] = gpu.create_host_visible_buffer(
      gpu_context,
      matrix[4, 4]f32,
      WORLD_MATRIX_CAPACITY,
      {.STORAGE_BUFFER},
      nil,
    ) or_return
  }
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX, .FRAGMENT, .COMPUTE},
    },
  }
  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &warehouse.world_matrix_buffer_set_layout,
  ) or_return
  layouts := [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout{}
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    layouts[i] = warehouse.world_matrix_buffer_set_layout
  }
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &vk.DescriptorSetAllocateInfo {
      sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool     = gpu_context.descriptor_pool,
      descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
      pSetLayouts        = raw_data(layouts[:]),
    },
    raw_data(warehouse.world_matrix_descriptor_sets[:]),
  ) or_return
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    buffer_info := vk.DescriptorBufferInfo {
      buffer = warehouse.world_matrix_buffers[frame_idx].buffer,
      offset = 0,
      range  = vk.DeviceSize(vk.WHOLE_SIZE),
    }
    write := vk.WriteDescriptorSet {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = warehouse.world_matrix_descriptor_sets[frame_idx],
      dstBinding      = 0,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo     = &buffer_info,
    }
    vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
  }
  return .SUCCESS
}

deinit_world_matrix_buffers :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) {
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    gpu.data_buffer_deinit(
      gpu_context,
      &warehouse.world_matrix_buffers[frame_idx],
    )
  }
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    warehouse.world_matrix_buffer_set_layout,
    nil,
  )
  warehouse.world_matrix_buffer_set_layout = 0
}

init_node_data_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  log.infof(
    "Creating node data buffer with capacity %d nodes...",
    NODE_DATA_CAPACITY,
  )
  warehouse.node_data_buffer = gpu.create_host_visible_buffer(
    gpu_context,
    NodeData,
    NODE_DATA_CAPACITY,
    {.STORAGE_BUFFER},
    nil,
  ) or_return
  node_slice := gpu.data_buffer_get_all(&warehouse.node_data_buffer)
  default_node := NodeData {
    material_id        = 0xFFFFFFFF,
    mesh_id            = 0xFFFFFFFF,
    bone_matrix_offset = 0xFFFFFFFF,
  }
  for &node in node_slice do node = default_node
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX, .FRAGMENT},
    },
  }
  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &warehouse.node_data_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &vk.DescriptorSetAllocateInfo {
      sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool     = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts        = &warehouse.node_data_buffer_set_layout,
    },
    &warehouse.node_data_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = warehouse.node_data_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = warehouse.node_data_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
  return .SUCCESS
}

deinit_node_data_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) {
  gpu.data_buffer_deinit(gpu_context, &warehouse.node_data_buffer)
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    warehouse.node_data_buffer_set_layout,
    nil,
  )
  warehouse.node_data_buffer_set_layout = 0
  warehouse.node_data_descriptor_set = 0
}

init_mesh_data_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  log.infof(
    "Creating mesh data buffer with capacity %d meshes...",
    MAX_MESHES,
  )
  warehouse.mesh_data_buffer = gpu.create_host_visible_buffer(
    gpu_context,
    MeshData,
    MAX_MESHES,
    {.STORAGE_BUFFER},
    nil,
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
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &warehouse.mesh_data_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &vk.DescriptorSetAllocateInfo {
      sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool     = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts        = &warehouse.mesh_data_buffer_set_layout,
    },
    &warehouse.mesh_data_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = warehouse.mesh_data_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = warehouse.mesh_data_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
  return .SUCCESS
}

init_emitter_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  log.info("Creating emitter buffer for bindless access")
  warehouse.emitter_buffer = gpu.create_host_visible_buffer(
    gpu_context,
    EmitterData,
    MAX_EMITTERS,
    {.STORAGE_BUFFER},
    nil,
  ) or_return
  emitters := gpu.data_buffer_get_all(&warehouse.emitter_buffer)
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
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &warehouse.emitter_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &vk.DescriptorSetAllocateInfo {
      sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool     = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts        = &warehouse.emitter_buffer_set_layout,
    },
    &warehouse.emitter_buffer_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = warehouse.emitter_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = warehouse.emitter_buffer_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
  return .SUCCESS
}

deinit_emitter_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) {
  gpu.data_buffer_deinit(gpu_context, &warehouse.emitter_buffer)
  if warehouse.emitter_buffer_set_layout != 0 {
    vk.DestroyDescriptorSetLayout(
      gpu_context.device,
      warehouse.emitter_buffer_set_layout,
      nil,
    )
  }
  warehouse.emitter_buffer_set_layout = 0
  warehouse.emitter_buffer_descriptor_set = 0
}

deinit_mesh_data_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) {
  gpu.data_buffer_deinit(gpu_context, &warehouse.mesh_data_buffer)
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    warehouse.mesh_data_buffer_set_layout,
    nil,
  )
  warehouse.mesh_data_buffer_set_layout = 0
  warehouse.mesh_data_descriptor_set = 0
}

init_vertex_skinning_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  skinning_count := BINDLESS_SKINNING_BUFFER_SIZE / size_of(geometry.SkinningData)
  log.infof(
    "Creating vertex skinning buffer with capacity %d entries...",
    skinning_count,
  )
  warehouse.vertex_skinning_buffer = gpu.create_host_visible_buffer(
    gpu_context,
    geometry.SkinningData,
    skinning_count,
    {.STORAGE_BUFFER},
    nil,
  ) or_return
  warehouse.vertex_skinning_data =
    warehouse.vertex_skinning_buffer.mapped[:skinning_count]
  resource.slab_allocator_init(&warehouse.vertex_skinning_slab, VERTEX_SLAB_CONFIG)
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX},
    },
  }
  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &warehouse.vertex_skinning_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &vk.DescriptorSetAllocateInfo {
      sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool     = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts        = &warehouse.vertex_skinning_buffer_set_layout,
    },
    &warehouse.vertex_skinning_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = warehouse.vertex_skinning_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = warehouse.vertex_skinning_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
  return .SUCCESS
}

deinit_vertex_skinning_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) {
  warehouse.vertex_skinning_data = nil
  resource.slab_allocator_deinit(&warehouse.vertex_skinning_slab)
  gpu.data_buffer_deinit(gpu_context, &warehouse.vertex_skinning_buffer)
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    warehouse.vertex_skinning_buffer_set_layout,
    nil,
  )
  warehouse.vertex_skinning_buffer_set_layout = 0
  warehouse.vertex_skinning_descriptor_set = 0
}

// Get mutable reference to camera uniform in bindless buffer
get_camera_uniform :: proc(
  warehouse: ^ResourceWarehouse,
  camera_index: u32,
) -> ^CameraUniform {
  if camera_index >= MAX_ACTIVE_CAMERAS {
    return nil
  }
  return gpu.data_buffer_get(&warehouse.camera_buffer, camera_index)
}

deinit_camera_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) {
  gpu.data_buffer_deinit(gpu_context, &warehouse.camera_buffer)
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    warehouse.camera_buffer_set_layout,
    nil,
  )
  warehouse.camera_buffer_set_layout = 0
}

deinit_global_samplers :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) {
  vk.DestroySampler(
    gpu_context.device,
    warehouse.linear_repeat_sampler,
    nil,
  );warehouse.linear_repeat_sampler = 0
  vk.DestroySampler(
    gpu_context.device,
    warehouse.linear_clamp_sampler,
    nil,
  );warehouse.linear_clamp_sampler = 0
  vk.DestroySampler(
    gpu_context.device,
    warehouse.nearest_repeat_sampler,
    nil,
  );warehouse.nearest_repeat_sampler = 0
  vk.DestroySampler(
    gpu_context.device,
    warehouse.nearest_clamp_sampler,
    nil,
  );warehouse.nearest_clamp_sampler = 0
}

set_texture_2d_descriptor :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  index: u32,
  image_view: vk.ImageView,
) {
  if index >= MAX_TEXTURES {
    log.errorf("Index %d out of bounds for bindless textures", index)
    return
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = warehouse.textures_descriptor_set,
    dstBinding      = 0,
    dstArrayElement = index,
    descriptorType  = .SAMPLED_IMAGE,
    descriptorCount = 1,
    pImageInfo      = &vk.DescriptorImageInfo {
      imageView = image_view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
  }
  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
}

set_texture_cube_descriptor :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  index: u32,
  image_view: vk.ImageView,
) {
  if index >= MAX_CUBE_TEXTURES {
    log.errorf("Index %d out of bounds for bindless cube textures", index)
    return
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = warehouse.textures_descriptor_set,
    dstBinding      = 2,
    dstArrayElement = index,
    descriptorType  = .SAMPLED_IMAGE,
    descriptorCount = 1,
    pImageInfo      = &vk.DescriptorImageInfo {
      imageView = image_view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
  }
  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
}

create_empty_texture_2d :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  width, height: u32,
  format: vk.Format,
  usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT, .SAMPLED},
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&warehouse.image_2d_buffers)
  texture^ = gpu.malloc_image_buffer(
    gpu_context,
    width,
    height,
    format,
    .OPTIMAL,
    usage,
    {.DEVICE_LOCAL},
  ) or_return

  // Determine aspect mask based on format
  aspect_mask := vk.ImageAspectFlags{.COLOR}
  if format == .D32_SFLOAT ||
     format == .D24_UNORM_S8_UINT ||
     format == .D16_UNORM {
    aspect_mask = {.DEPTH}
  }

  texture.view = gpu.create_image_view(
    gpu_context,
    texture.image,
    format,
    aspect_mask,
  ) or_return
  set_texture_2d_descriptor(gpu_context, warehouse, handle.index, texture.view)
  ret = .SUCCESS
  log.debugf(
    "created empty texture %d x %d %v 0x%x",
    width,
    height,
    format,
    texture.image,
  )
  return
}

create_empty_texture_cube :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  size: u32,
  format: vk.Format = .D32_SFLOAT,
  usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
) -> (
  handle: Handle,
  texture: ^gpu.CubeImageBuffer,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&warehouse.image_cube_buffers)
  gpu.cube_depth_texture_init(
    gpu_context,
    texture,
    size,
    format,
    usage,
  ) or_return
  set_texture_cube_descriptor(
    gpu_context,
    warehouse,
    handle.index,
    texture.view,
  )
  ret = .SUCCESS
  return
}

deinit_bone_matrix_allocator :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) {
  for &b in warehouse.bone_buffers {
      gpu.data_buffer_deinit(gpu_context, &b)
  }
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    warehouse.bone_buffer_set_layout,
    nil,
  )
  warehouse.bone_buffer_set_layout = 0
  resource.slab_allocator_deinit(&warehouse.bone_matrix_slab)
}

WORLD_MATRIX_CAPACITY :: MAX_NODES_IN_SCENE
NODE_DATA_CAPACITY :: MAX_NODES_IN_SCENE

BINDLESS_VERTEX_BUFFER_SIZE :: 128 * 1024 * 1024 // 128MB
BINDLESS_INDEX_BUFFER_SIZE :: 64 * 1024 * 1024 // 64MB
BINDLESS_SKINNING_BUFFER_SIZE :: 128 * 1024 * 1024 // 128MB

// Configuration for different allocation sizes
// Total capacity: 256*512 + 1024*256 + 4096*128 + 16384*64 + 65536*16 + 262144*4 + 1048576*1 + 0*0 = 2,097,152 vertices
VERTEX_SLAB_CONFIG :: [resource.MAX_SLAB_CLASSES]struct {
  block_size, block_count: u32,
} {
  {block_size = 256, block_count = 512}, // Small meshes: 131,072 vertices
  {block_size = 1024, block_count = 256}, // Medium meshes: 262,144 vertices
  {block_size = 4096, block_count = 128}, // Large meshes: 524,288 vertices
  {block_size = 16384, block_count = 64}, // Very large meshes: 1,048,576 vertices
  {block_size = 65536, block_count = 16}, // Huge meshes: 1,048,576 vertices
  {block_size = 262144, block_count = 4}, // Massive meshes: 1,048,576 vertices
  {block_size = 1048576, block_count = 1}, // Giant meshes: 1,048,576 vertices
  {block_size = 0, block_count = 0}, // Unused - disabled to fit within buffer
}

// Total capacity: 128*2048 + 512*1024 + 2048*512 + 8192*256 + 32768*128 + 131072*32 + 524288*8 + 2097152*4 = 16,777,216 indices
INDEX_SLAB_CONFIG :: [resource.MAX_SLAB_CLASSES]struct {
  block_size, block_count: u32,
} {
  {block_size = 128, block_count = 2048}, // Small index counts: 262,144 indices
  {block_size = 512, block_count = 1024}, // Medium index counts: 524,288 indices
  {block_size = 2048, block_count = 512}, // Large index counts: 1,048,576 indices
  {block_size = 8192, block_count = 256}, // Very large index counts: 2,097,152 indices
  {block_size = 32768, block_count = 128}, // Huge index counts: 4,194,304 indices
  {block_size = 131072, block_count = 32}, // Massive index counts: 4,194,304 indices
  {block_size = 524288, block_count = 8}, // Giant index counts: 4,194,304 indices
  {block_size = 2097152, block_count = 4}, // Enormous index counts: 8,388,608 indices
}

init_bindless_buffers :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  vertex_count := BINDLESS_VERTEX_BUFFER_SIZE / size_of(geometry.Vertex)
  index_count := BINDLESS_INDEX_BUFFER_SIZE / size_of(u32)
  warehouse.vertex_buffer = gpu.malloc_host_visible_buffer(
    gpu_context,
    geometry.Vertex,
    vertex_count,
    {.VERTEX_BUFFER},
  ) or_return
  warehouse.index_buffer = gpu.malloc_host_visible_buffer(
    gpu_context,
    u32,
    index_count,
    {.INDEX_BUFFER},
  ) or_return
  vertex_data_ptr: rawptr
  vk.MapMemory(
    gpu_context.device,
    warehouse.vertex_buffer.memory,
    0,
    vk.DeviceSize(vk.WHOLE_SIZE),
    {},
    &vertex_data_ptr,
  ) or_return
  warehouse.vertex_data = ([^]geometry.Vertex)(vertex_data_ptr)[:vertex_count]
  index_data_ptr: rawptr
  vk.MapMemory(
    gpu_context.device,
    warehouse.index_buffer.memory,
    0,
    vk.DeviceSize(vk.WHOLE_SIZE),
    {},
    &index_data_ptr,
  ) or_return
  warehouse.index_data = ([^]u32)(index_data_ptr)[:index_count]
  resource.slab_allocator_init(&warehouse.vertex_slab, VERTEX_SLAB_CONFIG)
  resource.slab_allocator_init(&warehouse.index_slab, INDEX_SLAB_CONFIG)
  log.info("Bindless buffer system initialized")
  log.info("Vertex buffer capacity:", vertex_count, "vertices")
  log.info("Index buffer capacity:", index_count, "indices")
  return .SUCCESS
}

deinit_bindless_buffers :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) {
  if warehouse.vertex_buffer.memory != 0 {
    vk.UnmapMemory(gpu_context.device, warehouse.vertex_buffer.memory)
  }
  if warehouse.index_buffer.memory != 0 {
    vk.UnmapMemory(gpu_context.device, warehouse.index_buffer.memory)
  }
  gpu.data_buffer_deinit(gpu_context, &warehouse.vertex_buffer)
  gpu.data_buffer_deinit(gpu_context, &warehouse.index_buffer)
  resource.slab_allocator_deinit(&warehouse.vertex_slab)
  resource.slab_allocator_deinit(&warehouse.index_slab)
}

warehouse_allocate_vertices :: proc(
  warehouse: ^ResourceWarehouse,
  vertices: []geometry.Vertex,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  vertex_count := u32(len(vertices))
  offset, ok := resource.slab_alloc(&warehouse.vertex_slab, vertex_count)
  if !ok {
    log.error("Failed to allocate vertices from slab allocator")
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  if offset + vertex_count > u32(len(warehouse.vertex_data)) {
    log.error("Vertex buffer overflow")
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  copy(warehouse.vertex_data[offset:offset + vertex_count], vertices)
  return BufferAllocation{offset = offset, count = vertex_count}, .SUCCESS
}

warehouse_allocate_indices :: proc(
  warehouse: ^ResourceWarehouse,
  indices: []u32,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  index_count := u32(len(indices))
  offset, ok := resource.slab_alloc(&warehouse.index_slab, index_count)
  if !ok {
    log.error("Failed to allocate indices from slab allocator")
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }

  if offset + index_count > u32(len(warehouse.index_data)) {
    log.error("Index buffer overflow")
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }

  copy(warehouse.index_data[offset:offset + index_count], indices)
  return BufferAllocation{offset = offset, count = index_count}, .SUCCESS
}

warehouse_allocate_vertex_skinning :: proc(
  warehouse: ^ResourceWarehouse,
  skinnings: []geometry.SkinningData,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  if len(skinnings) == 0 {
    return {}, .SUCCESS
  }
  skinning_count := u32(len(skinnings))
  offset, ok := resource.slab_alloc(&warehouse.vertex_skinning_slab, skinning_count)
  if !ok {
    log.error("Failed to allocate vertex skinning data from slab allocator")
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  if offset + skinning_count > u32(len(warehouse.vertex_skinning_data)) {
    log.error("Vertex skinning buffer overflow")
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  copy(
    warehouse.vertex_skinning_data[offset:offset + skinning_count],
    skinnings,
  )
  return BufferAllocation{offset = offset, count = skinning_count}, .SUCCESS
}

warehouse_free_vertex_skinning :: proc(
  warehouse: ^ResourceWarehouse,
  allocation: BufferAllocation,
) {
  if allocation.count == 0 {
    return
  }
  resource.slab_free(&warehouse.vertex_skinning_slab, allocation.offset)
}

warehouse_free_vertices :: proc(
  warehouse: ^ResourceWarehouse,
  allocation: BufferAllocation,
) {
  resource.slab_free(&warehouse.vertex_slab, allocation.offset)
}

warehouse_free_indices :: proc(
  warehouse: ^ResourceWarehouse,
  allocation: BufferAllocation,
) {
  resource.slab_free(&warehouse.index_slab, allocation.offset)
}

create_mesh :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  data: geometry.Geometry,
) -> (
  handle: Handle,
  mesh: ^Mesh,
  ret: vk.Result,
) {
  handle, mesh = resource.alloc(&warehouse.meshes)
  ret = mesh_init(mesh, gpu_context, warehouse, data)
  if ret != .SUCCESS {
    return
  }
  ret = mesh_write_to_gpu(warehouse, handle, mesh)
  return
}

create_mesh_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  data: geometry.Geometry,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_mesh(gpu_context, warehouse, data)
  return h, ret == .SUCCESS
}

mesh_data_from_mesh :: proc(mesh: ^Mesh) -> MeshData {
  skin_offset: u32
  flags: MeshFlagSet
  skin, has_skin := mesh.skinning.?
  if has_skin && skin.vertex_skinning_allocation.count > 0 {
    flags |= {.SKINNED}
    skin_offset = skin.vertex_skinning_allocation.offset
  }
  return MeshData {
    aabb_min              = mesh.aabb.min,
    index_count           = mesh.index_allocation.count,
    aabb_max              = mesh.aabb.max,
    first_index           = mesh.index_allocation.offset,
    vertex_offset         = cast(i32)mesh.vertex_allocation.offset,
    vertex_skinning_offset = skin_offset,
    flags                 = flags,
  }
}

mesh_write_to_gpu :: proc(
  warehouse: ^ResourceWarehouse,
  handle: Handle,
  mesh: ^Mesh,
) -> vk.Result {
  if handle.index >= MAX_MESHES {
    log.errorf("Mesh index %d exceeds capacity %d", handle.index, MAX_MESHES)
    return .ERROR_OUT_OF_DEVICE_MEMORY
  }
  data := mesh_data_from_mesh(mesh)
  return gpu.data_buffer_write_single(
    &warehouse.mesh_data_buffer,
    &data,
    int(handle.index),
  )
}

material_data_from_material :: proc(mat: ^Material) -> MaterialData {
  return MaterialData {
    albedo_index             = min(MAX_TEXTURES - 1, mat.albedo.index),
    metallic_roughness_index = min(
      MAX_TEXTURES - 1,
      mat.metallic_roughness.index,
    ),
    normal_index             = min(MAX_TEXTURES - 1, mat.normal.index),
    emissive_index           = min(MAX_TEXTURES - 1, mat.emissive.index),
    metallic_value           = mat.metallic_value,
    roughness_value          = mat.roughness_value,
    emissive_value           = mat.emissive_value,
    features                 = mat.features,
    base_color_factor        = mat.base_color_factor,
  }
}

material_write_to_gpu :: proc(
  warehouse: ^ResourceWarehouse,
  handle: Handle,
  mat: ^Material,
) -> vk.Result {
  if handle.index >= MAX_MATERIALS {
    log.errorf(
      "Material index %d exceeds capacity %d",
      handle.index,
      MAX_MATERIALS,
    )
    return .ERROR_OUT_OF_DEVICE_MEMORY
  }
  data := material_data_from_material(mat)
  gpu.data_buffer_write(
    &warehouse.material_buffer,
    &data,
    int(handle.index),
  ) or_return
  return .SUCCESS
}

sync_material_gpu_data :: proc(
  warehouse: ^ResourceWarehouse,
  handle: Handle,
) -> vk.Result {
  mat, ok := resource.get(warehouse.materials, handle)
  if !ok {
    log.errorf("Invalid material handle %v", handle)
    return .ERROR_UNKNOWN
  }
  return material_write_to_gpu(warehouse, handle, mat)
}

create_material :: proc(
  warehouse: ^ResourceWarehouse,
  features: ShaderFeatureSet = {},
  type: MaterialType = .PBR,
  albedo_handle: Handle = {},
  metallic_roughness_handle: Handle = {},
  normal_handle: Handle = {},
  emissive_handle: Handle = {},
  occlusion_handle: Handle = {},
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: f32 = 0.0,
  base_color_factor: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (
  ret: Handle,
  mat: ^Material,
  res: vk.Result,
) {
  ret, mat = resource.alloc(&warehouse.materials)
  mat.type = type
  mat.features = features
  mat.albedo = albedo_handle
  mat.metallic_roughness = metallic_roughness_handle
  mat.normal = normal_handle
  mat.emissive = emissive_handle
  mat.occlusion = occlusion_handle
  mat.metallic_value = metallic_value
  mat.roughness_value = roughness_value
  mat.emissive_value = emissive_value
  mat.base_color_factor = base_color_factor
  log.infof(
    "Material created: albedo=%d metallic_roughness=%d normal=%d emissive=%d",
    mat.albedo.index,
    mat.metallic_roughness.index,
    mat.normal.index,
    mat.emissive.index,
  )
  res = material_write_to_gpu(warehouse, ret, mat)
  return
}

create_material_handle :: proc(
  warehouse: ^ResourceWarehouse,
  features: ShaderFeatureSet = {},
  type: MaterialType = .PBR,
  albedo_handle: Handle = {},
  metallic_roughness_handle: Handle = {},
  normal_handle: Handle = {},
  emissive_handle: Handle = {},
  occlusion_handle: Handle = {},
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: f32 = 0.0,
  base_color_factor: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_material(
    warehouse,
    features,
    type,
    albedo_handle,
    metallic_roughness_handle,
    normal_handle,
    emissive_handle,
    occlusion_handle,
    metallic_value,
    roughness_value,
    emissive_value,
    base_color_factor,
  )
  return h, ret == .SUCCESS
}

create_texture :: proc {
  create_empty_texture_2d,
  create_texture_from_path,
  create_texture_from_data,
  create_texture_from_pixels,
}

// Grouped cube texture creation procedures
create_cube_texture :: proc {
  create_empty_texture_cube,
}

create_texture_from_path :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  path: string,
) -> (
  handle: resource.Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&warehouse.image_2d_buffers)
  width, height, c_in_file: c.int
  path_cstr := strings.clone_to_cstring(path)
  pixels := stbi.load(path_cstr, &width, &height, &c_in_file, 4)
  if pixels == nil {
    log.errorf(
      "Failed to load texture from path '%s': %s\n",
      path,
      stbi.failure_reason(),
    )
    ret = .ERROR_UNKNOWN
    return handle, texture, ret
  }
  defer stbi.image_free(pixels)
  num_pixels := int(width * height * 4)
  texture^ = gpu.create_image_buffer(
    gpu_context,
    pixels,
    size_of(u8) * vk.DeviceSize(num_pixels),
    .R8G8B8A8_SRGB,
    u32(width),
    u32(height),
  ) or_return
  set_texture_2d_descriptor(gpu_context, warehouse, handle.index, texture.view)
  ret = .SUCCESS
  return handle, texture, ret
}

create_hdr_texture_from_path :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  path: string,
) -> (
  handle: resource.Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&warehouse.image_2d_buffers)
  path_cstr := strings.clone_to_cstring(path)
  width, height, c_in_file: c.int
  actual_channels: c.int = 4 // we always want RGBA for HDR
  float_pixels := stbi.loadf(
    path_cstr,
    &width,
    &height,
    &c_in_file,
    actual_channels,
  )
  if float_pixels == nil {
    log.errorf(
      "Failed to load HDR texture from path '%s': %s\n",
      path,
      stbi.failure_reason(),
    )
    ret = .ERROR_UNKNOWN
    return handle, texture, ret
  }
  defer stbi.image_free(float_pixels)
  num_floats := int(width * height * actual_channels)
  texture^ = gpu.create_image_buffer(
    gpu_context,
    float_pixels,
    size_of(f32) * vk.DeviceSize(num_floats),
    .R32G32B32A32_SFLOAT,
    u32(width),
    u32(height),
  ) or_return
  set_texture_2d_descriptor(gpu_context, warehouse, handle.index, texture.view)
  ret = .SUCCESS
  return handle, texture, ret
}

create_texture_from_pixels :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  pixels: []u8,
  width: int,
  height: int,
  channel: int,
  format: vk.Format = .R8G8B8A8_SRGB,
) -> (
  handle: resource.Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&warehouse.image_2d_buffers)
  texture^ = gpu.create_image_buffer(
    gpu_context,
    raw_data(pixels),
    size_of(u8) * vk.DeviceSize(len(pixels)),
    format,
    u32(width),
    u32(height),
  ) or_return
  log.infof(
    "created texture %d x %d -> id %d",
    texture.width,
    texture.height,
    texture.image,
  )
  set_texture_2d_descriptor(gpu_context, warehouse, handle.index, texture.view)
  ret = .SUCCESS
  return
}

create_texture_from_data :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  data: []u8,
) -> (
  handle: resource.Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&warehouse.image_2d_buffers)
  width, height, ch: c.int
  actual_channels: c.int = 4
  pixels := stbi.load_from_memory(
    raw_data(data),
    c.int(len(data)),
    &width,
    &height,
    &ch,
    actual_channels,
  )
  if pixels == nil {
    log.errorf("Failed to load texture from data: %s\n", stbi.failure_reason())
    ret = .ERROR_UNKNOWN
    return
  }
  bytes_count := int(width * height * actual_channels)
  format: vk.Format
  // for simplicity, we assume the data is in sRGB format
  if actual_channels == 4 {
    format = vk.Format.R8G8B8A8_SRGB
  } else if actual_channels == 3 {
    format = vk.Format.R8G8B8_SRGB
  } else if actual_channels == 1 {
    format = vk.Format.R8_SRGB
  }
  texture^ = gpu.create_image_buffer(
    gpu_context,
    pixels,
    size_of(u8) * vk.DeviceSize(bytes_count),
    format,
    u32(width),
    u32(height),
  ) or_return
  log.infof(
    "created texture %d x %d -> id %d",
    texture.width,
    texture.height,
    texture.image,
  )
  set_texture_2d_descriptor(gpu_context, warehouse, handle.index, texture.view)
  ret = .SUCCESS
  return
}

// Calculate number of mip levels for a given texture size
calculate_mip_levels :: proc(width, height: u32) -> f32 {
  return linalg.floor(linalg.log2(f32(max(width, height)))) + 1
}

// Create image buffer with mip maps
create_image_buffer_with_mips :: proc(
  gpu_context: ^gpu.GPUContext,
  data: rawptr,
  size: vk.DeviceSize,
  format: vk.Format,
  width, height: u32,
) -> (
  img: gpu.ImageBuffer,
  ret: vk.Result,
) {
  mip_levels := u32(calculate_mip_levels(width, height))
  staging := gpu.create_host_visible_buffer(
    gpu_context,
    u8,
    int(size),
    {.TRANSFER_SRC},
    data,
  ) or_return
  defer gpu.data_buffer_deinit(gpu_context, &staging)

  img = gpu.malloc_image_buffer_with_mips(
    gpu_context,
    width,
    height,
    format,
    .OPTIMAL,
    {.TRANSFER_DST, .SAMPLED, .TRANSFER_SRC},
    {.DEVICE_LOCAL},
    mip_levels,
  ) or_return

  gpu.copy_image_for_mips(gpu_context, img, staging) or_return
  gpu.generate_mipmaps(
    gpu_context,
    img,
    format,
    width,
    height,
    mip_levels,
  ) or_return

  aspect_mask := vk.ImageAspectFlags{.COLOR}
  img.view = gpu.create_image_view_with_mips(
    gpu_context,
    img.image,
    format,
    aspect_mask,
    mip_levels,
  ) or_return
  ret = .SUCCESS
  return
}

// Create HDR texture with mip maps
create_hdr_texture_from_path_with_mips :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  path: string,
) -> (
  handle: resource.Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&warehouse.image_2d_buffers)
  path_cstr := strings.clone_to_cstring(path)
  width, height, c_in_file: c.int
  actual_channels: c.int = 4 // we always want RGBA for HDR
  float_pixels := stbi.loadf(
    path_cstr,
    &width,
    &height,
    &c_in_file,
    actual_channels,
  )
  if float_pixels == nil {
    log.errorf(
      "Failed to load HDR texture from path '%s': %s\n",
      path,
      stbi.failure_reason(),
    )
    ret = .ERROR_UNKNOWN
    return handle, texture, ret
  }
  defer stbi.image_free(float_pixels)
  num_floats := int(width * height * actual_channels)
  texture^ = create_image_buffer_with_mips(
    gpu_context,
    float_pixels,
    size_of(f32) * vk.DeviceSize(num_floats),
    .R32G32B32A32_SFLOAT,
    u32(width),
    u32(height),
  ) or_return
  set_texture_2d_descriptor(gpu_context, warehouse, handle.index, texture.view)
  ret = .SUCCESS
  return handle, texture, ret
}

// Handle-only variants for texture creation procedures
create_texture_handle :: proc {
  create_empty_texture_2d_handle,
  create_texture_from_path_handle,
  create_texture_from_data_handle,
  create_texture_from_pixels_handle,
}

create_empty_texture_2d_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  width, height: u32,
  format: vk.Format,
  usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT, .SAMPLED},
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_empty_texture_2d(
    gpu_context,
    warehouse,
    width,
    height,
    format,
    usage,
  )
  return h, ret == .SUCCESS
}

create_texture_from_path_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  path: string,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_texture_from_path(gpu_context, warehouse, path)
  return h, ret == .SUCCESS
}

create_texture_from_data_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  data: []u8,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_texture_from_data(gpu_context, warehouse, data)
  return h, ret == .SUCCESS
}

create_texture_from_pixels_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  pixels: []u8,
  width: int,
  height: int,
  channel: int,
  format: vk.Format = .R8G8B8A8_SRGB,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_texture_from_pixels(
    gpu_context,
    warehouse,
    pixels,
    width,
    height,
    channel,
    format,
  )
  return h, ret == .SUCCESS
}

engine_get_render_target :: proc(
  engine: ^Engine,
  handle: Handle,
) -> (
  ret: ^RenderTarget,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(engine.warehouse.render_targets, handle)
  return
}

warehouse_get_render_target :: proc(
  warehouse: ^ResourceWarehouse,
  handle: Handle,
) -> (
  ret: ^RenderTarget,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(warehouse.render_targets, handle)
  return
}

render_target :: proc {
  engine_get_render_target,
  warehouse_get_render_target,
}

engine_get_mesh :: proc(
  engine: ^Engine,
  handle: Handle,
) -> (
  ret: ^Mesh,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(engine.warehouse.meshes, handle)
  return
}

warehouse_get_mesh :: proc(
  warehouse: ^ResourceWarehouse,
  handle: Handle,
) -> (
  ret: ^Mesh,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(warehouse.meshes, handle)
  return
}

mesh :: proc {
  engine_get_mesh,
  warehouse_get_mesh,
}

engine_get_material :: proc(
  engine: ^Engine,
  handle: Handle,
) -> (
  ret: ^Material,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(engine.warehouse.materials, handle)
  return
}

warehouse_get_material :: proc(
  warehouse: ^ResourceWarehouse,
  handle: Handle,
) -> (
  ret: ^Material,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(warehouse.materials, handle)
  return
}

material :: proc {
  engine_get_material,
  warehouse_get_material,
}

engine_get_image_2d :: proc(
  engine: ^Engine,
  handle: Handle,
) -> (
  ret: ^gpu.ImageBuffer,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(engine.warehouse.image_2d_buffers, handle)
  return
}

warehouse_get_image_2d :: proc(
  warehouse: ^ResourceWarehouse,
  handle: Handle,
) -> (
  ret: ^gpu.ImageBuffer,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(warehouse.image_2d_buffers, handle)
  return
}

image_2d :: proc {
  engine_get_image_2d,
  warehouse_get_image_2d,
}

engine_get_image_cube :: proc(
  engine: ^Engine,
  handle: Handle,
) -> (
  ret: ^gpu.CubeImageBuffer,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(engine.warehouse.image_cube_buffers, handle)
  return
}

warehouse_get_image_cube :: proc(
  warehouse: ^ResourceWarehouse,
  handle: Handle,
) -> (
  ret: ^gpu.CubeImageBuffer,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(warehouse.image_cube_buffers, handle)
  return
}

image_cube :: proc {
  engine_get_image_cube,
  warehouse_get_image_cube,
}

engine_get_camera :: proc(
  engine: ^Engine,
  handle: Handle,
) -> (
  ret: ^geometry.Camera,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(engine.warehouse.cameras, handle)
  return
}

warehouse_get_camera :: proc(
  warehouse: ^ResourceWarehouse,
  handle: Handle,
) -> (
  ret: ^geometry.Camera,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(warehouse.cameras, handle)
  return
}

camera :: proc {
  engine_get_camera,
  warehouse_get_camera,
}

engine_get_navmesh :: proc(
  engine: ^Engine,
  handle: Handle,
) -> (
  ret: ^NavMesh,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(engine.warehouse.nav_meshes, handle)
  return
}

warehouse_get_navmesh :: proc(
  warehouse: ^ResourceWarehouse,
  handle: Handle,
) -> (
  ret: ^NavMesh,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(warehouse.nav_meshes, handle)
  return
}

navmesh :: proc {
  engine_get_navmesh,
  warehouse_get_navmesh,
}

engine_get_nav_context :: proc(
  engine: ^Engine,
  handle: Handle,
) -> (
  ret: ^NavContext,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(engine.warehouse.nav_contexts, handle)
  return
}

warehouse_get_nav_context :: proc(
  warehouse: ^ResourceWarehouse,
  handle: Handle,
) -> (
  ret: ^NavContext,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(warehouse.nav_contexts, handle)
  return
}

nav_context :: proc {
  engine_get_nav_context,
  warehouse_get_nav_context,
}

engine_get_animation_clip :: proc(
  engine: ^Engine,
  handle: Handle,
) -> (
  ret: ^animation.Clip,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(engine.warehouse.animation_clips, handle)
  return
}

warehouse_get_animation_clip :: proc(
  warehouse: ^ResourceWarehouse,
  handle: Handle,
) -> (
  ret: ^animation.Clip,
  ok: bool,
) #optional_ok {
  ret, ok = resource.get(warehouse.animation_clips, handle)
  return
}

animation_clip :: proc {
  engine_get_animation_clip,
  warehouse_get_animation_clip,
}

create_animation_clip :: proc(
  warehouse: ^ResourceWarehouse,
  name: string,
  duration: f32,
  channels: []animation.Channel,
) -> (
  handle: Handle,
  clip: ^animation.Clip,
  ret: vk.Result,
) {
  handle, clip = resource.alloc(&warehouse.animation_clips)
  clip.name = name
  clip.duration = duration
  clip.channels = channels
  ret = .SUCCESS
  return
}

create_animation_clip_handle :: proc(
  warehouse: ^ResourceWarehouse,
  name: string,
  duration: f32,
  channels: []animation.Channel,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_animation_clip(warehouse, name, duration, channels)
  return h, ret == .SUCCESS
}
