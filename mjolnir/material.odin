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

Material :: struct {
  texture_descriptor_set:    vk.DescriptorSet,
  skinning_descriptor_sets:  [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  features:                  ShaderFeatureSet,
  is_lit:                    bool,
  albedo_handle:             Handle,
  metallic_roughness_handle: Handle,
  normal_handle:             Handle,
  displacement_handle:       Handle,
  emissive_handle:           Handle,
  albedo_value:              linalg.Vector4f32,
  metallic_value:            f32,
  roughness_value:           f32,
  emissive_value:            linalg.Vector4f32,
  fallback_buffer:           DataBuffer(MaterialFallbacks),
}

material_deinit :: proc(self: ^Material) {
  if self == nil {
    return
  }
  // Descriptor sets are freed with the pool, we can get away ignoring the unused descriptor sets
  // TODO: when descriptor set count get too big, consider manually deallocate
  self.texture_descriptor_set = 0
  for &set in self.skinning_descriptor_sets do set = 0
  data_buffer_deinit(&self.fallback_buffer)
}

material_init_descriptor_set_layout :: proc(
  mat: ^Material,
  texture_descriptor_set_layout: vk.DescriptorSetLayout,
  skinning_descriptor_set_layout: vk.DescriptorSetLayout,
) -> vk.Result {
  texture_layout := texture_descriptor_set_layout
  skinning_layout := skinning_descriptor_set_layout
  vk.AllocateDescriptorSets(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &texture_layout,
    },
    &mat.texture_descriptor_set,
  ) or_return
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

material_update_textures :: proc(
  mat: ^Material,
  albedo: ^ImageBuffer = nil,
  metallic_roughness: ^ImageBuffer = nil,
  normal: ^ImageBuffer = nil,
  displacement: ^ImageBuffer = nil,
  emissive: ^ImageBuffer = nil,
) -> vk.Result {
  if mat.texture_descriptor_set == 0 {
    return .ERROR_INITIALIZATION_FAILED
  }
  writes: [dynamic]vk.WriteDescriptorSet
  if albedo != nil {
    append(
      &writes,
      vk.WriteDescriptorSet {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = mat.texture_descriptor_set,
        dstBinding = 0,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = 1,
        pImageInfo = &{
          sampler = g_linear_repeat_sampler,
          imageView = albedo.view,
          imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        },
      },
    )
  }
  if metallic_roughness != nil {
    append(
      &writes,
      vk.WriteDescriptorSet {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = mat.texture_descriptor_set,
        dstBinding = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = 1,
        pImageInfo = &{
          sampler = g_linear_repeat_sampler,
          imageView = metallic_roughness.view,
          imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        },
      },
    )
  }
  if normal != nil {
    append(
      &writes,
      vk.WriteDescriptorSet {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = mat.texture_descriptor_set,
        dstBinding = 2,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = 1,
        pImageInfo = &{
          sampler = g_linear_repeat_sampler,
          imageView = normal.view,
          imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        },
      },
    )
  }
  if displacement != nil {
    append(
      &writes,
      vk.WriteDescriptorSet {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = mat.texture_descriptor_set,
        dstBinding = 3,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = 1,
        pImageInfo = &{
          sampler = g_linear_repeat_sampler,
          imageView = displacement.view,
          imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        },
      },
    )
  }
  if emissive != nil {
    append(
      &writes,
      vk.WriteDescriptorSet {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = mat.texture_descriptor_set,
        dstBinding = 4,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = 1,
        pImageInfo = &{
          sampler = g_linear_repeat_sampler,
          imageView = emissive.view,
          imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        },
      },
    )
  }
  append(
    &writes,
    vk.WriteDescriptorSet {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = mat.texture_descriptor_set,
      dstBinding = 5,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &vk.DescriptorBufferInfo {
        buffer = mat.fallback_buffer.buffer,
        offset = 0,
        range = size_of(MaterialFallbacks),
      },
    },
  )
  vk.UpdateDescriptorSets(g_device, u32(len(writes)), raw_data(writes), 0, nil)
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
