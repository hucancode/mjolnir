package mjolnir

import "core:log"
import vk "vendor:vulkan"

MAX_LIGHTS :: 10
SHADOW_MAP_SIZE :: 512
MAX_SHADOW_MAPS :: MAX_LIGHTS
MAX_SCENE_UNIFORMS :: 16

Frame :: struct {
  image_available_semaphore:      vk.Semaphore,
  render_finished_semaphore:      vk.Semaphore,
  fence:                          vk.Fence,
  command_buffer:                 vk.CommandBuffer,
  camera_uniform:                 DataBuffer(SceneUniform),
  light_uniform:                  DataBuffer(SceneLightUniform),
  shadow_maps:                    [MAX_SHADOW_MAPS]ImageBuffer,
  cube_shadow_maps:               [MAX_SHADOW_MAPS]CubeImageBuffer,
  camera_descriptor_set:          vk.DescriptorSet,
  shadow_map_descriptor_set:      vk.DescriptorSet,
  cube_shadow_map_descriptor_set: vk.DescriptorSet,
  main_pass_image:                ImageBuffer,
  postprocess_images:             [2]ImageBuffer,
}

frame_init :: proc(
  self: ^Frame,
  color_format: vk.Format,
  width: u32,
  height: u32,
  camera_descriptor_set_layout: vk.DescriptorSetLayout,
) -> (
  res: vk.Result,
) {
  vk.AllocateCommandBuffers(
    g_device,
    &{
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = g_command_pool,
      level = .PRIMARY,
      commandBufferCount = 1,
    },
    &self.command_buffer,
  ) or_return
  vk.CreateSemaphore(
    g_device,
    &{sType = .SEMAPHORE_CREATE_INFO},
    nil,
    &self.image_available_semaphore,
  ) or_return
  vk.CreateSemaphore(
    g_device,
    &{sType = .SEMAPHORE_CREATE_INFO},
    nil,
    &self.render_finished_semaphore,
  ) or_return
  vk.CreateFence(
    g_device,
    &{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}},
    nil,
    &self.fence,
  ) or_return
  self.camera_uniform = create_host_visible_buffer(
    SceneUniform,
    (1 + 6 * MAX_SCENE_UNIFORMS),
    {.UNIFORM_BUFFER},
  ) or_return
  self.light_uniform = create_host_visible_buffer(
    SceneLightUniform,
    1,
    {.UNIFORM_BUFFER},
  ) or_return
  for i in 0 ..< MAX_SHADOW_MAPS {
    depth_image_init(
      &self.shadow_maps[i],
      SHADOW_MAP_SIZE,
      SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
    cube_depth_texture_init(
      &self.cube_shadow_maps[i],
      SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
  }
  layout := camera_descriptor_set_layout
  vk.AllocateDescriptorSets(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &layout,
    },
    &self.camera_descriptor_set,
  ) or_return
  shadow_map_image_infos: [MAX_SHADOW_MAPS]vk.DescriptorImageInfo
  for i in 0 ..< MAX_SHADOW_MAPS {
    shadow_map_image_infos[i] = {
      sampler     = g_linear_clamp_sampler,
      imageView   = self.shadow_maps[i].view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }
  }
  cube_shadow_map_image_infos: [MAX_SHADOW_MAPS]vk.DescriptorImageInfo
  for i in 0 ..< MAX_SHADOW_MAPS {
    cube_shadow_map_image_infos[i] = {
      sampler     = g_linear_clamp_sampler,
      imageView   = self.cube_shadow_maps[i].view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }
  }
  writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.camera_descriptor_set,
      dstBinding = 0,
      descriptorType = .UNIFORM_BUFFER_DYNAMIC,
      descriptorCount = 1,
      pBufferInfo = &{
        buffer = self.camera_uniform.buffer,
        range = vk.DeviceSize(size_of(SceneUniform)),
      },
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.camera_descriptor_set,
      dstBinding = 1,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &{
        buffer = self.light_uniform.buffer,
        range = vk.DeviceSize(size_of(SceneLightUniform)),
      },
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.camera_descriptor_set,
      dstBinding = 2,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = MAX_SHADOW_MAPS,
      pImageInfo = raw_data(shadow_map_image_infos[:]),
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.camera_descriptor_set,
      dstBinding = 3,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = MAX_SHADOW_MAPS,
      pImageInfo = raw_data(cube_shadow_map_image_infos[:]),
    },
  }
  vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
  frame_init_images(self, width, height, color_format)
  return .SUCCESS
}

frame_init_images :: proc(
  self: ^Frame,
  width: u32,
  height: u32,
  color_format: vk.Format,
) -> vk.Result {
  self.main_pass_image = malloc_image_buffer(
    width,
    height,
    color_format,
    .OPTIMAL,
    {.COLOR_ATTACHMENT, .SAMPLED, .TRANSFER_SRC, .TRANSFER_DST},
    {.DEVICE_LOCAL},
  ) or_return
  self.main_pass_image.view = create_image_view(
    self.main_pass_image.image,
    color_format,
    {.COLOR},
  ) or_return
  for &image in self.postprocess_images {
    image = malloc_image_buffer(
      width,
      height,
      color_format,
      .OPTIMAL,
      {.COLOR_ATTACHMENT, .SAMPLED, .TRANSFER_SRC, .TRANSFER_DST},
      {.DEVICE_LOCAL},
    ) or_return
    image.view = create_image_view(
      image.image,
      color_format,
      {.COLOR},
    ) or_return
  }
  return .SUCCESS
}

frame_deinit :: proc(self: ^Frame) {
  vk.DestroySemaphore(g_device, self.image_available_semaphore, nil)
  vk.DestroySemaphore(g_device, self.render_finished_semaphore, nil)
  vk.DestroyFence(g_device, self.fence, nil)
  vk.FreeCommandBuffers(g_device, g_command_pool, 1, &self.command_buffer)
  data_buffer_deinit(&self.camera_uniform)
  data_buffer_deinit(&self.light_uniform)
  for i in 0 ..< MAX_SHADOW_MAPS {
    image_buffer_deinit(&self.shadow_maps[i])
    cube_depth_texture_deinit(&self.cube_shadow_maps[i])
  }
  frame_deinit_images(self)
}

frame_deinit_images :: proc(self: ^Frame) {
  image_buffer_deinit(&self.main_pass_image)
  for &image in self.postprocess_images {
    image_buffer_deinit(&image)
  }
}
