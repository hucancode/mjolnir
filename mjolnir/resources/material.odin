package resources

import cont "../containers"
import "../gpu"
import "core:log"
import vk "vendor:vulkan"

ShaderFeature :: enum {
  ALBEDO_TEXTURE             = 0,
  METALLIC_ROUGHNESS_TEXTURE = 1,
  NORMAL_TEXTURE             = 2,
  EMISSIVE_TEXTURE           = 3,
  OCCLUSION_TEXTURE          = 4,
}

ShaderFeatureSet :: bit_set[ShaderFeature;u32]

MaterialType :: enum {
  PBR,
  UNLIT,
  WIREFRAME,
  TRANSPARENT,
}

MAX_MATERIALS :: 4096

MaterialData :: struct {
  albedo_index:             u32,
  metallic_roughness_index: u32,
  normal_index:             u32,
  emissive_index:           u32,
  metallic_value:           f32,
  roughness_value:          f32,
  emissive_value:           f32,
  features:                 ShaderFeatureSet,
  base_color_factor:        [4]f32,
}

Material :: struct {
  using data:         MaterialData,
  type:               MaterialType,
  albedo:             Image2DHandle,
  metallic_roughness: Image2DHandle,
  normal:             Image2DHandle,
  emissive:           Image2DHandle,
  occlusion:          Image2DHandle,
  using meta:         ResourceMetadata,
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

material_init :: proc(
  self: ^Material,
  features: ShaderFeatureSet,
  type: MaterialType,
  albedo_handle: Image2DHandle,
  metallic_roughness_handle: Image2DHandle,
  normal_handle: Image2DHandle,
  emissive_handle: Image2DHandle,
  occlusion_handle: Image2DHandle,
  metallic_value: f32,
  roughness_value: f32,
  emissive_value: f32,
  base_color_factor: [4]f32,
) {
  self.type = type
  self.features = features
  self.albedo = albedo_handle
  self.metallic_roughness = metallic_roughness_handle
  self.normal = normal_handle
  self.emissive = emissive_handle
  self.occlusion = occlusion_handle
  self.metallic_value = metallic_value
  self.roughness_value = roughness_value
  self.emissive_value = emissive_value
  self.base_color_factor = base_color_factor
}

material_upload_gpu_data :: proc(
  rm: ^Manager,
  handle: MaterialHandle,
  self: ^Material,
) -> vk.Result {
  if handle.index >= MAX_MATERIALS {
    return .ERROR_OUT_OF_DEVICE_MEMORY
  }
  self.albedo_index = min(MAX_TEXTURES - 1, self.albedo.index)
  self.metallic_roughness_index = min(
    MAX_TEXTURES - 1,
    self.metallic_roughness.index,
  )
  self.normal_index = min(MAX_TEXTURES - 1, self.normal.index)
  self.emissive_index = min(MAX_TEXTURES - 1, self.emissive.index)
  gpu.write(
    &rm.material_buffer.buffer,
    &self.data,
    int(handle.index),
  ) or_return
  return .SUCCESS
}

material_destroy :: proc(self: ^Material, rm: ^Manager) {
  texture_2d_unref(rm, self.albedo)
  texture_2d_unref(rm, self.metallic_roughness)
  texture_2d_unref(rm, self.normal)
  texture_2d_unref(rm, self.emissive)
  texture_2d_unref(rm, self.occlusion)
}

create_material :: proc(
  rm: ^Manager,
  features: ShaderFeatureSet = {},
  type: MaterialType = .PBR,
  albedo_handle: Image2DHandle = {},
  metallic_roughness_handle: Image2DHandle = {},
  normal_handle: Image2DHandle = {},
  emissive_handle: Image2DHandle = {},
  occlusion_handle: Image2DHandle = {},
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: f32 = 0.0,
  base_color_factor: [4]f32 = {1.0, 1.0, 1.0, 1.0},
  auto_purge := false,
) -> (
  handle: MaterialHandle,
  ret: vk.Result,
) {
  mat: ^Material
  ok: bool
  handle, mat, ok = cont.alloc(&rm.materials, MaterialHandle)
  if !ok {
    log.error("Failed to allocate material: pool capacity reached")
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  material_init(
    mat,
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
  mat.auto_purge = auto_purge
  material_upload_gpu_data(rm, handle, mat) or_return
  log.infof(
    "Material created: albedo=%d metallic_roughness=%d normal=%d emissive=%d",
    mat.albedo.index,
    mat.metallic_roughness.index,
    mat.normal.index,
    mat.emissive.index,
  )
  return handle, .SUCCESS
}

create_material_handle :: proc(
  rm: ^Manager,
  features: ShaderFeatureSet = {},
  type: MaterialType = .PBR,
  albedo_handle: Image2DHandle = {},
  metallic_roughness_handle: Image2DHandle = {},
  normal_handle: Image2DHandle = {},
  emissive_handle: Image2DHandle = {},
  occlusion_handle: Image2DHandle = {},
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: f32 = 0.0,
  base_color_factor: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (
  handle: MaterialHandle,
  ok: bool,
) #optional_ok {
  h, ret := create_material(
    rm,
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

init_builtin_materials :: proc(self: ^Manager) -> vk.Result {
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
    self.builtin_materials[i] =
    create_material(self, type = .PBR, base_color_factor = color) or_continue
  }
  log.info("Builtin materials created successfully")
  return .SUCCESS
}
