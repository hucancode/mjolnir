package resources

import "../animation"
import "core:c"
import "core:log"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "../geometry"
import "../gpu"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

BufferAllocation :: struct {
  offset: u32,
  count:  u32,
}

Manager :: struct {
  // Global samplers
  linear_repeat_sampler:        vk.Sampler,
  linear_clamp_sampler:         vk.Sampler,
  nearest_repeat_sampler:       vk.Sampler,
  nearest_clamp_sampler:        vk.Sampler,

  // Resource pools
  meshes:                       Pool(Mesh),
  materials:                    Pool(Material),
  image_2d_buffers:             Pool(gpu.ImageBuffer),
  image_cube_buffers:           Pool(gpu.CubeImageBuffer),
  cameras:                      Pool(geometry.Camera),
  render_targets:               Pool(RenderTarget),
  emitters:                     Pool(Emitter),
  animation_clips:              Pool(animation.Clip),

  // Navigation system resources
  nav_meshes:                   Pool(NavMesh),
  nav_contexts:                 Pool(NavContext),
  navigation_system:            NavigationSystem,

  // Bone matrix system
  bone_buffer_set_layout:       vk.DescriptorSetLayout,
  bone_buffer_descriptor_sets:  [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  bone_buffers:                 [MAX_FRAMES_IN_FLIGHT]gpu.DataBuffer(matrix[4, 4]f32),
  bone_matrix_slab:             SlabAllocator,

  // Bindless camera buffer system
  camera_buffer_set_layout:     vk.DescriptorSetLayout,
  camera_buffer_descriptor_set: vk.DescriptorSet,
  camera_buffer:                gpu.DataBuffer(CameraData),

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
  vertex_skinning_slab:              SlabAllocator,

  // Bindless texture system
  textures_set_layout:          vk.DescriptorSetLayout,
  textures_descriptor_set:      vk.DescriptorSet,

  // Shared pipeline layout used by geometry-style renderers
  geometry_pipeline_layout:     vk.PipelineLayout,

  // Bindless vertex/index buffer system
  vertex_buffer:                gpu.DataBuffer(geometry.Vertex),
  index_buffer:                 gpu.DataBuffer(u32),
  vertex_slab:                  SlabAllocator,
  index_slab:                   SlabAllocator,

  // Frame-scoped bookkeeping
  current_frame_index:          u32,
  pending_uploads:              [dynamic]UploadRequest,
}

UPLOAD_REQUEST_RESERVE :: 32

FrameContext :: struct {
  frame_index:               u32,
  transfer_command_buffer:   vk.CommandBuffer,
  upload_allocator:          rawptr,
}

StageUploadProc :: #type proc(
  manager: ^Manager,
  gpu_context: ^gpu.GPUContext,
  frame: ^FrameContext,
) -> vk.Result

UploadRequest :: struct {
  execute: StageUploadProc,
  label:   string,
}

init :: proc(
  manager: ^Manager,
  gpu_context: ^gpu.GPUContext,
) -> vk.Result {
  log.infof("Initializing mesh pool... ")
  pool_init(&manager.meshes)
  log.infof("Initializing materials pool... ")
  pool_init(&manager.materials)
  log.infof("Initializing image 2d buffer pool... ")
  pool_init(&manager.image_2d_buffers)
  log.infof("Initializing image cube buffer pool... ")
  pool_init(&manager.image_cube_buffers)
  log.infof("Initializing cameras pool... ")
  pool_init(&manager.cameras)
  log.infof("Initializing render target pool... ")
  pool_init(&manager.render_targets)
  log.infof("Initializing emitter pool... ")
  pool_init(&manager.emitters)
  log.infof("Initializing animation clips pool... ")
  pool_init(&manager.animation_clips)
  log.infof("Initializing navigation mesh pool... ")
  pool_init(&manager.nav_meshes)
  log.infof("Initializing navigation context pool... ")
  pool_init(&manager.nav_contexts)
  log.infof("Initializing navigation system... ")
  manager.navigation_system = {}
  manager.pending_uploads = make([dynamic]UploadRequest, 0, UPLOAD_REQUEST_RESERVE)
  manager.current_frame_index = 0
  log.infof("All resource pools initialized successfully")
  init_global_samplers(gpu_context, manager)
  init_bone_matrix_allocator(gpu_context, manager) or_return
  init_camera_buffer(gpu_context, manager) or_return
  init_material_buffer(gpu_context, manager) or_return
  init_world_matrix_buffers(gpu_context, manager) or_return
  init_node_data_buffer(gpu_context, manager) or_return
  init_mesh_data_buffer(gpu_context, manager) or_return
  init_vertex_skinning_buffer(gpu_context, manager) or_return
  init_emitter_buffer(gpu_context, manager) or_return
  init_bindless_buffers(gpu_context, manager) or_return
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
    &manager.textures_set_layout,
  ) or_return
  layout_result := create_geometry_pipeline_layout(gpu_context, manager)
  if layout_result != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gpu_context.device,
      manager.textures_set_layout,
      nil,
    )
    manager.textures_set_layout = 0
    return layout_result
  }
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gpu_context.descriptor_pool,
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
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = manager.nearest_clamp_sampler},
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = manager.textures_descriptor_set,
      dstBinding = 1,
      dstArrayElement = 1,
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = manager.linear_clamp_sampler},
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = manager.textures_descriptor_set,
      dstBinding = 1,
      dstArrayElement = 2,
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = manager.nearest_repeat_sampler},
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = manager.textures_descriptor_set,
      dstBinding = 1,
      dstArrayElement = 3,
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = manager.linear_repeat_sampler},
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

begin_frame :: proc(
  manager: ^Manager,
  frame: ^FrameContext,
) {
  manager.current_frame_index = frame.frame_index
  delete(manager.pending_uploads)
  manager.pending_uploads = make([dynamic]UploadRequest, 0, UPLOAD_REQUEST_RESERVE)
}

stage_upload :: proc(
  manager: ^Manager,
  request: UploadRequest,
) {
  append(&manager.pending_uploads, request)
}

commit :: proc(
  manager: ^Manager,
  gpu_context: ^gpu.GPUContext,
  frame: ^FrameContext,
) -> vk.Result {
  for request in manager.pending_uploads {
    if request.execute == nil do continue
    request.execute(manager, gpu_context, frame) or_return
  }
  delete(manager.pending_uploads)
  manager.pending_uploads = make([dynamic]UploadRequest, 0, UPLOAD_REQUEST_RESERVE)
  return .SUCCESS
}

shutdown :: proc(
  manager: ^Manager,
  gpu_context: ^gpu.GPUContext,
) {
  destroy_material_buffer(gpu_context, manager)
  destroy_world_matrix_buffers(gpu_context, manager)
  destroy_emitter_buffer(gpu_context, manager)
  // Manually clean up each pool since callbacks can't capture gpu_context
  for &entry in manager.image_2d_buffers.entries {
    if entry.generation > 0 && entry.active {
      gpu.image_buffer_destroy(gpu_context.device, &entry.item)
    }
  }
  delete(manager.image_2d_buffers.entries)
  delete(manager.image_2d_buffers.free_indices)

  for &entry in manager.image_cube_buffers.entries {
    if entry.generation > 0 && entry.active {
      gpu.cube_depth_texture_destroy(gpu_context.device, &entry.item)
    }
  }
  delete(manager.image_cube_buffers.entries)
  delete(manager.image_cube_buffers.free_indices)

  for &entry in manager.meshes.entries {
    if entry.generation > 0 && entry.active {
      mesh_destroy(&entry.item, gpu_context, manager)
    }
  }
  delete(manager.meshes.entries)
  delete(manager.meshes.free_indices)
  // Simple cleanup for pools without GPU resources
  delete(manager.materials.entries)
  delete(manager.materials.free_indices)
  delete(manager.cameras.entries)
  delete(manager.cameras.free_indices)
  delete(manager.emitters.entries)
  delete(manager.emitters.free_indices)
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
  destroy_global_samplers(gpu_context, manager)
  destroy_bone_matrix_allocator(gpu_context, manager)
  destroy_camera_buffer(gpu_context, manager)
  destroy_node_data_buffer(gpu_context, manager)
  destroy_mesh_data_buffer(gpu_context, manager)
  destroy_vertex_skinning_buffer(gpu_context, manager)
  destroy_bindless_buffers(gpu_context, manager)
  vk.DestroyPipelineLayout(
    gpu_context.device,
    manager.geometry_pipeline_layout,
    nil,
  )
  manager.geometry_pipeline_layout = 0
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    manager.textures_set_layout,
    nil,
  )
  manager.textures_set_layout = 0
  manager.textures_descriptor_set = 0
  delete(manager.pending_uploads)
}

create_emitter_handle :: proc(
  manager: ^Manager,
  config: Emitter,
) -> Handle {
  handle, emitter := alloc(&manager.emitters)
  emitter^ = config
  emitter.node_handle = {}
  emitter.is_dirty = true
  return handle
}

destroy_emitter_handle :: proc(
  manager: ^Manager,
  handle: Handle,
) -> bool {
  _, freed := free(&manager.emitters, handle)
  return freed
}

create_geometry_pipeline_layout :: proc(
  gpu_context: ^gpu.GPUContext,
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
    &manager.geometry_pipeline_layout,
  ) or_return
  return .SUCCESS
}

init_global_samplers :: proc(
  gpu_context: ^gpu.GPUContext,
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
    gpu_context.device,
    &info,
    nil,
    &manager.linear_repeat_sampler,
  ) or_return
  info.addressModeU = .CLAMP_TO_EDGE
  info.addressModeV = .CLAMP_TO_EDGE
  info.addressModeW = .CLAMP_TO_EDGE
  vk.CreateSampler(
    gpu_context.device,
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
    gpu_context.device,
    &info,
    nil,
    &manager.nearest_repeat_sampler,
  ) or_return
  info.addressModeU = .CLAMP_TO_EDGE
  info.addressModeV = .CLAMP_TO_EDGE
  info.addressModeW = .CLAMP_TO_EDGE
  vk.CreateSampler(
    gpu_context.device,
    &info,
    nil,
    &manager.nearest_clamp_sampler,
  ) or_return
  return .SUCCESS
}

init_bone_matrix_allocator :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  slab_allocator_init(
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
    "Creating bone matrices array with capacity %d matrices per frame, %d frames...",
    manager.bone_matrix_slab.capacity,
    MAX_FRAMES_IN_FLIGHT,
  )
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    manager.bone_buffers[frame_idx] = gpu.create_host_visible_buffer(
      gpu_context,
      matrix[4, 4]f32,
      int(manager.bone_matrix_slab.capacity),
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
    &manager.bone_buffer_set_layout,
  ) or_return
  layouts : [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT do layouts[i] = manager.bone_buffer_set_layout
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gpu_context.descriptor_pool,
      descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
      pSetLayouts = raw_data(layouts[:]),
    },
    raw_data(manager.bone_buffer_descriptor_sets[:]),
  ) or_return
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    buffer_info := vk.DescriptorBufferInfo {
      buffer = manager.bone_buffers[frame_idx].buffer,
      offset = 0,
      range  = vk.DeviceSize(vk.WHOLE_SIZE),
    }
    write := vk.WriteDescriptorSet {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = manager.bone_buffer_descriptor_sets[frame_idx],
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
  manager: ^Manager,
) -> vk.Result {
  log.infof(
    "Creating camera buffer with capacity %d cameras...",
    MAX_ACTIVE_CAMERAS,
  )

  // Create camera buffer
  manager.camera_buffer = gpu.create_host_visible_buffer(
    gpu_context,
    CameraData,
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
    &manager.camera_buffer_set_layout,
  ) or_return

  // Allocate descriptor set
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &manager.camera_buffer_set_layout,
    },
    &manager.camera_buffer_descriptor_set,
  ) or_return

  // Update descriptor set
  buffer_info := vk.DescriptorBufferInfo {
    buffer = manager.camera_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }

  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = manager.camera_buffer_descriptor_set,
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
  manager: ^Manager,
) -> vk.Result {
  log.infof(
    "Creating material buffer with capacity %d materials...",
    MAX_MATERIALS,
  )
  manager.material_buffer = gpu.create_host_visible_buffer(
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
    &manager.material_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gpu_context.descriptor_pool,
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
  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
  return .SUCCESS
}

destroy_material_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) {
  gpu.data_buffer_destroy(gpu_context.device, &manager.material_buffer)
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    manager.material_buffer_set_layout,
    nil,
  )
  manager.material_buffer_set_layout = 0
}

init_world_matrix_buffers :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  log.infof(
    "Creating world matrix buffers with capacity %d nodes...",
    WORLD_MATRIX_CAPACITY,
  )
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    manager.world_matrix_buffers[frame_idx] = gpu.create_host_visible_buffer(
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
    &manager.world_matrix_buffer_set_layout,
  ) or_return
  layouts := [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout{}
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    layouts[i] = manager.world_matrix_buffer_set_layout
  }
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &vk.DescriptorSetAllocateInfo {
      sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool     = gpu_context.descriptor_pool,
      descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
      pSetLayouts        = raw_data(layouts[:]),
    },
    raw_data(manager.world_matrix_descriptor_sets[:]),
  ) or_return
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    buffer_info := vk.DescriptorBufferInfo {
      buffer = manager.world_matrix_buffers[frame_idx].buffer,
      offset = 0,
      range  = vk.DeviceSize(vk.WHOLE_SIZE),
    }
    write := vk.WriteDescriptorSet {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = manager.world_matrix_descriptor_sets[frame_idx],
      dstBinding      = 0,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo     = &buffer_info,
    }
    vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
  }
  return .SUCCESS
}

destroy_world_matrix_buffers :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) {
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    gpu.data_buffer_destroy(
      gpu_context.device,
      &manager.world_matrix_buffers[frame_idx],
    )
  }
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    manager.world_matrix_buffer_set_layout,
    nil,
  )
  manager.world_matrix_buffer_set_layout = 0
}

init_node_data_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  log.infof(
    "Creating node data buffer with capacity %d nodes...",
    NODE_DATA_CAPACITY,
  )
  manager.node_data_buffer = gpu.create_host_visible_buffer(
    gpu_context,
    NodeData,
    NODE_DATA_CAPACITY,
    {.STORAGE_BUFFER},
    nil,
  ) or_return
  node_slice := gpu.data_buffer_get_all(&manager.node_data_buffer)
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
    &manager.node_data_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &vk.DescriptorSetAllocateInfo {
      sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool     = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts        = &manager.node_data_buffer_set_layout,
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
  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
  return .SUCCESS
}

destroy_node_data_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) {
  gpu.data_buffer_destroy(gpu_context.device, &manager.node_data_buffer)
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    manager.node_data_buffer_set_layout,
    nil,
  )
  manager.node_data_buffer_set_layout = 0
  manager.node_data_descriptor_set = 0
}

init_mesh_data_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  log.infof(
    "Creating mesh data buffer with capacity %d meshes...",
    MAX_MESHES,
  )
  manager.mesh_data_buffer = gpu.create_host_visible_buffer(
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
    &manager.mesh_data_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &vk.DescriptorSetAllocateInfo {
      sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool     = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts        = &manager.mesh_data_buffer_set_layout,
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
  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
  return .SUCCESS
}

init_emitter_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  log.info("Creating emitter buffer for bindless access")
  manager.emitter_buffer = gpu.create_host_visible_buffer(
    gpu_context,
    EmitterData,
    MAX_EMITTERS,
    {.STORAGE_BUFFER},
    nil,
  ) or_return
  emitters := gpu.data_buffer_get_all(&manager.emitter_buffer)
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
    &manager.emitter_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &vk.DescriptorSetAllocateInfo {
      sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool     = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts        = &manager.emitter_buffer_set_layout,
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
  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
  return .SUCCESS
}

destroy_emitter_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) {
  gpu.data_buffer_destroy(gpu_context.device, &manager.emitter_buffer)
  if manager.emitter_buffer_set_layout != 0 {
    vk.DestroyDescriptorSetLayout(
      gpu_context.device,
      manager.emitter_buffer_set_layout,
      nil,
    )
  }
  manager.emitter_buffer_set_layout = 0
  manager.emitter_buffer_descriptor_set = 0
}

destroy_mesh_data_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) {
  gpu.data_buffer_destroy(gpu_context.device, &manager.mesh_data_buffer)
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    manager.mesh_data_buffer_set_layout,
    nil,
  )
  manager.mesh_data_buffer_set_layout = 0
  manager.mesh_data_descriptor_set = 0
}

init_vertex_skinning_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) -> vk.Result {
  skinning_count := BINDLESS_SKINNING_BUFFER_SIZE / size_of(geometry.SkinningData)
  log.infof(
    "Creating vertex skinning buffer with capacity %d entries...",
    skinning_count,
  )
  manager.vertex_skinning_buffer = gpu.create_host_visible_buffer(
    gpu_context,
    geometry.SkinningData,
    skinning_count,
    {.STORAGE_BUFFER},
    nil,
  ) or_return
  slab_allocator_init(&manager.vertex_skinning_slab, VERTEX_SLAB_CONFIG)
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
    &manager.vertex_skinning_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &vk.DescriptorSetAllocateInfo {
      sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool     = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts        = &manager.vertex_skinning_buffer_set_layout,
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
  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
  return .SUCCESS
}

destroy_vertex_skinning_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) {
  slab_allocator_destroy(&manager.vertex_skinning_slab)
  gpu.data_buffer_destroy(gpu_context.device, &manager.vertex_skinning_buffer)
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    manager.vertex_skinning_buffer_set_layout,
    nil,
  )
  manager.vertex_skinning_buffer_set_layout = 0
  manager.vertex_skinning_descriptor_set = 0
}

// Get mutable reference to camera uniform in bindless buffer
get_camera_data :: proc(
  manager: ^Manager,
  camera_index: u32,
) -> ^CameraData {
  if camera_index >= MAX_ACTIVE_CAMERAS {
    return nil
  }
  return gpu.data_buffer_get(&manager.camera_buffer, camera_index)
}

destroy_camera_buffer :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) {
  gpu.data_buffer_destroy(gpu_context.device, &manager.camera_buffer)
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    manager.camera_buffer_set_layout,
    nil,
  )
  manager.camera_buffer_set_layout = 0
}

destroy_global_samplers :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) {
  vk.DestroySampler(
    gpu_context.device,
    manager.linear_repeat_sampler,
    nil,
  );manager.linear_repeat_sampler = 0
  vk.DestroySampler(
    gpu_context.device,
    manager.linear_clamp_sampler,
    nil,
  );manager.linear_clamp_sampler = 0
  vk.DestroySampler(
    gpu_context.device,
    manager.nearest_repeat_sampler,
    nil,
  );manager.nearest_repeat_sampler = 0
  vk.DestroySampler(
    gpu_context.device,
    manager.nearest_clamp_sampler,
    nil,
  );manager.nearest_clamp_sampler = 0
}

set_texture_2d_descriptor :: proc(
  gpu_context: ^gpu.GPUContext,
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
  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
}

set_texture_cube_descriptor :: proc(
  gpu_context: ^gpu.GPUContext,
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
  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)
}

create_empty_texture_2d :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  width, height: u32,
  format: vk.Format,
  usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT, .SAMPLED},
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = alloc(&manager.image_2d_buffers)
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
    gpu_context.device,
    texture.image,
    format,
    aspect_mask,
  ) or_return
  set_texture_2d_descriptor(gpu_context, manager, handle.index, texture.view)
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
  manager: ^Manager,
  size: u32,
  format: vk.Format = .D32_SFLOAT,
  usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
) -> (
  handle: Handle,
  texture: ^gpu.CubeImageBuffer,
  ret: vk.Result,
) {
  handle, texture = alloc(&manager.image_cube_buffers)
  gpu.cube_depth_texture_init(
    gpu_context,
    texture,
    size,
    format,
    usage,
  ) or_return
  set_texture_cube_descriptor(
    gpu_context,
    manager,
    handle.index,
    texture.view,
  )
  ret = .SUCCESS
  return
}

destroy_bone_matrix_allocator :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) {
  for &b in manager.bone_buffers {
      gpu.data_buffer_destroy(gpu_context.device, &b)
  }
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    manager.bone_buffer_set_layout,
    nil,
  )
  manager.bone_buffer_set_layout = 0
  slab_allocator_destroy(&manager.bone_matrix_slab)
}

WORLD_MATRIX_CAPACITY :: MAX_NODES_IN_SCENE
NODE_DATA_CAPACITY :: MAX_NODES_IN_SCENE

BINDLESS_VERTEX_BUFFER_SIZE :: 128 * 1024 * 1024 // 128MB
BINDLESS_INDEX_BUFFER_SIZE :: 64 * 1024 * 1024 // 64MB
BINDLESS_SKINNING_BUFFER_SIZE :: 128 * 1024 * 1024 // 128MB

// Configuration for different allocation sizes
// Total capacity: 256*512 + 1024*256 + 4096*128 + 16384*64 + 65536*16 + 262144*4 + 1048576*1 + 0*0 = 2,097,152 vertices
VERTEX_SLAB_CONFIG :: [MAX_SLAB_CLASSES]struct {
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
INDEX_SLAB_CONFIG :: [MAX_SLAB_CLASSES]struct {
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
  manager: ^Manager,
) -> vk.Result {
  vertex_count := BINDLESS_VERTEX_BUFFER_SIZE / size_of(geometry.Vertex)
  index_count := BINDLESS_INDEX_BUFFER_SIZE / size_of(u32)
  manager.vertex_buffer = gpu.create_host_visible_buffer(
    gpu_context,
    geometry.Vertex,
    vertex_count,
    {.VERTEX_BUFFER},
  ) or_return
  manager.index_buffer = gpu.create_host_visible_buffer(
    gpu_context,
    u32,
    index_count,
    {.INDEX_BUFFER},
  ) or_return
  slab_allocator_init(&manager.vertex_slab, VERTEX_SLAB_CONFIG)
  slab_allocator_init(&manager.index_slab, INDEX_SLAB_CONFIG)
  log.info("Bindless buffer system initialized")
  log.info("Vertex buffer capacity:", vertex_count, "vertices")
  log.info("Index buffer capacity:", index_count, "indices")
  return .SUCCESS
}

destroy_bindless_buffers :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
) {
  gpu.data_buffer_destroy(gpu_context.device, &manager.vertex_buffer)
  gpu.data_buffer_destroy(gpu_context.device, &manager.index_buffer)
  slab_allocator_destroy(&manager.vertex_slab)
  slab_allocator_destroy(&manager.index_slab)
}

manager_allocate_vertices :: proc(
  manager: ^Manager,
  vertices: []geometry.Vertex,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  vertex_count := u32(len(vertices))
  offset, ok := slab_alloc(&manager.vertex_slab, vertex_count)
  if !ok {
    log.error("Failed to allocate vertices from slab allocator")
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  ret = gpu.data_buffer_write(&manager.vertex_buffer, vertices, int(offset))
  if ret != .SUCCESS {
    log.error("Failed to write vertex data to GPU buffer")
    return {}, ret
  }
  return BufferAllocation{offset = offset, count = vertex_count}, .SUCCESS
}

manager_allocate_indices :: proc(
  manager: ^Manager,
  indices: []u32,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  index_count := u32(len(indices))
  offset, ok := slab_alloc(&manager.index_slab, index_count)
  if !ok {
    log.error("Failed to allocate indices from slab allocator")
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  ret = gpu.data_buffer_write(&manager.index_buffer, indices, int(offset))
  if ret != .SUCCESS {
    log.error("Failed to write index data to GPU buffer")
    return {}, ret
  }
  return BufferAllocation{offset = offset, count = index_count}, .SUCCESS
}

manager_allocate_vertex_skinning :: proc(
  manager: ^Manager,
  skinnings: []geometry.SkinningData,
) -> (
  allocation: BufferAllocation,
  ret: vk.Result,
) {
  if len(skinnings) == 0 {
    return {}, .SUCCESS
  }
  skinning_count := u32(len(skinnings))
  offset, ok := slab_alloc(&manager.vertex_skinning_slab, skinning_count)
  if !ok {
    log.error("Failed to allocate vertex skinning data from slab allocator")
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  ret = gpu.data_buffer_write(
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
  slab_free(&manager.vertex_skinning_slab, allocation.offset)
}

manager_free_vertices :: proc(
  manager: ^Manager,
  allocation: BufferAllocation,
) {
  slab_free(&manager.vertex_slab, allocation.offset)
}

manager_free_indices :: proc(
  manager: ^Manager,
  allocation: BufferAllocation,
) {
  slab_free(&manager.index_slab, allocation.offset)
}

create_mesh :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  data: geometry.Geometry,
) -> (
  handle: Handle,
  mesh: ^Mesh,
  ret: vk.Result,
) {
  handle, mesh = alloc(&manager.meshes)
  ret = mesh_init(mesh, gpu_context, manager, data)
  if ret != .SUCCESS {
    return
  }
  ret = mesh_write_to_gpu(manager, handle, mesh)
  return
}

create_mesh_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  data: geometry.Geometry,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_mesh(gpu_context, manager, data)
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
  manager: ^Manager,
  handle: Handle,
  mesh: ^Mesh,
) -> vk.Result {
  if handle.index >= MAX_MESHES {
    log.errorf("Mesh index %d exceeds capacity %d", handle.index, MAX_MESHES)
    return .ERROR_OUT_OF_DEVICE_MEMORY
  }
  data := mesh_data_from_mesh(mesh)
  return gpu.data_buffer_write_single(
    &manager.mesh_data_buffer,
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
  manager: ^Manager,
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
    &manager.material_buffer,
    &data,
    int(handle.index),
  ) or_return
  return .SUCCESS
}

sync_material_gpu_data :: proc(
  manager: ^Manager,
  handle: Handle,
) -> vk.Result {
  mat, ok := get(manager.materials, handle)
  if !ok {
    log.errorf("Invalid material handle %v", handle)
    return .ERROR_UNKNOWN
  }
  return material_write_to_gpu(manager, handle, mat)
}

create_material :: proc(
  manager: ^Manager,
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
  ret, mat = alloc(&manager.materials)
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
  res = material_write_to_gpu(manager, ret, mat)
  return
}

create_material_handle :: proc(
  manager: ^Manager,
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
    manager,
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
  manager: ^Manager,
  path: string,
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = alloc(&manager.image_2d_buffers)
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
  set_texture_2d_descriptor(gpu_context, manager, handle.index, texture.view)
  ret = .SUCCESS
  return handle, texture, ret
}

create_hdr_texture_from_path :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  path: string,
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = alloc(&manager.image_2d_buffers)
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
  set_texture_2d_descriptor(gpu_context, manager, handle.index, texture.view)
  ret = .SUCCESS
  return handle, texture, ret
}

create_texture_from_pixels :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  pixels: []u8,
  width: int,
  height: int,
  channel: int,
  format: vk.Format = .R8G8B8A8_SRGB,
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = alloc(&manager.image_2d_buffers)
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
  set_texture_2d_descriptor(gpu_context, manager, handle.index, texture.view)
  ret = .SUCCESS
  return
}

create_texture_from_data :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  data: []u8,
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = alloc(&manager.image_2d_buffers)
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
  set_texture_2d_descriptor(gpu_context, manager, handle.index, texture.view)
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
  defer gpu.data_buffer_destroy(gpu_context.device, &staging)

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
    gpu_context.device,
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
  manager: ^Manager,
  path: string,
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = alloc(&manager.image_2d_buffers)
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
  set_texture_2d_descriptor(gpu_context, manager, handle.index, texture.view)
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
  manager: ^Manager,
  width, height: u32,
  format: vk.Format,
  usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT, .SAMPLED},
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_empty_texture_2d(
    gpu_context,
    manager,
    width,
    height,
    format,
    usage,
  )
  return h, ret == .SUCCESS
}

create_texture_from_path_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  path: string,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_texture_from_path(gpu_context, manager, path)
  return h, ret == .SUCCESS
}

create_texture_from_data_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  data: []u8,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_texture_from_data(gpu_context, manager, data)
  return h, ret == .SUCCESS
}

create_texture_from_pixels_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
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
    manager,
    pixels,
    width,
    height,
    channel,
    format,
  )
  return h, ret == .SUCCESS
}

get_render_target :: proc(
  manager: ^Manager,
  handle: Handle,
) -> (
  ret: ^RenderTarget,
  ok: bool,
) #optional_ok {
  ret, ok = get(manager.render_targets, handle)
  return
}

get_mesh :: proc(
  manager: ^Manager,
  handle: Handle,
) -> (
  ret: ^Mesh,
  ok: bool,
) #optional_ok {
  ret, ok = get(manager.meshes, handle)
  return
}

get_material :: proc(
  manager: ^Manager,
  handle: Handle,
) -> (
  ret: ^Material,
  ok: bool,
) #optional_ok {
  ret, ok = get(manager.materials, handle)
  return
}

get_image_2d :: proc(
  manager: ^Manager,
  handle: Handle,
) -> (
  ret: ^gpu.ImageBuffer,
  ok: bool,
) #optional_ok {
  ret, ok = get(manager.image_2d_buffers, handle)
  return
}

get_image_cube :: proc(
  manager: ^Manager,
  handle: Handle,
) -> (
  ret: ^gpu.CubeImageBuffer,
  ok: bool,
) #optional_ok {
  ret, ok = get(manager.image_cube_buffers, handle)
  return
}

get_camera :: proc(
  manager: ^Manager,
  handle: Handle,
) -> (
  ret: ^geometry.Camera,
  ok: bool,
) #optional_ok {
  ret, ok = get(manager.cameras, handle)
  return
}

get_navmesh :: proc(
  manager: ^Manager,
  handle: Handle,
) -> (
  ret: ^NavMesh,
  ok: bool,
) #optional_ok {
  ret, ok = get(manager.nav_meshes, handle)
  return
}

get_nav_context :: proc(
  manager: ^Manager,
  handle: Handle,
) -> (
  ret: ^NavContext,
  ok: bool,
) #optional_ok {
  ret, ok = get(manager.nav_contexts, handle)
  return
}

get_animation_clip :: proc(
  manager: ^Manager,
  handle: Handle,
) -> (
  ret: ^animation.Clip,
  ok: bool,
) #optional_ok {
  ret, ok = get(manager.animation_clips, handle)
  return
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
  handle, clip = alloc(&manager.animation_clips)
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
