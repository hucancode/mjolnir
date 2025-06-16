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
  skinning_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
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
  for &set in self.skinning_descriptor_sets do set = 0
  data_buffer_deinit(&self.fallback_buffer)
}

material_init_descriptor_set_layout :: proc(
  mat: ^Material,
  skinning_descriptor_set_layout: vk.DescriptorSetLayout,
) -> vk.Result {
  skinning_layout := skinning_descriptor_set_layout
  for &set in mat.skinning_descriptor_sets {
    vk.AllocateDescriptorSets(
      g_device,
      &{
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = g_descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &skinning_layout,
      },
      &set,
    ) or_return
  }
  return .SUCCESS
}

material_update_bone_buffer :: proc(
  self: ^Material,
  buffer: vk.Buffer,
  size: vk.DeviceSize,
  frame: u32,
) {
  if self.skinning_descriptor_sets[frame] == 0 {
    return
  }
  buffer_info := vk.DescriptorBufferInfo {
    buffer = buffer,
    offset = 0,
    range  = size,
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = self.skinning_descriptor_sets[frame],
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(g_device, 1, &write, 0, nil)
}
