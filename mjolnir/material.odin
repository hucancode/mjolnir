package mjolnir

import "core:log"
import linalg "core:math/linalg"
import vk "vendor:vulkan"

MaterialFallbacks :: struct {
  albedo:    linalg.Vector4f32,
  emissive:  linalg.Vector4f32,
  roughness: f32,
  metallic:  f32,
  padding:   [2]f32, // Padding to align to 16 bytes
}

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
  fallback_buffer:          DataBuffer(MaterialFallbacks),
}

material_deinit :: proc(self: ^Material) {
  if self == nil {
    return
  }
  data_buffer_deinit(&self.fallback_buffer)
}
