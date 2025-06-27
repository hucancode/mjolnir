package mjolnir

import "core:c"
import "core:log"
import linalg "core:math/linalg"
import "core:strings"
import "geometry"
import "resource"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

g_linear_repeat_sampler: vk.Sampler
g_linear_clamp_sampler: vk.Sampler
g_nearest_repeat_sampler: vk.Sampler
g_nearest_clamp_sampler: vk.Sampler

g_meshes: resource.Pool(Mesh)
g_materials: resource.Pool(Material)
g_image_buffers: resource.Pool(ImageBuffer)

g_bindless_bone_buffer_set_layout: vk.DescriptorSetLayout
g_bindless_bone_buffer_descriptor_set: vk.DescriptorSet
g_bindless_bone_buffer: DataBuffer(linalg.Matrix4f32)
g_bone_matrix_slab: resource.SlabAllocator

factory_init :: proc() -> vk.Result {
  log.infof("Initializing mesh pool... ")
  resource.pool_init(&g_meshes)
  log.infof("Initializing materials pool... ")
  resource.pool_init(&g_materials)
  log.infof("Initializing image buffer pool... ")
  resource.pool_init(&g_image_buffers)
  log.infof("All resource pools initialized successfully")
  init_global_samplers()
  init_bone_matrix_allocator() or_return
  return .SUCCESS
}

factory_deinit :: proc() {
  data_buffer_deinit(&g_bindless_bone_buffer)
  resource.pool_deinit(g_image_buffers, image_buffer_deinit)
  resource.pool_deinit(g_meshes, mesh_deinit)
  resource.pool_deinit(g_materials, proc(_: ^Material) {})
  deinit_global_samplers()
  deinit_bone_matrix_allocator()
}

init_global_samplers :: proc() -> vk.Result {
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
  vk.CreateSampler(g_device, &info, nil, &g_linear_repeat_sampler) or_return
  info.addressModeU = .CLAMP_TO_EDGE
  info.addressModeV = .CLAMP_TO_EDGE
  info.addressModeW = .CLAMP_TO_EDGE
  vk.CreateSampler(g_device, &info, nil, &g_linear_clamp_sampler) or_return
  info.magFilter = .NEAREST
  info.minFilter = .NEAREST
  info.addressModeU = .REPEAT
  info.addressModeV = .REPEAT
  info.addressModeW = .REPEAT
  vk.CreateSampler(g_device, &info, nil, &g_nearest_repeat_sampler) or_return
  info.addressModeU = .CLAMP_TO_EDGE
  info.addressModeV = .CLAMP_TO_EDGE
  info.addressModeW = .CLAMP_TO_EDGE
  vk.CreateSampler(g_device, &info, nil, &g_nearest_clamp_sampler) or_return
  write_samplers := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = g_bindless_samplers,
      dstBinding = 0,
      dstArrayElement = 0,
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = g_nearest_clamp_sampler},
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = g_bindless_samplers,
      dstBinding = 0,
      dstArrayElement = 1,
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = g_linear_clamp_sampler},
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = g_bindless_samplers,
      dstBinding = 0,
      dstArrayElement = 2,
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = g_nearest_repeat_sampler},
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = g_bindless_samplers,
      dstBinding = 0,
      dstArrayElement = 3,
      descriptorType = .SAMPLER,
      descriptorCount = 1,
      pImageInfo = &{sampler = g_linear_repeat_sampler},
    },
  }
  vk.UpdateDescriptorSets(
    g_device,
    len(write_samplers),
    raw_data(write_samplers[:]),
    0,
    nil,
  )
  return .SUCCESS
}

init_bone_matrix_allocator :: proc() -> vk.Result {
  resource.slab_allocator_init(
    &g_bone_matrix_slab,
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
    g_bone_matrix_slab.capacity,
    MAX_FRAMES_IN_FLIGHT,
  )
  // Create bone buffer with space for all frames in flight
  g_bindless_bone_buffer, _ = create_host_visible_buffer(
    linalg.Matrix4f32,
    int(g_bone_matrix_slab.capacity) * MAX_FRAMES_IN_FLIGHT,
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
    g_device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(skinning_bindings),
      pBindings = raw_data(skinning_bindings[:]),
    },
    nil,
    &g_bindless_bone_buffer_set_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &g_bindless_bone_buffer_set_layout,
    },
    &g_bindless_bone_buffer_descriptor_set,
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = g_bindless_bone_buffer.buffer,
    offset = 0,
    range  = vk.DeviceSize(vk.WHOLE_SIZE),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = g_bindless_bone_buffer_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(g_device, 1, &write, 0, nil)
  return .SUCCESS
}

deinit_global_samplers :: proc() {
  vk.DestroySampler(
    g_device,
    g_linear_repeat_sampler,
    nil,
  );g_linear_repeat_sampler = 0
  vk.DestroySampler(
    g_device,
    g_linear_clamp_sampler,
    nil,
  );g_linear_clamp_sampler = 0
  vk.DestroySampler(
    g_device,
    g_nearest_repeat_sampler,
    nil,
  );g_nearest_repeat_sampler = 0
  vk.DestroySampler(
    g_device,
    g_nearest_clamp_sampler,
    nil,
  );g_nearest_clamp_sampler = 0
}

deinit_bone_matrix_allocator :: proc() {
  data_buffer_deinit(&g_bindless_bone_buffer)
  vk.DestroyDescriptorSetLayout(
    g_device,
    g_bindless_bone_buffer_set_layout,
    nil,
  )
  g_bindless_bone_buffer_set_layout = 0
  resource.slab_allocator_deinit(&g_bone_matrix_slab)
}

create_mesh :: proc(
  data: geometry.Geometry,
) -> (
  handle: Handle,
  mesh: ^Mesh,
  ret: vk.Result,
) {
  handle, mesh = resource.alloc(&g_meshes)
  mesh_init(mesh, data)
  ret = .SUCCESS
  return
}

create_material :: proc(
  features: ShaderFeatureSet = {},
  albedo_handle: Handle = {},
  metallic_roughness_handle: Handle = {},
  normal_handle: Handle = {},
  displacement_handle: Handle = {},
  emissive_handle: Handle = {},
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: f32 = 0.0,
) -> (
  ret: Handle,
  mat: ^Material,
  res: vk.Result,
) {
  log.info("creating material")
  ret, mat = resource.alloc(&g_materials)
  mat.type = .PBR
  mat.features = features
  mat.albedo = albedo_handle
  mat.metallic_roughness = metallic_roughness_handle
  mat.normal = normal_handle
  mat.displacement = displacement_handle
  mat.emissive = emissive_handle
  mat.metallic_value = metallic_value
  mat.roughness_value = roughness_value
  mat.emissive_value = emissive_value
  log.infof(
    "Material created: albedo=%d metallic_roughness=%d normal=%d displacement=%d emissive=%d",
    mat.albedo.index,
    mat.metallic_roughness.index,
    mat.normal.index,
    mat.displacement.index,
    mat.emissive.index,
  )
  res = .SUCCESS
  return
}

create_unlit_material :: proc(
  features: ShaderFeatureSet = {},
  albedo_handle: Handle = {},
  emissive_value: f32 = 0.0,
) -> (
  ret: Handle,
  mat: ^Material,
  res: vk.Result,
) {
  ret, mat = resource.alloc(&g_materials)
  mat.type = .UNLIT
  mat.features = features
  mat.albedo = albedo_handle
  mat.emissive_value = emissive_value
  res = .SUCCESS
  return
}

create_wireframe_material :: proc(
  features: ShaderFeatureSet = {},
) -> (
  ret: Handle,
  mat: ^Material,
  res: vk.Result,
) {
  ret, mat = resource.alloc(&g_materials)
  mat.type = .WIREFRAME
  mat.features = features
  res = .SUCCESS
  return
}

create_texture_from_path :: proc(
  path: string,
) -> (
  handle: resource.Handle,
  texture: ^ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&g_image_buffers)
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
  texture^ = create_image_buffer(
    pixels,
    size_of(u8) * vk.DeviceSize(num_pixels),
    .R8G8B8A8_SRGB,
    u32(width),
    u32(height),
  ) or_return
  set_texture_descriptor(handle.index, texture.view)
  ret = .SUCCESS
  return handle, texture, ret
}

create_hdr_texture_from_path :: proc(
  path: string,
) -> (
  handle: resource.Handle,
  texture: ^ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&g_image_buffers)
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
  texture^ = create_image_buffer(
    float_pixels,
    size_of(f32) * vk.DeviceSize(num_floats),
    .R32G32B32A32_SFLOAT,
    u32(width),
    u32(height),
  ) or_return
  set_texture_descriptor(handle.index, texture.view)
  ret = .SUCCESS
  return handle, texture, ret
}

create_texture_from_pixels :: proc(
  pixels: []u8,
  width: int,
  height: int,
  channel: int,
  format: vk.Format = .R8G8B8A8_SRGB,
) -> (
  handle: resource.Handle,
  texture: ^ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&g_image_buffers)
  texture^ = create_image_buffer(
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
  set_texture_descriptor(handle.index, texture.view)
  ret = .SUCCESS
  return
}

create_texture_from_data :: proc(
  data: []u8,
) -> (
  handle: resource.Handle,
  texture: ^ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&g_image_buffers)
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
  texture^ = create_image_buffer(
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
  set_texture_descriptor(handle.index, texture.view)
  ret = .SUCCESS
  return
}

// Calculate frame-specific bone matrix offset
get_frame_bone_matrix_offset :: proc(base_offset: u32, frame_index: u32) -> u32 {
  frame_capacity := g_bone_matrix_slab.capacity
  return base_offset + frame_index * frame_capacity
}
