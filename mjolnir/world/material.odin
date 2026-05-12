package world

import cont "../containers"
import "../gpu"
import "core:log"

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
  RANDOM_COLOR,
  LINE_STRIP,
}

Material :: struct {
  features:           ShaderFeatureSet,
  base_color_factor:  [4]f32,
  metallic_value:     f32,
  roughness_value:    f32,
  emissive_value:     f32,
  type:               MaterialType,
  albedo:             gpu.Texture2DHandle,
  metallic_roughness: gpu.Texture2DHandle,
  normal:             gpu.Texture2DHandle,
  emissive:           gpu.Texture2DHandle,
  occlusion:          gpu.Texture2DHandle,
}

material_init :: proc(
  self: ^Material,
  features: ShaderFeatureSet,
  type: MaterialType,
  albedo_handle: gpu.Texture2DHandle,
  metallic_roughness_handle: gpu.Texture2DHandle,
  normal_handle: gpu.Texture2DHandle,
  emissive_handle: gpu.Texture2DHandle,
  occlusion_handle: gpu.Texture2DHandle,
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

// Focused PBR constructor — solid color + metallic/roughness/emissive scalars.
// For textured variants use `material_textured`. For non-PBR use `material_unlit`,
// `material_wireframe`, etc.
material_pbr :: proc(
  world: ^World,
  base_color: [4]f32 = {1, 1, 1, 1},
  metallic: f32 = 0.0,
  roughness: f32 = 1.0,
  emissive: f32 = 0.0,
) -> (MaterialHandle, bool) #optional_ok {
  return create_material(
    world,
    type              = .PBR,
    base_color_factor = base_color,
    metallic_value    = metallic,
    roughness_value   = roughness,
    emissive_value    = emissive,
  )
}

// Textured PBR material. Pass any subset of texture handles; pass `{}` to skip.
material_textured :: proc(
  world: ^World,
  albedo: gpu.Texture2DHandle = {},
  metallic_roughness: gpu.Texture2DHandle = {},
  normal: gpu.Texture2DHandle = {},
  emissive_tex: gpu.Texture2DHandle = {},
  occlusion: gpu.Texture2DHandle = {},
  base_color: [4]f32 = {1, 1, 1, 1},
  metallic: f32 = 0.0,
  roughness: f32 = 1.0,
  emissive: f32 = 0.0,
) -> (MaterialHandle, bool) #optional_ok {
  features: ShaderFeatureSet
  if albedo             != {} do features += {.ALBEDO_TEXTURE}
  if metallic_roughness != {} do features += {.METALLIC_ROUGHNESS_TEXTURE}
  if normal             != {} do features += {.NORMAL_TEXTURE}
  if emissive_tex       != {} do features += {.EMISSIVE_TEXTURE}
  if occlusion          != {} do features += {.OCCLUSION_TEXTURE}
  return create_material(
    world,
    features                  = features,
    type                      = .PBR,
    albedo_handle             = albedo,
    metallic_roughness_handle = metallic_roughness,
    normal_handle             = normal,
    emissive_handle           = emissive_tex,
    occlusion_handle          = occlusion,
    metallic_value            = metallic,
    roughness_value           = roughness,
    emissive_value            = emissive,
    base_color_factor         = base_color,
  )
}

material_unlit :: proc(
  world: ^World,
  base_color: [4]f32 = {1, 1, 1, 1},
  albedo: gpu.Texture2DHandle = {},
) -> (MaterialHandle, bool) #optional_ok {
  features: ShaderFeatureSet
  if albedo != {} do features += {.ALBEDO_TEXTURE}
  return create_material(
    world,
    features          = features,
    type              = .UNLIT,
    albedo_handle     = albedo,
    base_color_factor = base_color,
  )
}

material_wireframe :: proc(
  world: ^World,
  base_color: [4]f32 = {1, 1, 1, 1},
) -> (MaterialHandle, bool) #optional_ok {
  return create_material(world, type = .WIREFRAME, base_color_factor = base_color)
}

material_transparent :: proc(
  world: ^World,
  base_color: [4]f32 = {1, 1, 1, 0.5},
) -> (MaterialHandle, bool) #optional_ok {
  return create_material(world, type = .TRANSPARENT, base_color_factor = base_color)
}

create_material :: proc(
  world: ^World,
  features: ShaderFeatureSet = {},
  type: MaterialType = .PBR,
  albedo_handle: gpu.Texture2DHandle = {},
  metallic_roughness_handle: gpu.Texture2DHandle = {},
  normal_handle: gpu.Texture2DHandle = {},
  emissive_handle: gpu.Texture2DHandle = {},
  occlusion_handle: gpu.Texture2DHandle = {},
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: f32 = 0.0,
  base_color_factor: [4]f32 = {1.0, 1.0, 1.0, 1.0},
) -> (
  handle: MaterialHandle,
  ok: bool,
) #optional_ok {
  mat: ^Material
  handle, mat = cont.alloc(&world.materials, MaterialHandle) or_return
  defer if !ok {
    cont.free(&world.materials, handle)
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
  stage_material_data(&world.staging, handle)
  return handle, true
}
