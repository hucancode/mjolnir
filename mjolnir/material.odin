package mjolnir

import "core:log"

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
}

MaterialType :: enum {
  PBR,
  UNLIT,
  WIREFRAME,
}

Material :: struct {
  type:               MaterialType,
  features:           ShaderFeatureSet,
  is_transparent:     bool,
  albedo:             Handle,
  metallic_roughness: Handle,
  normal:             Handle,
  emissive:           Handle,
  metallic_value:     f32,
  roughness_value:    f32,
  emissive_value:     f32,
}
