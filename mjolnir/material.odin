package mjolnir

import "core:fmt"
import linalg "core:math/linalg"
import "resource"
import vk "vendor:vulkan"

MaterialFallbacks :: struct {
  albedo:    linalg.Vector4f32,
  emissive:  linalg.Vector4f32,
  roughness: f32,
  metallic:  f32,
}

Material :: struct {
  texture_descriptor_set:    vk.DescriptorSet,
  skinning_descriptor_set:   vk.DescriptorSet,
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
  fallback_buffer:           DataBuffer,
}

material_deinit :: proc(self: ^Material) {
  if self == nil {
    return
  }
  if self.texture_descriptor_set != 0 {
    // Descriptor sets are freed with the pool, so do not explicitly destroy
    self.texture_descriptor_set = 0
  }
  if self.skinning_descriptor_set != 0 {
    self.skinning_descriptor_set = 0
  }
  data_buffer_deinit(&self.fallback_buffer)
}

material_init_descriptor_set_layout :: proc(mat: ^Material) -> vk.Result {
  alloc_info_texture := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = g_descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &texture_descriptor_set_layout,
  }
  vk.AllocateDescriptorSets(
    g_device,
    &alloc_info_texture,
    &mat.texture_descriptor_set,
  ) or_return
  alloc_info_skinning := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = g_descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &skinning_descriptor_set_layout,
  }
  vk.AllocateDescriptorSets(
    g_device,
    &alloc_info_skinning,
    &mat.skinning_descriptor_set,
  ) or_return
  return .SUCCESS
}

material_update_textures :: proc(
  mat: ^Material,
  albedo: ^Texture = nil,
  metallic_roughness: ^Texture = nil,
  normal: ^Texture = nil,
  displacement: ^Texture = nil,
  emissive: ^Texture = nil,
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
        pImageInfo = &vk.DescriptorImageInfo {
          sampler = albedo.sampler,
          imageView = albedo.buffer.view,
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
        pImageInfo = &vk.DescriptorImageInfo {
          sampler = metallic_roughness.sampler,
          imageView = metallic_roughness.buffer.view,
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
        pImageInfo = &vk.DescriptorImageInfo {
          sampler = normal.sampler,
          imageView = normal.buffer.view,
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
        pImageInfo = &vk.DescriptorImageInfo {
          sampler = displacement.sampler,
          imageView = displacement.buffer.view,
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
        pImageInfo = &vk.DescriptorImageInfo {
          sampler = emissive.sampler,
          imageView = emissive.buffer.view,
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
  mat: ^Material,
  buffer: vk.Buffer,
  size: vk.DeviceSize,
) {
  if mat.texture_descriptor_set == 0 {
    return
  }
  buffer_info := vk.DescriptorBufferInfo {
    buffer = buffer,
    offset = 0,
    range  = size,
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = mat.skinning_descriptor_set,
    dstBinding      = 0,
    descriptorType  = .STORAGE_BUFFER,
    descriptorCount = 1,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(g_device, 1, &write, 0, nil)
}

create_material :: proc(
  engine: ^Engine,
  features: ShaderFeatureSet = {},
  albedo_handle: Handle = {},
  metallic_roughness_handle: Handle = {},
  normal_handle: Handle = {},
  displacement_handle: Handle = {},
  emissive_handle: Handle = {},
  albedo_value: linalg.Vector4f32 = {1, 1, 1, 1},
  metallic_value: f32 = 0.0,
  roughness_value: f32 = 1.0,
  emissive_value: linalg.Vector4f32 = {},
) -> (
  ret: Handle,
  mat: ^Material,
  res: vk.Result,
) {
  ret, mat = resource.alloc(&engine.materials)
  mat.is_lit = true
  mat.features = features

  mat.albedo_handle = albedo_handle
  mat.metallic_roughness_handle = metallic_roughness_handle
  mat.normal_handle = normal_handle
  mat.displacement_handle = displacement_handle
  mat.emissive_handle = emissive_handle

  mat.albedo_value = albedo_value
  mat.metallic_value = metallic_value
  mat.roughness_value = roughness_value
  mat.emissive_value = emissive_value

  material_init_descriptor_set_layout(mat) or_return
  fallbacks := MaterialFallbacks {
    albedo    = mat.albedo_value,
    emissive  = mat.emissive_value,
    roughness = mat.roughness_value,
    metallic  = mat.metallic_value,
  }

  mat.fallback_buffer = create_host_visible_buffer(
    size_of(MaterialFallbacks),
    {.UNIFORM_BUFFER},
    &fallbacks,
  ) or_return

  albedo := resource.get(engine.textures, albedo_handle)
  metallic_roughness := resource.get(
    engine.textures,
    metallic_roughness_handle,
  )
  normal := resource.get(engine.textures, normal_handle)
  displacement := resource.get(engine.textures, displacement_handle)
  emissive := resource.get(engine.textures, emissive_handle)
  material_update_textures(
    mat,
    albedo,
    metallic_roughness,
    normal,
    displacement,
    emissive,
  ) or_return
  res = .SUCCESS
  return
}

create_unlit_material :: proc(
  engine: ^Engine,
  features: ShaderFeatureSet = {},
  albedo_handle: Handle = {},
  albedo_value: linalg.Vector4f32 = {1, 1, 1, 1},
) -> (
  ret: Handle,
  mat: ^Material,
  res: vk.Result,
) {
  ret, mat = resource.alloc(&engine.materials)
  mat.is_lit = false
  mat.features = features
  mat.albedo_handle = albedo_handle
  mat.albedo_value = albedo_value
  material_init_descriptor_set_layout(mat) or_return
  albedo := resource.get(engine.textures, albedo_handle)
  fallbacks := MaterialFallbacks {
    albedo = mat.albedo_value,
  }
  mat.fallback_buffer = create_host_visible_buffer(
    size_of(MaterialFallbacks),
    {.UNIFORM_BUFFER},
    &fallbacks,
  ) or_return
  material_update_textures(mat, albedo) or_return
  res = .SUCCESS
  return
}
