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

factory_init :: proc() {
  log.infof("Initializing mesh pool... ")
  resource.pool_init(&g_meshes)
  log.infof("Initializing materials pool... ")
  resource.pool_init(&g_materials)
  log.infof("Initializing image buffer pool... ")
  resource.pool_init(&g_image_buffers)
  log.infof("All resource pools initialized successfully")
  init_global_samplers()
}

factory_deinit :: proc() {
  resource.pool_deinit(g_image_buffers, image_buffer_deinit)
  resource.pool_deinit(g_meshes, mesh_deinit)
  resource.pool_deinit(g_materials, material_deinit)
  deinit_global_samplers()
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
  texture_descriptor_set_layout: vk.DescriptorSetLayout,
  skinning_descriptor_set_layout: vk.DescriptorSetLayout,
  features: ShaderFeatureSet = {},
  albedo_handle: Handle = {},
  metallic_roughness_handle: Handle = {},
  normal_handle: Handle = {},
  displacement_handle: Handle = {},
  emissive_handle: Handle = {},
  albedo_value: linalg.Vector4f32 = {1, 1, 1, 1},
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: linalg.Vector4f32 = {},
) -> (
  ret: Handle,
  mat: ^Material,
  res: vk.Result,
) {
  log.info("creating material")
  ret, mat = resource.alloc(&g_materials)
  mat.is_lit = true
  mat.features = features
  mat.albedo_handle = albedo_handle
  mat.metallic_roughness_handle = metallic_roughness_handle
  mat.normal_handle = normal_handle
  mat.displacement_handle = displacement_handle
  mat.emissive_handle = emissive_handle
  mat.albedo_value = albedo_value
  mat.metallic_value = metallic_value
  mat.roughness_value = roughness_value
  mat.emissive_value = emissive_value
  material_init_descriptor_set_layout(
    mat,
    texture_descriptor_set_layout,
    skinning_descriptor_set_layout,
  ) or_return
  fallbacks := MaterialFallbacks {
    albedo    = mat.albedo_value,
    emissive  = mat.emissive_value,
    roughness = mat.roughness_value,
    metallic  = mat.metallic_value,
  }
  mat.fallback_buffer = create_host_visible_buffer(
    MaterialFallbacks,
    1,
    {.UNIFORM_BUFFER},
    &fallbacks,
  ) or_return
  albedo := resource.get(g_image_buffers, albedo_handle)
  metallic_roughness := resource.get(
    g_image_buffers,
    metallic_roughness_handle,
  )
  normal := resource.get(g_image_buffers, normal_handle)
  displacement := resource.get(g_image_buffers, displacement_handle)
  emissive := resource.get(g_image_buffers, emissive_handle)
  material_update_textures(
    mat,
    albedo,
    metallic_roughness,
    normal,
    displacement,
    emissive,
  ) or_return
  res = .SUCCESS
  return
}

create_unlit_material :: proc(
  texture_descriptor_set_layout: vk.DescriptorSetLayout,
  skinning_descriptor_set_layout: vk.DescriptorSetLayout,
  features: ShaderFeatureSet = {},
  albedo_handle: Handle = {},
  albedo_value: linalg.Vector4f32 = {1, 1, 1, 1},
) -> (
  ret: Handle,
  mat: ^Material,
  res: vk.Result,
) {
  ret, mat = resource.alloc(&g_materials)
  mat.is_lit = false
  mat.features = features
  mat.albedo_handle = albedo_handle
  mat.albedo_value = albedo_value
  material_init_descriptor_set_layout(
    mat,
    texture_descriptor_set_layout,
    skinning_descriptor_set_layout,
  ) or_return
  albedo := resource.get(g_image_buffers, albedo_handle)
  fallbacks := MaterialFallbacks {
    albedo = mat.albedo_value,
  }
  mat.fallback_buffer = create_host_visible_buffer(
    MaterialFallbacks,
    1,
    {.UNIFORM_BUFFER},
    &fallbacks,
  ) or_return
  material_update_textures(mat, albedo) or_return
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
    return
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
  ret = .SUCCESS
  return
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
    return
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
  log.infof(
    "created HDR texture %d x %d -> id %d",
    width,
    height,
    texture.image,
  )
  ret = .SUCCESS
  return
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
  ret = .SUCCESS
  return
}
