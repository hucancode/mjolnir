package mjolnir

import "core:log"

ShaderFeatures :: enum {
  ALBEDO_TEXTURE             = 0,
  METALLIC_ROUGHNESS_TEXTURE = 1,
  NORMAL_TEXTURE             = 2,
  EMISSIVE_TEXTURE           = 3,
  OCCLUSION_TEXTURE          = 4,
}

ShaderFeatureSet :: bit_set[ShaderFeatures;u32]

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
