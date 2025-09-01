package mjolnir

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

  // Navigation system resources
  nav_meshes:                   resource.Pool(NavMesh),
  nav_contexts:                 resource.Pool(NavContext),
  navigation_system:            NavigationSystem,

  // Bone matrix system
  bone_buffer_set_layout:       vk.DescriptorSetLayout,
  bone_buffer_descriptor_set:   vk.DescriptorSet,
  bone_buffer:                  gpu.DataBuffer(matrix[4, 4]f32),
  bone_matrix_slab:             resource.SlabAllocator,

  // Bindless camera buffer system
  camera_buffer_set_layout:     vk.DescriptorSetLayout,
  camera_buffer_descriptor_set: vk.DescriptorSet,
  camera_buffer:                gpu.DataBuffer(CameraUniform),

  // Dummy skinning buffer for static meshes
  dummy_skinning_buffer:        gpu.DataBuffer(geometry.SkinningData),

  // Bindless texture system
  textures_set_layout:          vk.DescriptorSetLayout,
  textures_descriptor_set:      vk.DescriptorSet,
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
  // Textuwarehouse+samplers descriptor set
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
  gpu.data_buffer_deinit(gpu_context, &warehouse.dummy_skinning_buffer)
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
      mesh_deinit(&entry.item, gpu_context)
    }
  }
  delete(warehouse.meshes.entries)
  delete(warehouse.meshes.free_indices)
  // Simple cleanup for pools without GPU resources
  delete(warehouse.materials.entries)
  delete(warehouse.materials.free_indices)
  delete(warehouse.cameras.entries)
  delete(warehouse.cameras.free_indices)

  // Navigation system cleanup
  for &entry in warehouse.nav_meshes.entries {
    if entry.generation > 0 && entry.active {
      // Clean up navigation mesh
      // Note: detour mesh cleanup would be added here if needed
    }
  }
  delete(warehouse.nav_meshes.entries)
  delete(warehouse.nav_meshes.free_indices)

  for &entry in warehouse.nav_contexts.entries {
    if entry.generation > 0 && entry.active {
      // Clean up navigation contexts
      // Note: context cleanup would be added here if needed
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
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    warehouse.textures_set_layout,
    nil,
  )
  warehouse.textures_set_layout = 0
  warehouse.textures_descriptor_set = 0
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
  // Create bone buffer with space for all frames in flight
  warehouse.bone_buffer, _ = gpu.create_host_visible_buffer(
    gpu_context,
    matrix[4, 4]f32,
    int(warehouse.bone_matrix_slab.capacity) * MAX_FRAMES_IN_FLIGHT,
    {.STORAGE_BUFFER},
    nil,
  )
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
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &warehouse.bone_buffer_set_layout,
    },
    &warehouse.bone_buffer_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = warehouse.bone_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = warehouse.bone_buffer_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gpu_context.device, 1, &write, 0, nil)

  // Initialize dummy skinning buffer for static meshes
  warehouse.dummy_skinning_buffer = gpu.create_host_visible_buffer(
  gpu_context,
  geometry.SkinningData,
  1, // Just one dummy element
  {.VERTEX_BUFFER},
  ) or_return

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
    log.infof("Error: Index %d out of bounds for bindless textures", index)
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
    log.infof(
      "Error: Index %d out of bounds for bindless cube textures",
      index,
    )
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
  gpu.data_buffer_deinit(gpu_context, &warehouse.bone_buffer)
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    warehouse.bone_buffer_set_layout,
    nil,
  )
  warehouse.bone_buffer_set_layout = 0
  resource.slab_allocator_deinit(&warehouse.bone_matrix_slab)
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
  mesh_init(mesh, gpu_context, data)
  ret = .SUCCESS
  return
}

create_material :: proc(
  warehouse: ^ResourceWarehouse,
  features: ShaderFeatureSet = {},
  albedo_handle: Handle = {},
  metallic_roughness_handle: Handle = {},
  normal_handle: Handle = {},
  emissive_handle: Handle = {},
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: f32 = 0.0,
) -> (
  ret: Handle,
  mat: ^Material,
  res: vk.Result,
) {
  ret, mat = resource.alloc(&warehouse.materials)
  mat.type = .PBR
  mat.features = features
  mat.albedo = albedo_handle
  mat.metallic_roughness = metallic_roughness_handle
  mat.normal = normal_handle
  mat.emissive = emissive_handle
  mat.metallic_value = metallic_value
  mat.roughness_value = roughness_value
  mat.emissive_value = emissive_value
  log.infof(
    "Material created: albedo=%d metallic_roughness=%d normal=%d emissive=%d",
    mat.albedo.index,
    mat.metallic_roughness.index,
    mat.normal.index,
    mat.emissive.index,
  )
  res = .SUCCESS
  return
}

create_unlit_material :: proc(
  warehouse: ^ResourceWarehouse,
  features: ShaderFeatureSet = {},
  albedo_handle: Handle = {},
  emissive_value: f32 = 0.0,
) -> (
  ret: Handle,
  mat: ^Material,
  res: vk.Result,
) {
  ret, mat = resource.alloc(&warehouse.materials)
  mat.type = .UNLIT
  mat.features = features
  mat.albedo = albedo_handle
  mat.emissive_value = emissive_value
  res = .SUCCESS
  return
}

create_transparent_material :: proc(
  warehouse: ^ResourceWarehouse,
  features: ShaderFeatureSet = {},
) -> (
  ret: Handle,
  mat: ^Material,
  res: vk.Result,
) {
  ret, mat = resource.alloc(&warehouse.materials)
  mat.type = .TRANSPARENT
  mat.features = features
  res = .SUCCESS
  return
}

create_wireframe_material :: proc(
  warehouse: ^ResourceWarehouse,
  features: ShaderFeatureSet = {},
) -> (
  ret: Handle,
  mat: ^Material,
  res: vk.Result,
) {
  ret, mat = resource.alloc(&warehouse.materials)
  mat.type = .WIREFRAME
  mat.features = features
  res = .SUCCESS
  return
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
  pixels := stbi.load(path_cstr, &width, &height, &c_in_file, 4) // force RGBA
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

get_frame_bone_matrix_offset :: proc(
  warehouse: ^ResourceWarehouse,
  base_offset: u32,
  frame_index: u32,
) -> u32 {
  frame_capacity := warehouse.bone_matrix_slab.capacity
  return base_offset + frame_index * frame_capacity
}
