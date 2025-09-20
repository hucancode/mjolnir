package mjolnir

import "core:log"
import "core:math"

SHADOW_SHADER_OPTION_COUNT: u32 : 1 // Only SKINNING
SHADOW_SHADER_VARIANT_COUNT: u32 : 1 << SHADOW_SHADER_OPTION_COUNT

ShadowShaderConfig :: struct {
  is_skinned: b32,
}

ShaderFeatures :: enum {
  SKINNING                   = 0,
  ALBEDO_TEXTURE             = 1,
  METALLIC_ROUGHNESS_TEXTURE = 2,
  NORMAL_TEXTURE             = 3,
  EMISSIVE_TEXTURE           = 4,
  OCCLUSION_TEXTURE          = 5,
}

ShaderFeatureSet :: bit_set[ShaderFeatures;u32]
SHADER_OPTION_COUNT: u32 : len(ShaderFeatures)
SHADER_VARIANT_COUNT: u32 : 1 << SHADER_OPTION_COUNT

ShaderConfig :: struct {
  is_skinned:                     b32,
  has_albedo_texture:             b32,
  has_metallic_roughness_texture: b32,
  has_normal_texture:             b32,
  has_emissive_texture:           b32,
  has_occlusion_texture:          b32,
}

MaterialType :: enum {
  PBR,
  UNLIT,
  WIREFRAME,
  TRANSPARENT,
}

Material :: struct {
  type:               MaterialType,
  features:           ShaderFeatureSet,
  albedo:             Handle,
  metallic_roughness: Handle,
  normal:             Handle,
  emissive:           Handle,
  occlusion:          Handle,
  metallic_value:     f32,
  roughness_value:    f32,
  emissive_value:     f32,
  base_color_factor:  [4]f32,
}

MaterialData :: struct {
  albedo_index:             u32,
  metallic_roughness_index: u32,
  normal_index:             u32,
  emissive_index:           u32,
  metallic_value:           f32,
  roughness_value:          f32,
  emissive_value:           f32,
  material_type:            u32,
  features:                 u32,
  base_color_factor:        [4]f32,
  padding:                  [2]u32,
}

material_to_data :: proc(material: ^Material) -> MaterialData {
  return MaterialData {
    albedo_index             = math.min(MAX_TEXTURES - 1, material.albedo.index),
    metallic_roughness_index = math.min(MAX_TEXTURES - 1, material.metallic_roughness.index),
    normal_index             = math.min(MAX_TEXTURES - 1, material.normal.index),
    emissive_index           = math.min(MAX_TEXTURES - 1, material.emissive.index),
    metallic_value           = material.metallic_value,
    roughness_value          = material.roughness_value,
    emissive_value           = material.emissive_value,
    material_type            = u32(material.type),
    features                 = transmute(u32)material.features,
    base_color_factor        = material.base_color_factor,
  }
}
