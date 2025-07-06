package mjolnir

import "core:log"

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
  displacement:       Handle,
  emissive:           Handle,
  metallic_value:     f32,
  roughness_value:    f32,
  emissive_value:     f32,
}
