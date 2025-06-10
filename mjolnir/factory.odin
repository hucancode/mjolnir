package mjolnir

import "core:c"
import "core:log"
import linalg "core:math/linalg"
import "core:slice"
import "core:strings"
import "geometry"
import "resource"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

g_meshes: resource.Pool(Mesh)
g_materials: resource.Pool(Material)
g_textures: resource.Pool(Texture)

factory_init :: proc() {
  log.infof("Initializing mesh pool... ")
  resource.pool_init(&g_meshes)
  log.infof("Initializing materials pool... ")
  resource.pool_init(&g_materials)
  log.infof("Initializing textures pool... ")
  resource.pool_init(&g_textures)
  log.infof("All resource pools initialized successfully")
}

factory_deinit :: proc() {
  resource.pool_deinit(g_textures, texture_deinit)
  resource.pool_deinit(g_meshes, mesh_deinit)
  resource.pool_deinit(g_materials, material_deinit)
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
  albedo := resource.get(g_textures, albedo_handle)
  metallic_roughness := resource.get(g_textures, metallic_roughness_handle)
  normal := resource.get(g_textures, normal_handle)
  displacement := resource.get(g_textures, displacement_handle)
  emissive := resource.get(g_textures, emissive_handle)
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
  albedo := resource.get(g_textures, albedo_handle)
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
  texture: ^Texture,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&g_textures)
  read_texture(texture, path) or_return
  texture_init(texture) or_return
  ret = .SUCCESS
  return
}

create_hdr_texture_from_path :: proc(
  path: string,
) -> (
  handle: resource.Handle,
  texture: ^Texture,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&g_textures)
  path_cstr := strings.clone_to_cstring(path)
  w, h, c_in_file: c.int
  float_pixels_ptr := stbi.loadf(path_cstr, &w, &h, &c_in_file, 4) // force RGBA
  if float_pixels_ptr == nil {
    log.errorf(
      "Failed to load HDR texture from path '%s': %s\n",
      path,
      stbi.failure_reason(),
    )
    ret = .ERROR_UNKNOWN
    return
  }
  num_floats := int(w * h * 4)
  texture.image_data.pixels = slice.to_bytes(float_pixels_ptr[:num_floats])
  texture.image_data.width = int(w)
  texture.image_data.height = int(h)
  texture.image_data.channels_in_file = 3
  texture.image_data.actual_channels = 4
  texture_init(texture, .R32G32B32A32_SFLOAT) or_return
  log.infof("created HDR texture %d x %d -> id %d", w, h, texture.buffer.image)
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
  texture: ^Texture,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&g_textures)
  texture.image_data.pixels = pixels
  texture.image_data.width = width
  texture.image_data.height = height
  texture.image_data.channels_in_file = channel
  texture.image_data.actual_channels = channel
  texture_init(texture, format) or_return
  log.infof(
    "created texture %d x %d -> id %d",
    texture.image_data.width,
    texture.image_data.height,
    texture.buffer.image,
  )
  ret = .SUCCESS
  return
}

create_texture_from_data :: proc(
  data: []u8,
) -> (
  handle: resource.Handle,
  texture: ^Texture,
  ret: vk.Result,
) {
  handle, texture = resource.alloc(&g_textures)
  read_texture_data(texture, data) or_return
  texture_init(texture) or_return
  log.infof(
    "created texture %d x %d -> id %d",
    texture.image_data.width,
    texture.image_data.height,
    texture.buffer.image,
  )
  ret = .SUCCESS
  return
}
