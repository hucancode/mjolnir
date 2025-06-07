package mjolnir

import "core:fmt"
import "core:log"
import "core:math"
import linalg "core:math/linalg"
import "core:slice"
import "core:time"
import "geometry"
import "resource"
import glfw "vendor:glfw"
import mu "vendor:microui"
import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 2

MAX_LIGHTS :: 10
SHADOW_MAP_SIZE :: 512
MAX_SHADOW_MAPS :: MAX_LIGHTS
MAX_SCENE_UNIFORMS :: 16

SingleLightUniform :: struct {
  view_proj:  linalg.Matrix4f32,
  color:      linalg.Vector4f32,
  position:   linalg.Vector4f32,
  direction:  linalg.Vector4f32,
  kind:       enum u32 {
    POINT       = 0,
    DIRECTIONAL = 1,
    SPOT        = 2,
  },
  angle:      f32, // For spotlight: cone angle
  radius:     f32, // For point/spot: attenuation radius
  has_shadow: b32,
}

SceneUniform :: struct {
  view:       linalg.Matrix4f32,
  projection: linalg.Matrix4f32,
  time:       f32,
}

SceneLightUniform :: struct {
  lights:      [MAX_LIGHTS]SingleLightUniform,
  light_count: u32,
}

push_light :: proc(self: ^SceneLightUniform, light: SingleLightUniform) {
  if self.light_count < MAX_LIGHTS {
    self.lights[self.light_count] = light
    self.light_count += 1
  }
}

clear_lights :: proc(self: ^SceneLightUniform) {
  self.light_count = 0
}

Frame :: struct {
  image_available_semaphore:      vk.Semaphore,
  render_finished_semaphore:      vk.Semaphore,
  fence:                          vk.Fence,
  command_buffer:                 vk.CommandBuffer,
  camera_uniform:                 DataBuffer(SceneUniform),
  light_uniform:                  DataBuffer(SceneLightUniform),
  shadow_maps:                    [MAX_SHADOW_MAPS]DepthTexture,
  cube_shadow_maps:               [MAX_SHADOW_MAPS]CubeDepthTexture,
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
) -> (
  res: vk.Result,
) {
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
    depth_texture_init(
      &self.shadow_maps[i],
      SHADOW_MAP_SIZE,
      SHADOW_MAP_SIZE,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
    cube_depth_texture_init(
      &self.cube_shadow_maps[i],
      SHADOW_MAP_SIZE,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
  }

  vk.AllocateDescriptorSets(
    g_device,
    &vk.DescriptorSetAllocateInfo {
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &g_camera_descriptor_set_layout,
    },
    &self.camera_descriptor_set,
  ) or_return

  scene_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.camera_uniform.buffer,
    offset = 0,
    range  = vk.DeviceSize(size_of(SceneUniform)),
  }
  light_buffer_info := vk.DescriptorBufferInfo {
    buffer = self.light_uniform.buffer,
    offset = 0,
    range  = vk.DeviceSize(size_of(SceneLightUniform)),
  }
  shadow_map_image_infos: [MAX_SHADOW_MAPS]vk.DescriptorImageInfo
  for i in 0 ..< MAX_SHADOW_MAPS {
    shadow_map_image_infos[i] = vk.DescriptorImageInfo {
      sampler     = self.shadow_maps[i].sampler,
      imageView   = self.shadow_maps[i].buffer.view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }
  }
  cube_shadow_map_image_infos: [MAX_SHADOW_MAPS]vk.DescriptorImageInfo
  for i in 0 ..< MAX_SHADOW_MAPS {
    cube_shadow_map_image_infos[i] = vk.DescriptorImageInfo {
      sampler     = self.cube_shadow_maps[i].sampler,
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
      pBufferInfo = &scene_buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.camera_descriptor_set,
      dstBinding = 1,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &light_buffer_info,
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
    depth_texture_deinit(&self.shadow_maps[i])
    cube_depth_texture_deinit(&self.cube_shadow_maps[i])
  }
}

Renderer :: struct {
  swapchain:                  vk.SwapchainKHR,
  format:                     vk.SurfaceFormatKHR,
  extent:                     vk.Extent2D,
  swapchain_images:           []vk.Image,
  swapchain_views:            []vk.ImageView,
  frames:                     [MAX_FRAMES_IN_FLIGHT]Frame,
  depth_buffer:               ImageBuffer,
  environment_map:            ^Texture,
  environment_map_handle:     Handle,
  environment_descriptor_set: vk.DescriptorSet,
  brdf_lut_handle:            Handle,
  brdf_lut:                   ^Texture,
  current_frame_index:        u32,
  particle_render:            ParticleRenderPipeline,
}

renderer_init :: proc(
  self: ^Renderer,
  window: glfw.WindowHandle,
) -> vk.Result {
  create_swapchain(self, window) or_return
  alloc_info := vk.CommandBufferAllocateInfo {
    sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool        = g_command_pool,
    level              = .PRIMARY,
    commandBufferCount = 1,
  }
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    vk.AllocateCommandBuffers(
      g_device,
      &alloc_info,
      &self.frames[i].command_buffer,
    ) or_return
  }
  semaphore_info := vk.SemaphoreCreateInfo {
    sType = .SEMAPHORE_CREATE_INFO,
  }
  fence_info := vk.FenceCreateInfo {
    sType = .FENCE_CREATE_INFO,
    flags = {.SIGNALED},
  }
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    frame := &self.frames[i]
    vk.CreateSemaphore(
      g_device,
      &semaphore_info,
      nil,
      &frame.image_available_semaphore,
    ) or_return
    vk.CreateSemaphore(
      g_device,
      &semaphore_info,
      nil,
      &frame.render_finished_semaphore,
    ) or_return
    vk.CreateFence(g_device, &fence_info, nil, &frame.fence) or_return
  }
  self.depth_buffer = create_depth_image(
    self.extent.width,
    self.extent.height,
  ) or_return
  self.current_frame_index = 0
  for &frame in self.frames {
    frame_init(
      &frame,
      self.format.format,
      self.extent.width,
      self.extent.height,
    ) or_return
  }
  // Initialize particle render pipeline
  self.particle_render = setup_particle_render_pipeline() or_return
  return .SUCCESS
}

renderer_deinit :: proc(self: ^Renderer) {
  vk.DeviceWaitIdle(g_device)
  destroy_particle_render_pipeline(&self.particle_render)
  destroy_swapchain(self)
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT do frame_deinit(&self.frames[i])

  vk.DestroyDescriptorSetLayout(g_device, g_camera_descriptor_set_layout, nil)
}

recreate_swapchain :: proc(
  self: ^Renderer,
  window: glfw.WindowHandle,
) -> vk.Result {
  vk.DeviceWaitIdle(g_device)
  destroy_swapchain(self)
  create_swapchain(self, window) or_return
  return .SUCCESS
}

create_swapchain :: proc(
  self: ^Renderer,
  window: glfw.WindowHandle,
) -> vk.Result {
  pick_swap_present_mode :: proc(
    present_modes: []vk.PresentModeKHR,
  ) -> vk.PresentModeKHR {
    return(
      .MAILBOX if slice.contains(present_modes, vk.PresentModeKHR.MAILBOX) else .FIFO \
    )
  }
  pick_swapchain_format :: proc(
    formats: []vk.SurfaceFormatKHR,
  ) -> vk.SurfaceFormatKHR {
    ret := vk.SurfaceFormatKHR{.B8G8R8A8_SRGB, .SRGB_NONLINEAR}
    if len(formats) == 0 {
      log.infof("No surface formats available for swapchain.")
      return ret
    }
    return ret if slice.contains(formats, ret) else formats[0]
  }
  pick_swapchain_extent :: proc(
    capabilities: vk.SurfaceCapabilitiesKHR,
    actual_width, actual_height: u32,
  ) -> vk.Extent2D {
    if capabilities.currentExtent.width != math.max(u32) {
      return capabilities.currentExtent
    }
    return {
      math.clamp(
        actual_width,
        capabilities.minImageExtent.width,
        capabilities.maxImageExtent.width,
      ),
      math.clamp(
        actual_height,
        capabilities.minImageExtent.height,
        capabilities.maxImageExtent.height,
      ),
    }
  }
  width, height := glfw.GetFramebufferSize(window)
  support := query_swapchain_support(g_physical_device, g_surface) or_return
  defer swapchain_support_deinit(&support)
  self.format = pick_swapchain_format(support.formats)
  self.extent = pick_swapchain_extent(
    support.capabilities,
    u32(width),
    u32(height),
  )
  image_count := support.capabilities.minImageCount + 1
  if support.capabilities.maxImageCount > 0 &&
     image_count > support.capabilities.maxImageCount {
    image_count = support.capabilities.maxImageCount
  }
  create_info := vk.SwapchainCreateInfoKHR {
    sType            = .SWAPCHAIN_CREATE_INFO_KHR,
    surface          = g_surface,
    minImageCount    = image_count,
    imageFormat      = self.format.format,
    imageColorSpace  = self.format.colorSpace,
    imageExtent      = self.extent,
    imageArrayLayers = 1,
    imageUsage       = {.COLOR_ATTACHMENT},
    preTransform     = support.capabilities.currentTransform,
    compositeAlpha   = {.OPAQUE},
    presentMode      = pick_swap_present_mode(support.present_modes),
    clipped          = true,
  }
  queue_family_indices := [2]u32{g_graphics_family, g_present_family}
  if g_graphics_family != g_present_family {
    create_info.imageSharingMode = .CONCURRENT
    create_info.queueFamilyIndexCount = 2
    create_info.pQueueFamilyIndices = raw_data(queue_family_indices[:])
  } else {
    create_info.imageSharingMode = .EXCLUSIVE
  }
  vk.CreateSwapchainKHR(g_device, &create_info, nil, &self.swapchain) or_return
  swapchain_image_count: u32
  vk.GetSwapchainImagesKHR(
    g_device,
    self.swapchain,
    &swapchain_image_count,
    nil,
  )
  self.swapchain_images = make([]vk.Image, swapchain_image_count)
  vk.GetSwapchainImagesKHR(
    g_device,
    self.swapchain,
    &swapchain_image_count,
    raw_data(self.swapchain_images),
  )
  self.swapchain_views = make([]vk.ImageView, swapchain_image_count)
  for i in 0 ..< swapchain_image_count {
    self.swapchain_views[i] = create_image_view(
      self.swapchain_images[i],
      self.format.format,
      {.COLOR},
    ) or_return
  }
  depth_format := vk.Format.D32_SFLOAT
  self.depth_buffer = malloc_image_buffer(
    self.extent.width,
    self.extent.height,
    depth_format,
    .OPTIMAL,
    {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    {.DEVICE_LOCAL},
  ) or_return
  self.depth_buffer.view = create_image_view(
    self.depth_buffer.image,
    self.depth_buffer.format,
    {.DEPTH},
  ) or_return
  return .SUCCESS
}

destroy_swapchain :: proc(self: ^Renderer) {
  image_buffer_deinit(&self.depth_buffer)
  for view in self.swapchain_views do vk.DestroyImageView(g_device, view, nil)
  delete(self.swapchain_views)
  self.swapchain_views = nil
  delete(self.swapchain_images)
  self.swapchain_images = nil
  vk.DestroySwapchainKHR(g_device, self.swapchain, nil)
  self.swapchain = 0
}

renderer_get_in_flight_fence :: proc(self: ^Renderer) -> vk.Fence {
  return self.frames[self.current_frame_index].fence
}

renderer_get_image_available_semaphore :: proc(
  self: ^Renderer,
) -> vk.Semaphore {
  return self.frames[self.current_frame_index].image_available_semaphore
}

renderer_get_render_finished_semaphore :: proc(
  self: ^Renderer,
) -> vk.Semaphore {
  return self.frames[self.current_frame_index].render_finished_semaphore
}

renderer_get_command_buffer :: proc(self: ^Renderer) -> vk.CommandBuffer {
  if self == nil {
    log.errorf("Error: Renderer is nil in get_command_buffer_renderer")
    return vk.CommandBuffer{}
  }
  if self.current_frame_index >= len(self.frames) {
    log.errorf(
      "Error: Invalid frame index",
      self.current_frame_index,
      "vs",
      len(self.frames),
    )
    return vk.CommandBuffer{}
  }
  cmd_buffer := self.frames[self.current_frame_index].command_buffer
  if cmd_buffer == nil {
    log.errorf(
      "Error: Command buffer is nil for frame",
      self.current_frame_index,
    )
    return vk.CommandBuffer{}
  }
  return cmd_buffer
}

renderer_get_main_pass_image :: proc(self: ^Renderer) -> vk.Image {
  return self.frames[self.current_frame_index].main_pass_image.image
}

renderer_get_main_pass_view :: proc(self: ^Renderer) -> vk.ImageView {
  return self.frames[self.current_frame_index].main_pass_image.view
}

renderer_get_postprocess_pass_image :: proc(
  self: ^Renderer,
  i: int,
) -> vk.Image {
  return self.frames[self.current_frame_index].postprocess_images[i].image
}

renderer_get_postprocess_pass_view :: proc(
  self: ^Renderer,
  i: int,
) -> vk.ImageView {
  return self.frames[self.current_frame_index].postprocess_images[i].view
}

renderer_get_camera_uniform :: proc(
  self: ^Renderer,
) -> ^DataBuffer(SceneUniform) {
  return &self.frames[self.current_frame_index].camera_uniform
}

renderer_get_light_uniform :: proc(
  self: ^Renderer,
) -> ^DataBuffer(SceneLightUniform) {
  return &self.frames[self.current_frame_index].light_uniform
}

renderer_get_shadow_map :: proc(
  self: ^Renderer,
  light_idx: int,
) -> ^DepthTexture {
  return &self.frames[self.current_frame_index].shadow_maps[light_idx]
}

renderer_get_cube_shadow_map :: proc(
  self: ^Renderer,
  light_idx: int,
) -> ^CubeDepthTexture {
  return &self.frames[self.current_frame_index].cube_shadow_maps[light_idx]
}

renderer_get_camera_descriptor_set :: proc(
  self: ^Renderer,
) -> vk.DescriptorSet {
  return self.frames[self.current_frame_index].camera_descriptor_set
}

renderer_get_shadow_map_descriptor_set :: proc(
  self: ^Renderer,
) -> vk.DescriptorSet {
  return self.frames[self.current_frame_index].shadow_map_descriptor_set
}

renderer_get_cube_shadow_map_descriptor_set :: proc(
  self: ^Renderer,
) -> vk.DescriptorSet {
  return self.frames[self.current_frame_index].cube_shadow_map_descriptor_set
}

prepare_light :: proc(node: ^Node, cb_context: rawptr) -> bool {
  ctx := (^CollectLightsContext)(cb_context)
  uniform: SingleLightUniform
  #partial switch data in node.attachment {
  case PointLightAttachment:
    uniform.kind = .POINT
    uniform.color = data.color
    uniform.radius = data.radius
    uniform.has_shadow = b32(data.cast_shadow)
    uniform.position =
      node.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
    push_light(ctx.light_uniform, uniform)
  case DirectionalLightAttachment:
    uniform.kind = .DIRECTIONAL
    uniform.color = data.color
    uniform.has_shadow = b32(data.cast_shadow)
    uniform.position =
      node.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
    uniform.direction =
      node.transform.world_matrix * linalg.Vector4f32{0, 0, 1, 0} // Assuming +Z is forward
    push_light(ctx.light_uniform, uniform)
  case SpotLightAttachment:
    uniform.kind = .SPOT
    uniform.color = data.color
    uniform.radius = data.radius
    uniform.has_shadow = b32(data.cast_shadow)
    uniform.angle = data.angle
    uniform.position =
      node.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
    uniform.direction =
      node.transform.world_matrix * linalg.Vector4f32{0, 0, 1, 0}
    push_light(ctx.light_uniform, uniform)
  }
  return true
}

render_single_node :: proc(node: ^Node, cb_context: rawptr) -> bool {
  ctx := (^RenderMeshesContext)(cb_context)
  frame := ctx.engine.renderer.current_frame_index
  #partial switch data in node.attachment {
  case MeshAttachment:
    mesh := resource.get(ctx.engine.meshes, data.handle)
    if mesh == nil {
      return true
    }
    material := resource.get(ctx.engine.materials, data.material)
    if material == nil {
      return true
    }
    world_aabb := geometry.aabb_transform(
      mesh.aabb,
      node.transform.world_matrix,
    )
    if !geometry.frustum_test_aabb(&ctx.camera_frustum, world_aabb) {
      return true
    }
    pipeline :=
      g_pipelines[transmute(u32)material.features] if material.is_lit else g_unlit_pipelines[transmute(u32)material.features]
    layout := g_pipeline_layout
    descriptor_sets := [?]vk.DescriptorSet {
      renderer_get_camera_descriptor_set(&ctx.engine.renderer), // set 0
      material.texture_descriptor_set, // set 1
      material.skinning_descriptor_sets[frame], // set 2
      ctx.engine.renderer.environment_descriptor_set, // set 3
    }
    offsets := [1]u32{0}
    vk.CmdBindPipeline(ctx.command_buffer, .GRAPHICS, pipeline)
    vk.CmdBindDescriptorSets(
      ctx.command_buffer,
      .GRAPHICS,
      layout,
      0,
      u32(len(descriptor_sets)),
      raw_data(descriptor_sets[:]),
      len(offsets),
      raw_data(offsets[:]),
    )
    vk.CmdPushConstants(
      ctx.command_buffer,
      layout,
      {.VERTEX},
      0,
      size_of(linalg.Matrix4f32),
      &node.transform.world_matrix,
    )
    offset: vk.DeviceSize = 0
    vk.CmdBindVertexBuffers(
      ctx.command_buffer,
      0,
      1,
      &mesh.vertex_buffer.buffer,
      &offset,
    )
    mesh_skinning, mesh_has_skin := &mesh.skinning.?
    node_skinning, node_has_skin := data.skinning.?
    if mesh_has_skin && node_has_skin {
      material_update_bone_buffer(
        material,
        node_skinning.bone_buffers[frame].buffer,
        vk.DeviceSize(node_skinning.bone_buffers[frame].bytes_count),
        frame,
      )
      vk.CmdBindVertexBuffers(
        ctx.command_buffer,
        1,
        1,
        &mesh_skinning.skin_buffer.buffer,
        &offset,
      )
    }
    vk.CmdBindIndexBuffer(
      ctx.command_buffer,
      mesh.index_buffer.buffer,
      0,
      .UINT32,
    )
    vk.CmdDrawIndexed(ctx.command_buffer, mesh.indices_len, 1, 0, 0, 0)
    ctx.rendered_count^ += 1
  }
  return true
}

render_single_shadow :: proc(node: ^Node, cb_context: rawptr) -> bool {
  ctx := (^ShadowRenderContext)(cb_context)
  frame := ctx.engine.renderer.current_frame_index
  shadow_idx := ctx.shadow_idx
  shadow_layer := ctx.shadow_layer
  #partial switch data in node.attachment {
  case MeshAttachment:
    if !data.cast_shadow {
      return true
    }
    mesh := resource.get(ctx.engine.meshes, data.handle)
    if mesh == nil {
      return true
    }
    mesh_skinning, mesh_has_skin := &mesh.skinning.?
    node_skinning, node_has_skin := data.skinning.?
    world_aabb := geometry.aabb_transform(
      mesh.aabb,
      node.transform.world_matrix,
    )
    if !geometry.frustum_test_aabb(&ctx.frustum, world_aabb) {
      return true
    }
    material := resource.get(ctx.engine.materials, data.material)
    if material == nil {
      return true
    }
    features: ShaderFeatureSet
    pipeline := g_shadow_pipelines[transmute(u32)features]
    layout := g_shadow_pipeline_layout
    descriptor_sets: []vk.DescriptorSet
    if mesh_has_skin {
      pipeline = g_shadow_pipelines[transmute(u32)ShaderFeatureSet{.SKINNING}]
      descriptor_sets = {
        renderer_get_camera_descriptor_set(&ctx.engine.renderer), // set 0
        material.skinning_descriptor_sets[frame], // set 1
      }
    } else {
      descriptor_sets = {
        renderer_get_camera_descriptor_set(&ctx.engine.renderer), // set 0
      }
    }
    vk.CmdBindPipeline(ctx.command_buffer, .GRAPHICS, pipeline)
    offset_shadow := data_buffer_offset_of(
      renderer_get_camera_uniform(&ctx.engine.renderer)^,
      1 + shadow_idx * 6 + shadow_layer,
    )
    offsets := [1]u32{offset_shadow}
    vk.CmdBindDescriptorSets(
      ctx.command_buffer,
      .GRAPHICS,
      layout,
      0,
      u32(len(descriptor_sets)),
      raw_data(descriptor_sets[:]),
      len(offsets),
      raw_data(offsets[:]),
    )
    vk.CmdPushConstants(
      ctx.command_buffer,
      layout,
      {.VERTEX},
      0,
      size_of(linalg.Matrix4f32),
      &node.transform.world_matrix,
    )
    offset: vk.DeviceSize = 0
    vk.CmdBindVertexBuffers(
      ctx.command_buffer,
      0,
      1,
      &mesh.vertex_buffer.buffer,
      &offset,
    )
    if mesh_has_skin && node_has_skin {
      material_update_bone_buffer(
        material,
        node_skinning.bone_buffers[frame].buffer,
        vk.DeviceSize(node_skinning.bone_buffers[frame].bytes_count),
        frame,
      )
      vk.CmdBindVertexBuffers(
        ctx.command_buffer,
        1,
        1,
        &mesh_skinning.skin_buffer.buffer,
        &offset,
      )
    }
    vk.CmdBindIndexBuffer(
      ctx.command_buffer,
      mesh.index_buffer.buffer,
      0,
      .UINT32,
    )
    vk.CmdDrawIndexed(ctx.command_buffer, mesh.indices_len, 1, 0, 0, 0)
    ctx.obstacles_count^ += 1
  }
  return true
}

render :: proc(engine: ^Engine) -> vk.Result {
  current_fence := renderer_get_in_flight_fence(&engine.renderer)
  log.debug("waiting for fence...")
  vk.WaitForFences(g_device, 1, &current_fence, true, math.max(u64)) or_return
  image_idx: u32
  current_image_available_semaphore := renderer_get_image_available_semaphore(
    &engine.renderer,
  )
  log.debug("aquiring next image...")
  vk.AcquireNextImageKHR(
    g_device,
    engine.renderer.swapchain,
    math.max(u64),
    current_image_available_semaphore,
    0,
    &image_idx,
  ) or_return
  log.debug("reseting fence...")
  vk.ResetFences(g_device, 1, &current_fence) or_return
  mu.begin(&engine.ui.ctx)
  command_buffer := renderer_get_command_buffer(&engine.renderer)
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  begin_info := vk.CommandBufferBeginInfo {
    sType = .COMMAND_BUFFER_BEGIN_INFO,
    flags = {.ONE_TIME_SUBMIT},
  }
  log.debug("begining command...")
  vk.BeginCommandBuffer(command_buffer, &begin_info) or_return

  elapsed_seconds := time.duration_seconds(time.since(engine.start_timestamp))
  scene_uniform := SceneUniform {
    view       = geometry.calculate_view_matrix(&engine.scene.camera),
    projection = geometry.calculate_projection_matrix(&engine.scene.camera),
    time       = f32(elapsed_seconds),
  }
  light_uniform: SceneLightUniform
  camera_frustum := geometry.camera_make_frustum(&engine.scene.camera)
  collect_ctx := CollectLightsContext {
    engine        = engine,
    light_uniform = &light_uniform,
  }
  if !traverse_scene(&engine.scene, &collect_ctx, prepare_light) {
    log.errorf("[RENDER] Error during light collection")
  }
  log.debug("============ rendering shadow pass...============ ")
  render_shadow_pass(engine, &light_uniform, command_buffer) or_return
  log.debug("============ rendering main pass... =============")
  prepare_image_for_render(
    command_buffer,
    renderer_get_main_pass_image(&engine.renderer),
  )
  render_main_pass(engine, command_buffer, camera_frustum) or_return
  data_buffer_write(
    renderer_get_camera_uniform(&engine.renderer)^,
    &scene_uniform,
  )
  data_buffer_write(
    renderer_get_light_uniform(&engine.renderer)^,
    &light_uniform,
  )
  if engine.render2d_proc != nil {
    engine.render2d_proc(engine, &engine.ui.ctx)
  }
  mu.end(&engine.ui.ctx)
  ui_render(&engine.ui, command_buffer)
  vk.CmdEndRenderingKHR(command_buffer)
  prepare_image_for_shader_read(
    command_buffer,
    renderer_get_main_pass_image(&engine.renderer),
  )
  prepare_image_for_render(
    command_buffer,
    engine.renderer.swapchain_images[image_idx],
  )
  log.debug("============ rendering post processes... =============")
  render_postprocess_stack(
    &engine.renderer,
    command_buffer,
    renderer_get_main_pass_view(&engine.renderer), // postprocess input
    engine.renderer.swapchain_views[image_idx], // final output view
    engine.renderer.extent,
  )
  prepare_image_for_present(
    command_buffer,
    engine.renderer.swapchain_images[image_idx],
  )

  vk.EndCommandBuffer(command_buffer) or_return
  current_render_finished_semaphore := renderer_get_render_finished_semaphore(
    &engine.renderer,
  )
  wait_stage_mask: vk.PipelineStageFlags = {.COLOR_ATTACHMENT_OUTPUT}
  submit_info := vk.SubmitInfo {
    sType                = .SUBMIT_INFO,
    waitSemaphoreCount   = 1,
    pWaitSemaphores      = &current_image_available_semaphore,
    pWaitDstStageMask    = &wait_stage_mask,
    commandBufferCount   = 1,
    pCommandBuffers      = &command_buffer,
    signalSemaphoreCount = 1,
    pSignalSemaphores    = &current_render_finished_semaphore,
  }
  log.debug("============ submitting queue... =============")
  vk.QueueSubmit(g_graphics_queue, 1, &submit_info, current_fence) or_return
  image_indices := [?]u32{image_idx}
  present_info := vk.PresentInfoKHR {
    sType              = .PRESENT_INFO_KHR,
    waitSemaphoreCount = 1,
    pWaitSemaphores    = &current_render_finished_semaphore,
    swapchainCount     = 1,
    pSwapchains        = &engine.renderer.swapchain,
    pImageIndices      = raw_data(image_indices[:]),
  }
  log.debug("============ presenting image... =============")
  vk.QueuePresentKHR(g_present_queue, &present_info) or_return
  engine.renderer.current_frame_index =
    (engine.renderer.current_frame_index + 1) % MAX_FRAMES_IN_FLIGHT
  return .SUCCESS
}

render_shadow_pass :: proc(
  engine: ^Engine,
  light_uniform: ^SceneLightUniform,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  for i := 0; i < int(light_uniform.light_count); i += 1 {
    cube_shadow := renderer_get_cube_shadow_map(&engine.renderer, i)
    shadow_map_texture := renderer_get_shadow_map(&engine.renderer, i)
    // Transition shadow map to depth attachment
    initial_barriers := [2]vk.ImageMemoryBarrier {
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .UNDEFINED,
        newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = cube_shadow.buffer.image,
        subresourceRange = vk.ImageSubresourceRange {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 6,
        },
        dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      },
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .UNDEFINED,
        newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = shadow_map_texture.buffer.image,
        subresourceRange = vk.ImageSubresourceRange {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 1,
        },
        dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      },
    }
    vk.CmdPipelineBarrier(
      command_buffer,
      {.TOP_OF_PIPE},
      {.EARLY_FRAGMENT_TESTS},
      {},
      0,
      nil,
      0,
      nil,
      len(initial_barriers),
      raw_data(initial_barriers[:]),
    )
  }
  for i := 0; i < int(light_uniform.light_count); i += 1 {
    light := &light_uniform.lights[i]
    if !light.has_shadow || i >= MAX_SHADOW_MAPS {
      continue
    }
    if light.kind == .POINT {
      cube_shadow := renderer_get_cube_shadow_map(&engine.renderer, i)
      light_pos := light.position.xyz
      // Cube face directions and up vectors
      face_dirs := [6][3]f32 {
        {1, 0, 0},
        {-1, 0, 0},
        {0, 1, 0},
        {0, -1, 0},
        {0, 0, 1},
        {0, 0, -1},
      }
      face_ups := [6][3]f32 {
        {0, -1, 0},
        {0, -1, 0},
        {0, 0, 1},
        {0, 0, -1},
        {0, -1, 0},
        {0, -1, 0},
      }
      proj := linalg.matrix4_perspective(
        math.PI * 0.5,
        1.0,
        0.01,
        light.radius,
      )
      for face in 0 ..< 6 {
        view := linalg.matrix4_look_at(
          light_pos,
          light_pos + face_dirs[face],
          face_ups[face],
        )
        face_depth_attachment := vk.RenderingAttachmentInfoKHR {
          sType = .RENDERING_ATTACHMENT_INFO_KHR,
          imageView = cube_shadow.views[face],
          imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
          loadOp = .CLEAR,
          storeOp = .STORE,
          clearValue = vk.ClearValue{depthStencil = {depth = 1.0}},
        }
        face_render_info := vk.RenderingInfoKHR {
          sType = .RENDERING_INFO_KHR,
          renderArea = {
            extent = {
              width = cube_shadow.buffer.width,
              height = cube_shadow.buffer.height,
            },
          },
          layerCount = 1,
          pDepthAttachment = &face_depth_attachment,
        }
        viewport := vk.Viewport {
          width    = f32(cube_shadow.buffer.width),
          height   = f32(cube_shadow.buffer.height),
          minDepth = 0.0,
          maxDepth = 1.0,
        }
        scissor := vk.Rect2D {
          extent = {
            width = cube_shadow.buffer.width,
            height = cube_shadow.buffer.height,
          },
        }
        shadow_scene_uniform := SceneUniform {
          view       = view,
          projection = proj,
        }
        data_buffer_write(
          renderer_get_camera_uniform(&engine.renderer)^,
          &shadow_scene_uniform,
          i * 6 + face + 1,
        )
        vk.CmdBeginRenderingKHR(command_buffer, &face_render_info)
        vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
        vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
        obstacles_this_light: u32 = 0
        shadow_render_ctx := ShadowRenderContext {
          engine          = engine,
          command_buffer  = command_buffer,
          obstacles_count = &obstacles_this_light,
          shadow_idx      = u32(i),
          shadow_layer    = u32(face),
          frustum         = geometry.make_frustum(proj * view),
        }
        traverse_scene(&engine.scene, &shadow_render_ctx, render_single_shadow)
        vk.CmdEndRenderingKHR(command_buffer)
      }
    } else {
      shadow_map_texture := renderer_get_shadow_map(&engine.renderer, i)
      view: linalg.Matrix4f32
      proj: linalg.Matrix4f32
      if light.kind == .DIRECTIONAL {
        view = linalg.matrix4_look_at(
          light.position.xyz,
          light.position.xyz + light.direction.xyz,
          linalg.VECTOR3F32_Y_AXIS,
        )
        ortho_size: f32 = 20.0
        proj = linalg.matrix_ortho3d(
          -ortho_size,
          ortho_size,
          -ortho_size,
          ortho_size,
          0.1,
          light.radius,
        )
      } else {
        view = linalg.matrix4_look_at(
          light.position.xyz,
          light.position.xyz + light.direction.xyz,
          linalg.VECTOR3F32_X_AXIS,
          // TODO: hardcoding up vector will not work if the light is perfectly aligned with said vector
        )
        proj = linalg.matrix4_perspective(light.angle, 1.0, 0.01, light.radius)
      }
      light.view_proj = proj * view
      depth_attachment := vk.RenderingAttachmentInfoKHR {
        sType = .RENDERING_ATTACHMENT_INFO_KHR,
        imageView = shadow_map_texture.buffer.view,
        imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        loadOp = .CLEAR,
        storeOp = .STORE,
        clearValue = vk.ClearValue{depthStencil = {depth = 1.0}},
      }
      render_info_khr := vk.RenderingInfoKHR {
        sType = .RENDERING_INFO_KHR,
        renderArea = {
          extent = {
            width = shadow_map_texture.buffer.width,
            height = shadow_map_texture.buffer.height,
          },
        },
        layerCount = 1,
        pDepthAttachment = &depth_attachment,
      }
      shadow_scene_uniform := SceneUniform {
        view       = view,
        projection = proj,
      }
      data_buffer_write(
        renderer_get_camera_uniform(&engine.renderer)^,
        &shadow_scene_uniform,
        i * 6 + 1,
      )
      vk.CmdBeginRenderingKHR(command_buffer, &render_info_khr)
      viewport := vk.Viewport {
        width    = f32(shadow_map_texture.buffer.width),
        height   = f32(shadow_map_texture.buffer.height),
        minDepth = 0.0,
        maxDepth = 1.0,
      }
      scissor := vk.Rect2D {
        extent = {
          width = shadow_map_texture.buffer.width,
          height = shadow_map_texture.buffer.height,
        },
      }
      vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
      vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
      obstacles_this_light: u32 = 0
      shadow_render_ctx := ShadowRenderContext {
        engine          = engine,
        command_buffer  = command_buffer,
        obstacles_count = &obstacles_this_light,
        shadow_idx      = u32(i),
        frustum         = geometry.make_frustum(proj * view),
      }
      traverse_scene(&engine.scene, &shadow_render_ctx, render_single_shadow)
      vk.CmdEndRenderingKHR(command_buffer)
    }
  }
  for i := 0; i < int(light_uniform.light_count); i += 1 {
    cube_shadow := renderer_get_cube_shadow_map(&engine.renderer, i)
    shadow_map_texture := renderer_get_shadow_map(&engine.renderer, i)
    final_barriers := [2]vk.ImageMemoryBarrier {
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        newLayout = .SHADER_READ_ONLY_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = cube_shadow.buffer.image,
        subresourceRange = vk.ImageSubresourceRange {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 6,
        },
        srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        dstAccessMask = {.SHADER_READ},
      },
      {
        sType = .IMAGE_MEMORY_BARRIER,
        oldLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        newLayout = .SHADER_READ_ONLY_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = shadow_map_texture.buffer.image,
        subresourceRange = vk.ImageSubresourceRange {
          aspectMask = {.DEPTH},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 1,
        },
        srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        dstAccessMask = {.SHADER_READ},
      },
    }
    vk.CmdPipelineBarrier(
      command_buffer,
      {.LATE_FRAGMENT_TESTS},
      {.FRAGMENT_SHADER},
      {},
      0,
      nil,
      0,
      nil,
      len(final_barriers),
      raw_data(final_barriers[:]),
    )
  }
  return .SUCCESS
}

compute_particles :: proc(engine: ^Engine, command_buffer: vk.CommandBuffer) {
  log.info("binding compute pipeline", engine.particle_compute.pipeline)
  vk.CmdBindPipeline(
    command_buffer,
    .COMPUTE,
    engine.particle_compute.pipeline,
  )
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    engine.particle_compute.pipeline_layout,
    0,
    1,
    &engine.particle_compute.descriptor_set,
    0,
    nil,
  )
  vk.CmdDispatch(command_buffer, u32(MAX_PARTICLES + COMPUTE_PARTICLE_BATCH - 1) / COMPUTE_PARTICLE_BATCH, 1, 1)
  // Insert memory barrier to ensure compute results are visible
  barrier := vk.MemoryBarrier{
    sType = .MEMORY_BARRIER,
    srcAccessMask = {.SHADER_WRITE},
    dstAccessMask = {.VERTEX_ATTRIBUTE_READ},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.VERTEX_INPUT},
    {},
    1,
    &barrier,
    0,
    nil,
    0,
    nil,
  )
}

render_main_pass :: proc(
  engine: ^Engine,
  command_buffer: vk.CommandBuffer,
  camera_frustum: geometry.Frustum,
) -> vk.Result {
  // Log particle[0] before compute
  particles := engine.particle_compute.particle_buffer.mapped
  log.debugf("[ParticleSystem] BEFORE compute: particle[0] %v",
    particles[0]
  )

  // Run particle compute pass before starting rendering
  compute_particles(engine, command_buffer)

  // Log particle[0] after compute
  log.debugf("[ParticleSystem] AFTER compute: particle[0] %v",
    particles[0]
  )

  // Barrier to ensure compute shader writes are visible to the vertex shader
  particle_buffer_barrier := vk.BufferMemoryBarrier {
    sType               = .BUFFER_MEMORY_BARRIER,
    srcAccessMask       = {.SHADER_WRITE},
    dstAccessMask       = {.VERTEX_ATTRIBUTE_READ},
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    buffer              = engine.particle_compute.particle_buffer.buffer,
    offset              = 0,
    size                = vk.DeviceSize(vk.WHOLE_SIZE), // Or engine.particle_compute.particle_buffer.bytes_count
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},      // srcStageMask
    {.VERTEX_INPUT},        // dstStageMask
    {},                     // dependencyFlags
    0, nil,                 // memoryBarrierCount, pMemoryBarriers
    1, &particle_buffer_barrier, // bufferMemoryBarrierCount, pBufferMemoryBarriers
    0, nil,                 // imageMemoryBarrierCount, pImageMemoryBarriers
  )

  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = renderer_get_main_pass_view(&engine.renderer),
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = vk.ClearValue {
      color = {float32 = {0.0117, 0.0117, 0.0179, 1.0}},
    },
  }
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = engine.renderer.depth_buffer.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = vk.ClearValue{depthStencil = {1.0, 0}},
  }
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = vk.Rect2D{extent = engine.renderer.extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0.0,
    y        = f32(engine.renderer.extent.height),
    width    = f32(engine.renderer.extent.width),
    height   = -f32(engine.renderer.extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = engine.renderer.extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
  rendered_count: u32 = 0
  render_meshes_ctx := RenderMeshesContext {
    engine         = engine,
    command_buffer = command_buffer,
    camera_frustum = camera_frustum,
    rendered_count = &rendered_count,
  }
  if !traverse_scene(&engine.scene, &render_meshes_ctx, render_single_node) {
    log.errorf("[RENDER] Error during scene mesh rendering")
  }
  render_particles(engine, command_buffer)
  if mu.window(&engine.ui.ctx, "Inspector", {40, 40, 300, 150}, {.NO_CLOSE}) {
    mu.label(
      &engine.ui.ctx,
      fmt.tprintf(
        "Objects %d",
        len(engine.scene.nodes.entries) - len(engine.scene.nodes.free_indices),
      ),
    )
    mu.label(&engine.ui.ctx, fmt.tprintf("Rendered %d", rendered_count))
  }
  return .SUCCESS
}

render_particles :: proc(engine: ^Engine, command_buffer: vk.CommandBuffer) {
  log.info(
    "binding particle render pipeline",
    engine.renderer.particle_render.pipeline,
  )
  vk.CmdBindPipeline(
    command_buffer,
    .GRAPHICS,
    engine.renderer.particle_render.pipeline,
  )
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    engine.renderer.particle_render.pipeline_layout,
    0,
    1,
    &engine.renderer.particle_render.descriptor_set,
    0,
    nil,
  )

  // Push view projection matrix for particles
  uniform := SceneUniform {
      view = geometry.calculate_view_matrix(&engine.scene.camera),
      projection = geometry.calculate_projection_matrix(&engine.scene.camera),
  }
  vk.CmdPushConstants(
    command_buffer,
    engine.renderer.particle_render.pipeline_layout,
    {.VERTEX},
    0,
    size_of(SceneUniform),
    &uniform,
  )

  // Bind particle vertex buffer and draw
  offset: vk.DeviceSize = 0
  vk.CmdBindVertexBuffers(
    command_buffer,
    0,
    1,
    &engine.particle_compute.particle_buffer.buffer,
    &offset,
  )

  params := data_buffer_get(engine.particle_compute.params_buffer)

  // Debug: Print first 10 particles' position, size, life, and is_dead before rendering
  for i in 0..<min(10, params.particle_count) {
    p := engine.particle_compute.particle_buffer.mapped[i];
    log.debugf("[ParticleRender] idx=%d pos=%v size=%.2f life=%.2f is_dead=%v",
      i, p.position, p.size, p.life, p.is_dead);
  }

  if params.particle_count > 0 {
    vk.CmdDraw(command_buffer, u32(params.particle_count), 1, 0, 0)
  }
}

prepare_image_for_render :: proc(
  command_buffer: vk.CommandBuffer,
  image: vk.Image,
  old_layout: vk.ImageLayout = .UNDEFINED,
) {
  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = old_layout,
    newLayout = .COLOR_ATTACHMENT_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = image,
    subresourceRange = vk.ImageSubresourceRange {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
}

prepare_image_for_shader_read :: proc(
  command_buffer: vk.CommandBuffer,
  image: vk.Image,
  old_layout: vk.ImageLayout = .COLOR_ATTACHMENT_OPTIMAL,
) {
  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = old_layout,
    newLayout = .SHADER_READ_ONLY_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = image,
    subresourceRange = vk.ImageSubresourceRange {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
    dstAccessMask = {.SHADER_READ},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COLOR_ATTACHMENT_OUTPUT},
    {.FRAGMENT_SHADER},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
}

prepare_image_for_present :: proc(
  command_buffer: vk.CommandBuffer,
  image: vk.Image,
) {
  barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
    newLayout = .PRESENT_SRC_KHR,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = image,
    subresourceRange = vk.ImageSubresourceRange {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COLOR_ATTACHMENT_OUTPUT},
    {.BOTTOM_OF_PIPE},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &barrier,
  )
}

render_postprocess_stack :: proc(
  renderer: ^Renderer,
  command_buffer: vk.CommandBuffer,
  input_view: vk.ImageView,
  output_view: vk.ImageView,
  extent: vk.Extent2D,
) {
  if len(g_postprocess_stack) == 0 {
    // if no postprocess effect, just copy the input to output
    append(&g_postprocess_stack, nil)
  }
  // effect i:  0, 1, 2, 3, 4, 5, 6
  // read from: m0, p0, p1, p0, p1, p0 input  = (i+1)%2+1  (i != 0)
  // write to:  p0, p1, p0, p1 ...  m1 output = (i%2)+1    (i !=n-1)
  update_postprocess_input(0, input_view)
  update_postprocess_input(1, renderer_get_postprocess_pass_view(renderer, 0))
  update_postprocess_input(2, renderer_get_postprocess_pass_view(renderer, 1))
  for effect, i in g_postprocess_stack {
    is_first := i == 0
    is_last := i == len(g_postprocess_stack) - 1
    src_idx := 0 if is_first else (i - 1) % 2 + 1
    dst_image_idx := i % 2
    src_image_idx := (i - 1) % 2
    log.infof(
      "render effect %v, using descriptor %d, input image %d, output image %d",
      effect,
      src_idx,
      src_image_idx,
      dst_image_idx,
    )
    prepare_image_for_render(
      command_buffer,
      renderer_get_postprocess_pass_image(renderer, dst_image_idx),
      .SHADER_READ_ONLY_OPTIMAL,
    )
    // first image is main pass output, it is already ready for shader
    if !is_first {
      prepare_image_for_shader_read(
        command_buffer,
        renderer_get_postprocess_pass_image(renderer, src_image_idx),
      )
    }
    color_attachment := vk.RenderingAttachmentInfoKHR {
      sType = .RENDERING_ATTACHMENT_INFO_KHR,
      imageView = output_view if is_last else renderer_get_postprocess_pass_view(renderer, dst_image_idx),
      imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
      loadOp = .CLEAR,
      storeOp = .STORE,
      clearValue = vk.ClearValue{color = {float32 = {0.03, 0.01, 0.05, 1}}},
    }
    render_info := vk.RenderingInfoKHR {
      sType = .RENDERING_INFO_KHR,
      renderArea = vk.Rect2D{extent = extent},
      layerCount = 1,
      colorAttachmentCount = 1,
      pColorAttachments = &color_attachment,
    }
    vk.CmdBeginRenderingKHR(command_buffer, &render_info)

    viewport := vk.Viewport {
      width    = f32(extent.width),
      height   = f32(extent.height),
      minDepth = 0.0,
      maxDepth = 1.0,
    }
    scissor := vk.Rect2D {
      extent = extent,
    }
    vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
    vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

    effect_type := type_of_postprocess_effect(effect)
    vk.CmdBindPipeline(
      command_buffer,
      .GRAPHICS,
      g_postprocess_pipelines[effect_type],
    )
    vk.CmdBindDescriptorSets(
      command_buffer,
      .GRAPHICS,
      g_postprocess_pipeline_layouts[effect_type],
      0,
      1,
      &g_postprocess_descriptor_sets[src_idx],
      0,
      nil,
    )

    switch &e in effect {
    case BlurEffect:
      vk.CmdPushConstants(
        command_buffer,
        g_postprocess_pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(BlurEffect),
        &e,
      )
    case GrayscaleEffect:
      vk.CmdPushConstants(
        command_buffer,
        g_postprocess_pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(GrayscaleEffect),
        &e,
      )
    case ToneMapEffect:
      vk.CmdPushConstants(
        command_buffer,
        g_postprocess_pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(ToneMapEffect),
        &e,
      )
    case BloomEffect:
      vk.CmdPushConstants(
        command_buffer,
        g_postprocess_pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(BloomEffect),
        &e,
      )
    case OutlineEffect:
      vk.CmdPushConstants(
        command_buffer,
        g_postprocess_pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(OutlineEffect),
        &e,
      )
    }
    vk.CmdDraw(command_buffer, 3, 1, 0, 0)
    vk.CmdEndRenderingKHR(command_buffer)
  }
}
