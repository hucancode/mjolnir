package mjolnir

import "core:log"
import linalg "core:math/linalg"
import vk "vendor:vulkan"


MaterialTextures :: struct {
  albedo_index:             u32,
  metallic_roughness_index: u32,
  normal_index:             u32,
  displacement_index:       u32,
  emissive_index:           u32,
  environment_index:        u32,
  brdf_lut_index:           u32,
  bone_matrix_offset:       u32,
}

Material :: struct {
  features:                 ShaderFeatureSet,
  is_lit:                   bool,
  albedo:                   Handle,
  metallic_roughness:       Handle,
  normal:                   Handle,
  displacement:             Handle,
  emissive:                 Handle,
  albedo_value:             linalg.Vector4f32,
  metallic_value:           f32,
  roughness_value:          f32,
  emissive_value:           linalg.Vector4f32,
}
