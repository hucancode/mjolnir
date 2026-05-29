package render

import "../gpu"
import "ambient"
import "debug_line"
import "debug_ui"
import depth_pyramid_system "depth_pyramid"
import "direct_light"
import "geometry"
import "line_strip"
import "occlusion_culling"
import particles_compute "particles_compute"
import particles_render "particles_render"
import "post_process"
import "random_color"
import shadow_culling_system "shadow_culling"
import shadow_render_system "shadow_render"
import shadow_sphere_culling_system "shadow_sphere_culling"
import shadow_sphere_render_system "shadow_sphere_render"
import "sprite"
import "transparent"
import ui_render "ui"
import vk "vendor:vulkan"
import "wireframe"

@(private)
init_samplers :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  info := vk.SamplerCreateInfo {
    sType        = .SAMPLER_CREATE_INFO,
    magFilter    = .LINEAR,
    minFilter    = .LINEAR,
    addressModeU = .REPEAT,
    addressModeV = .REPEAT,
    addressModeW = .REPEAT,
    mipmapMode   = .LINEAR,
    maxLod       = 1000,
  }
  vk.CreateSampler(gctx.device, &info, nil, &self.internal.linear_repeat_sampler) or_return
  info.addressModeU, info.addressModeV, info.addressModeW =
    .CLAMP_TO_EDGE, .CLAMP_TO_EDGE, .CLAMP_TO_EDGE
  vk.CreateSampler(gctx.device, &info, nil, &self.internal.linear_clamp_sampler) or_return
  info.magFilter, info.minFilter = .NEAREST, .NEAREST
  info.addressModeU, info.addressModeV, info.addressModeW =
    .REPEAT, .REPEAT, .REPEAT
  vk.CreateSampler(gctx.device, &info, nil, &self.internal.nearest_repeat_sampler) or_return
  info.addressModeU, info.addressModeV, info.addressModeW =
    .CLAMP_TO_EDGE, .CLAMP_TO_EDGE, .CLAMP_TO_EDGE
  vk.CreateSampler(gctx.device, &info, nil, &self.internal.nearest_clamp_sampler) or_return
  return .SUCCESS
}

@(private)
destroy_samplers :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  vk.DestroySampler(gctx.device, self.internal.linear_repeat_sampler, nil)
  self.internal.linear_repeat_sampler = 0
  vk.DestroySampler(gctx.device, self.internal.linear_clamp_sampler, nil)
  self.internal.linear_clamp_sampler = 0
  vk.DestroySampler(gctx.device, self.internal.nearest_repeat_sampler, nil)
  self.internal.nearest_repeat_sampler = 0
  vk.DestroySampler(gctx.device, self.internal.nearest_clamp_sampler, nil)
  self.internal.nearest_clamp_sampler = 0
}

@(private)
init_subsystems :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  swapchain_extent: vk.Extent2D,
  swapchain_format: vk.Format,
  dpi_scale: f32,
) -> vk.Result {
  shadow_include := transmute(u32)NodeFlagSet{.VISIBLE}
  shadow_exclude := transmute(u32)NodeFlagSet{
    .MATERIAL_TRANSPARENT,
    .MATERIAL_WIREFRAME,
    .MATERIAL_RANDOM_COLOR,
    .MATERIAL_LINE_STRIP,
  }
  occlusion_culling.init(&self.internal.visibility, gctx, MAX_NODES_IN_SCENE) or_return
  depth_pyramid_system.init(&self.internal.depth_pyramid, gctx) or_return
  shadow_culling_system.init(
    &self.internal.shadow_culling,
    gctx,
    MAX_NODES_IN_SCENE,
    shadow_include,
    shadow_exclude,
  ) or_return
  shadow_sphere_culling_system.init(
    &self.internal.shadow_sphere_culling,
    gctx,
    MAX_NODES_IN_SCENE,
    shadow_include,
    shadow_exclude,
  ) or_return
  shadow_render_system.init(
    &self.internal.shadow_render,
    gctx,
    self.texture_manager.set_layout,
    self.internal.bone_buffer.set_layout,
    self.internal.material_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
    MAX_NODES_IN_SCENE,
    SHADOW_MAP_SIZE,
  ) or_return
  shadow_sphere_render_system.init(
    &self.internal.shadow_sphere_render,
    gctx,
    self.texture_manager.set_layout,
    self.internal.bone_buffer.set_layout,
    self.internal.material_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
    MAX_NODES_IN_SCENE,
    SHADOW_MAP_SIZE,
  ) or_return
  ambient.init(
    &self.internal.ambient,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  direct_light.init(
    &self.internal.direct_light,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  geometry.init(
    &self.internal.geometry,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.internal.bone_buffer.set_layout,
    self.internal.material_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  particles_compute.init(
    &self.internal.particles_compute,
    gctx,
    self.internal.emitter_buffer.set_layout,
    self.internal.forcefield_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
  ) or_return
  particles_render.init(
    &self.internal.particles_render,
    gctx,
    &self.texture_manager,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  transparent.init(
    &self.internal.transparent_renderer,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.internal.bone_buffer.set_layout,
    self.internal.material_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  sprite.init(
    &self.internal.sprite_renderer,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.sprite_buffer.set_layout,
  ) or_return
  wireframe.init(
    &self.internal.wireframe_renderer,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.internal.bone_buffer.set_layout,
    self.internal.material_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  line_strip.init(
    &self.internal.line_strip_renderer,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.internal.bone_buffer.set_layout,
    self.internal.material_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  random_color.init(
    &self.internal.random_color_renderer,
    gctx,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
    self.internal.bone_buffer.set_layout,
    self.internal.material_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.mesh_data_buffer.set_layout,
    self.mesh_manager.vertex_skinning_buffer.set_layout,
  ) or_return
  post_process.init(
    &self.post_process,
    gctx,
    swapchain_format,
    self.texture_manager.set_layout,
  ) or_return
  debug_ui.init(
    &self.debug_ui,
    gctx,
    swapchain_format,
    swapchain_extent,
    dpi_scale,
    self.texture_manager.set_layout,
  ) or_return
  debug_line.init(
    &self.internal.debug_line_renderer,
    gctx,
    self.internal.camera_buffer.set_layout,
  ) or_return
  ui_render.init(
    &self.internal.ui,
    gctx,
    self.texture_manager.set_layout,
    swapchain_format,
  ) or_return
  return .SUCCESS
}

init :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  swapchain_extent: vk.Extent2D,
  swapchain_format: vk.Format,
  dpi_scale: f32,
) -> vk.Result {
  self.cameras = make(map[u32]CameraTarget)
  init_light_state(self)
  gpu.allocate_command_buffer(gctx, self.internal.command_buffers[:]) or_return
  if gctx.has_async_compute {
    gpu.allocate_compute_command_buffer(
      gctx,
      self.internal.compute_command_buffers[:],
    ) or_return
  }
  gpu.mesh_manager_init(&self.mesh_manager, gctx)
  init_scene_buffers(self, gctx) or_return
  gpu.texture_manager_init(&self.texture_manager, gctx) or_return
  init_samplers(self, gctx) or_return
  init_subsystems(self, gctx, swapchain_extent, swapchain_format, dpi_scale) or_return
  return .SUCCESS
}

setup :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  swapchain_extent: vk.Extent2D,
  swapchain_format: vk.Format,
) -> vk.Result {
  gpu.texture_manager_setup(
    &self.texture_manager,
    gctx,
    {
      self.internal.nearest_clamp_sampler,
      self.internal.linear_clamp_sampler,
      self.internal.nearest_repeat_sampler,
      self.internal.linear_repeat_sampler,
    },
  ) or_return
  realloc_scene_descriptors(self, gctx) or_return
  ambient.setup(
    &self.internal.ambient,
    gctx,
    &self.texture_manager,
    self.internal.linear_repeat_sampler,
  ) or_return
  direct_light.setup(&self.internal.direct_light, gctx) or_return
  particles_compute.setup(
    &self.internal.particles_compute,
    gctx,
    self.internal.emitter_buffer.descriptor_set,
    self.internal.forcefield_buffer.descriptor_set,
  ) or_return
  post_process.setup(
    &self.post_process,
    gctx,
    &self.texture_manager,
    swapchain_extent,
    swapchain_format,
  ) or_return
  debug_ui.setup(&self.debug_ui, gctx, &self.texture_manager) or_return
  ui_render.setup(&self.internal.ui, gctx) or_return
  return .SUCCESS
}

teardown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  for _, &cam in self.cameras {
    camera_destroy(gctx, &cam, &self.texture_manager)
  }
  clear(&self.cameras)
  release_all_light_shadows(self, gctx)
  ui_render.teardown(&self.internal.ui, gctx)
  debug_ui.teardown(&self.debug_ui, gctx, &self.texture_manager)
  post_process.teardown(&self.post_process, gctx, &self.texture_manager)
  particles_compute.teardown(&self.internal.particles_compute, gctx)
  ambient.teardown(&self.internal.ambient, gctx, &self.texture_manager)
  direct_light.teardown(&self.internal.direct_light, gctx)
  gpu.texture_manager_teardown(&self.texture_manager, gctx)
  clear_scene_descriptor_handles(self)
  vk.ResetDescriptorPool(gctx.device, gctx.descriptor_pool, {})
}

shutdown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  gpu.free_command_buffer(gctx, ..self.internal.command_buffers[:])
  if gctx.has_async_compute {
    gpu.free_compute_command_buffer(gctx, self.internal.compute_command_buffers[:])
  }
  ui_render.shutdown(&self.internal.ui, gctx)
  debug_line.shutdown(&self.internal.debug_line_renderer, gctx)
  debug_ui.shutdown(&self.debug_ui, gctx)
  post_process.shutdown(&self.post_process, gctx)
  particles_compute.shutdown(&self.internal.particles_compute, gctx)
  particles_render.shutdown(&self.internal.particles_render, gctx)
  transparent.shutdown(&self.internal.transparent_renderer, gctx)
  sprite.shutdown(&self.internal.sprite_renderer, gctx)
  wireframe.shutdown(&self.internal.wireframe_renderer, gctx)
  line_strip.shutdown(&self.internal.line_strip_renderer, gctx)
  random_color.shutdown(&self.internal.random_color_renderer, gctx)
  ambient.shutdown(&self.internal.ambient, gctx)
  direct_light.shutdown(&self.internal.direct_light, gctx)
  shadow_sphere_render_system.shutdown(&self.internal.shadow_sphere_render, gctx)
  shadow_render_system.shutdown(&self.internal.shadow_render, gctx)
  shadow_sphere_culling_system.shutdown(&self.internal.shadow_sphere_culling, gctx)
  shadow_culling_system.shutdown(&self.internal.shadow_culling, gctx)
  geometry.shutdown(&self.internal.geometry, gctx)
  depth_pyramid_system.shutdown(&self.internal.depth_pyramid, gctx)
  occlusion_culling.shutdown(&self.internal.visibility, gctx)
  destroy_samplers(self, gctx)
  gpu.texture_manager_shutdown(&self.texture_manager, gctx)
  destroy_scene_buffers(self, gctx)
  gpu.mesh_manager_shutdown(&self.mesh_manager, gctx)
  delete(self.cameras)
  destroy_light_state(self)
}

resize :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  extent: vk.Extent2D,
  color_format: vk.Format,
  dpi_scale: f32,
) -> vk.Result {
  post_process.recreate_images(
    gctx,
    &self.post_process,
    &self.texture_manager,
    extent,
    color_format,
  ) or_return
  debug_ui.recreate_images(&self.debug_ui, color_format, extent, dpi_scale)
  return .SUCCESS
}
