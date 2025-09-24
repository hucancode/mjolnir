package mjolnir

import "core:log"

SHADOW_SHADER_OPTION_COUNT: u32 : 0
SHADOW_SHADER_VARIANT_COUNT: u32 : 1 << SHADOW_SHADER_OPTION_COUNT

ShadowShaderConfig :: struct {}

ShaderFeatures :: enum {
  ALBEDO_TEXTURE             = 0,
  METALLIC_ROUGHNESS_TEXTURE = 1,
  NORMAL_TEXTURE             = 2,
  EMISSIVE_TEXTURE           = 3,
  OCCLUSION_TEXTURE          = 4,
}

ShaderFeatureSet :: bit_set[ShaderFeatures;u32]
SHADER_OPTION_COUNT: u32 : len(ShaderFeatures)
SHADER_VARIANT_COUNT: u32 : 1 << SHADER_OPTION_COUNT

ShaderConfig :: struct {
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

MAX_MATERIALS :: 4096

MaterialData :: struct {
  albedo_index:             u32,
  metallic_roughness_index: u32,
  normal_index:             u32,
  emissive_index:           u32,
  metallic_value:           f32,
  roughness_value:          f32,
  emissive_value:           f32,
  features:                 u32,
  base_color_factor:        [4]f32,
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
