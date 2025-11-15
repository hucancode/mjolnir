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
  albedo:             Handle,
  metallic_roughness: Handle,
  normal:             Handle,
  emissive:           Handle,
  occlusion:          Handle,
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

material_update_gpu_data :: proc(mat: ^Material) {
  mat.albedo_index = min(MAX_TEXTURES - 1, mat.albedo.index)
  mat.metallic_roughness_index = min(
    MAX_TEXTURES - 1,
    mat.metallic_roughness.index,
  )
  mat.normal_index = min(MAX_TEXTURES - 1, mat.normal.index)
  mat.emissive_index = min(MAX_TEXTURES - 1, mat.emissive.index)
}

material_write_to_gpu :: proc(
  manager: ^Manager,
  handle: Handle,
  mat: ^Material,
) -> vk.Result {
  if handle.index >= MAX_MATERIALS {
    return .ERROR_OUT_OF_DEVICE_MEMORY
  }
  material_update_gpu_data(mat)
  gpu.write(&manager.material_buffer, &mat.data, int(handle.index)) or_return
  return .SUCCESS
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
  ok: bool
  ret, mat, ok = cont.alloc(&manager.materials)
  if !ok {
    log.error("Failed to allocate material: pool capacity reached")
    return Handle{}, nil, .ERROR_OUT_OF_DEVICE_MEMORY
  }
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
      type = .PBR,
      base_color_factor = color,
    )
  }
  log.info("Builtin materials created successfully")
  return .SUCCESS
}
