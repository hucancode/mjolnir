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
  ctx:                       ^VulkanContext,
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
  if self == nil || self.ctx == nil {
    return
  }
  vkd := self.ctx.vkd
  if self.texture_descriptor_set != 0 {
    // Descriptor sets are freed with the pool, so do not explicitly destroy
    self.texture_descriptor_set = 0
  }
  if self.skinning_descriptor_set != 0 {
    self.skinning_descriptor_set = 0
  }
  data_buffer_deinit(&self.fallback_buffer, self.ctx)
}

material_init_descriptor_set_layout :: proc(
  mat: ^Material,
  ctx: ^VulkanContext,
) -> vk.Result {
  alloc_info_texture := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = ctx.descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &texture_descriptor_set_layout,
  }
  vk.AllocateDescriptorSets(
    ctx.vkd,
    &alloc_info_texture,
    &mat.texture_descriptor_set,
  ) or_return
  alloc_info_skinning := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = ctx.descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &skinning_descriptor_set_layout,
  }
  vk.AllocateDescriptorSets(
    ctx.vkd,
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
  if mat.ctx == nil || mat.texture_descriptor_set == 0 {
    return .ERROR_INITIALIZATION_FAILED
  }

  image_infos := [?]vk.DescriptorImageInfo {
    {
      sampler = albedo.sampler if albedo != nil else 0,
      imageView = albedo.buffer.view if albedo != nil else 0,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
    {
      sampler = metallic_roughness.sampler if metallic_roughness != nil else 0,
      imageView = metallic_roughness.buffer.view if metallic_roughness != nil else 0,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
    {
      sampler = normal.sampler if normal != nil else 0,
      imageView = normal.buffer.view if normal != nil else 0,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
    {
      sampler = displacement.sampler if displacement != nil else 0,
      imageView = displacement.buffer.view if displacement != nil else 0,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
    {
      sampler = emissive.sampler if emissive != nil else 0,
      imageView = emissive.buffer.view if emissive != nil else 0,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
  }
  fallbacks := MaterialFallbacks {
    albedo    = mat.albedo_value,
    emissive  = mat.emissive_value,
    roughness = mat.roughness_value,
    metallic  = mat.metallic_value,
  }
  mat.fallback_buffer = create_host_visible_buffer(
    mat.ctx,
    size_of(MaterialFallbacks),
    {.UNIFORM_BUFFER},
    &fallbacks,
  ) or_return

  writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = mat.texture_descriptor_set,
      dstBinding = 0,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[0],
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = mat.texture_descriptor_set,
      dstBinding = 1,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[1],
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = mat.texture_descriptor_set,
      dstBinding = 2,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[2],
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = mat.texture_descriptor_set,
      dstBinding = 3,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[3],
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = mat.texture_descriptor_set,
      dstBinding = 4,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &image_infos[4],
    },
    {
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
  }

  vk.UpdateDescriptorSets(
    mat.ctx.vkd,
    len(writes),
    raw_data(writes[:]),
    0,
    nil,
  )
  return .SUCCESS
}

material_update_bone_buffer :: proc(
  mat: ^Material,
  buffer: vk.Buffer,
  size: vk.DeviceSize,
) {
  if mat.ctx == nil || mat.texture_descriptor_set == 0 {
    return
  }
  vkd := mat.ctx.vkd

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
  vk.UpdateDescriptorSets(vkd, 1, &write, 0, nil)
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
  mat.ctx = &engine.ctx
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

  material_init_descriptor_set_layout(mat, &engine.ctx) or_return
  albedo := resource.get(&engine.textures, albedo_handle)
  metallic_roughness := resource.get(
    &engine.textures,
    metallic_roughness_handle,
  )
  normal := resource.get(&engine.textures, normal_handle)
  displacement := resource.get(&engine.textures, displacement_handle)
  emissive := resource.get(&engine.textures, emissive_handle)
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
  mat.ctx = &engine.ctx
  mat.is_lit = false
  mat.features = features
  mat.albedo_handle = albedo_handle
  mat.albedo_value = albedo_value
  material_init_descriptor_set_layout(mat, &engine.ctx) or_return
  albedo := resource.get(&engine.textures, albedo_handle)
  material_update_textures(mat, albedo) or_return
  res = .SUCCESS
  return
}
