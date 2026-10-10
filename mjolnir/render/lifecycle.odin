package render

import "bindless"
import "core:strings"
import cont "../containers"
import "gpu"
import "ambient"
import "debug_line"
import depth_pyramid_system "depth_pyramid"
import "direct_light"
import "forward"
import "geometry"
import "occlusion_culling"
import "particles"
import "post_process"
import "shadow"
import ui_render "ui"
import vk "vendor:vulkan"

@(private)
init_subsystems :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
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
  shadow.init(
    &self.internal.shadow,
    gctx,
    scene_bindings(self, 0),
    MAX_NODES_IN_SCENE,
    SHADOW_MAP_SIZE,
    shadow_include,
    shadow_exclude,
  ) or_return
  ambient.init(
    &self.ambient,
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
  geometry.init(&self.internal.geometry, gctx, scene_bindings(self, 0)) or_return
  particles.init(
    &self.internal.particles,
    gctx,
    self.internal.emitter_buffer.set_layout,
    self.internal.forcefield_buffer.set_layout,
    self.internal.node_data_buffer.set_layout,
    self.internal.camera_buffer.set_layout,
    self.texture_manager.set_layout,
  ) or_return
  forward.init(&self.internal.forward, gctx, scene_bindings(self, 0)) or_return
  post_process.init(
    &self.post_process,
    gctx,
    swapchain_format,
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
    dpi_scale,
  ) or_return
  return .SUCCESS
}

// Create the Vulkan instance. The caller creates a window surface for
// vulkan_instance(self) and passes it to init.
create_instance :: proc(
  self: ^Manager,
  app_name: string,
  instance_extensions: []cstring,
  get_instance_proc_addr: rawptr,
) -> vk.Result {
  name := strings.clone_to_cstring(app_name, context.temp_allocator)
  return gpu.instance_init(&self.gctx, name, instance_extensions, get_instance_proc_addr)
}

vulkan_instance :: proc(self: ^Manager) -> vk.Instance {
  return self.gctx.instance
}

// Create the device, the swapchain for `surface` and every app-lifetime
// resource. Paired with shutdown. Follow with setup.
init :: proc(
  self: ^Manager,
  surface: vk.SurfaceKHR,
  framebuffer_size: [2]u32,
  dpi_scale: f32,
) -> vk.Result {
  gctx := &self.gctx
  gctx.surface = surface
  gpu.device_init(gctx) or_return
  gpu.swapchain_init(&self.swapchain, gctx, framebuffer_size) or_return
  swapchain_format := self.swapchain.format.format
  gpu.descriptor_pool_init(gctx, DESCRIPTOR_POOL_SIZES[:], DESCRIPTOR_POOL_MAX_SETS) or_return
  self.color_format = swapchain_format
  cont.init(&self.cameras, MAX_ACTIVE_CAMERAS)
  init_light_state(self)
  init_instances(self)
  init_resource_pools(self)
  gpu.allocate_command_buffer(gctx, self.internal.command_buffers[:]) or_return
  if gctx.has_async_compute {
    gpu.allocate_compute_command_buffer(
      gctx,
      self.internal.compute_command_buffers[:],
    ) or_return
  }
  bindless.mesh_manager_init(&self.mesh_manager, gctx)
  init_scene_buffers(self, gctx) or_return
  bindless.texture_manager_init(&self.texture_manager, gctx) or_return
  init_subsystems(self, gctx, swapchain_format, dpi_scale) or_return
  return .SUCCESS
}

// Level-lifetime resources: descriptors, per-level renderer state and the
// main camera. Paired with teardown. Safe to call at any point outside frame;
// a no-op when the level is already set up. Load the environment map with
// load_environment_map afterwards.
setup :: proc(self: ^Manager) -> (ret: vk.Result) {
  if self.internal.level_ready do return .SUCCESS
  gctx := &self.gctx
  swapchain_extent := self.swapchain.extent
  swapchain_format := self.swapchain.format.format
  self.internal.level_ready = true
  defer if ret != .SUCCESS do teardown(self)
  bindless.texture_manager_setup(&self.texture_manager, gctx) or_return
  realloc_scene_descriptors(self, gctx) or_return
  ambient.setup(&self.ambient, gctx, &self.texture_manager) or_return
  direct_light.setup(&self.internal.direct_light, gctx) or_return
  particles.setup(
    &self.internal.particles,
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
  ui_render.setup(&self.internal.ui, gctx, &self.texture_manager) or_return
  if _, ok := main_camera(self); !ok {
    cam, created := create_camera(
      self,
      swapchain_extent.width,
      swapchain_extent.height,
      position = {3, 4, 3},
      far_plane = 1000.0,
    )
    if !created do return .ERROR_INITIALIZATION_FAILED
    self.main_camera = cam
  }
  return .SUCCESS
}

// Free every slot, camera and level resource. App-lifetime resources (pools,
// pipelines, builtin meshes) stay. Safe to call at any point outside frame: it
// waits for every frame in flight first. A no-op when no level is set up.
teardown :: proc(self: ^Manager) {
  if !self.internal.level_ready do return
  self.internal.level_ready = false
  gctx := &self.gctx
  vk.DeviceWaitIdle(gctx.device)
  clear_slots(self)
  it := cont.iterator(&self.cameras)
  for _, handle in cont.next(&it, CameraHandle) do destroy_camera(self, handle)
  release_all_light_shadows(self, gctx)
  ui_render.teardown(&self.internal.ui, gctx)
  post_process.teardown(&self.post_process, gctx, &self.texture_manager)
  particles.teardown(&self.internal.particles, gctx)
  ambient.teardown(&self.ambient, gctx, &self.texture_manager)
  direct_light.teardown(&self.internal.direct_light, gctx)
  bindless.texture_manager_teardown(&self.texture_manager, gctx)
  clear_scene_descriptor_handles(self)
  vk.ResetDescriptorPool(gctx.device, gctx.descriptor_pool, {})
  // the GPU is idle: destroy what teardown queued for deferred destruction
  gpu.deferred_flush(gctx)
}

// Replace the environment map with the equirectangular HDR image at `path`
// and precompute image-based lighting from it. Level-lifetime: call after
// setup; teardown frees it. Without one, IBL and the skybox are black.
load_environment_map :: proc(self: ^Manager, path: string) -> vk.Result {
  return ambient.load_environment(&self.ambient, &self.gctx, &self.texture_manager, path)
}

// Destroy everything init created; tears the level down first if needed.
shutdown :: proc(self: ^Manager) {
  teardown(self)
  gctx := &self.gctx
  vk.DeviceWaitIdle(gctx.device)
  gpu.free_command_buffer(gctx, ..self.internal.command_buffers[:])
  if gctx.has_async_compute {
    gpu.free_compute_command_buffer(gctx, self.internal.compute_command_buffers[:])
  }
  ui_render.shutdown(&self.internal.ui, gctx)
  debug_line.shutdown(&self.internal.debug_line_renderer, gctx)
  post_process.shutdown(&self.post_process, gctx)
  particles.shutdown(&self.internal.particles, gctx)
  forward.shutdown(&self.internal.forward, gctx)
  ambient.shutdown(&self.ambient, gctx)
  direct_light.shutdown(&self.internal.direct_light, gctx)
  shadow.shutdown(&self.internal.shadow, gctx)
  geometry.shutdown(&self.internal.geometry, gctx)
  depth_pyramid_system.shutdown(&self.internal.depth_pyramid, gctx)
  occlusion_culling.shutdown(&self.internal.visibility, gctx)
  bindless.texture_manager_shutdown(&self.texture_manager, gctx)
  destroy_scene_buffers(self, gctx)
  bindless.mesh_manager_shutdown(&self.mesh_manager, gctx)
  cont.destroy(&self.cameras, proc(_: ^Camera) {})
  destroy_light_state(self)
  destroy_resource_pools(self)
  staging_destroy(&self.internal.staging)
  for _, palette in self.internal.bone_matrices do delete(palette)
  delete(self.internal.bone_matrices)
  delete(self.instances)
  delete(self.internal.ui_atlas_pixels)
  gpu.swapchain_destroy(&self.swapchain, gctx.device)
  gpu.shutdown(gctx)
}

// Rebuild the swapchain at the new framebuffer size; cameras that matched the
// old swapchain extent and the screen-sized targets follow it.
@(private)
recreate_swapchain :: proc(self: ^Manager, framebuffer_size: [2]u32, dpi_scale: f32) -> vk.Result {
  gctx := &self.gctx
  old_extent := self.swapchain.extent
  gpu.swapchain_recreate(gctx, &self.swapchain, framebuffer_size) or_return
  extent := self.swapchain.extent
  color_format := self.swapchain.format.format
  resize_swapchain_cameras(self, old_extent, extent) or_return
  post_process.recreate_images(
    gctx,
    &self.post_process,
    &self.texture_manager,
    extent,
    color_format,
  ) or_return
  ui_render.set_dpi_scale(&self.internal.ui, dpi_scale)
  return .SUCCESS
}

@(private = "file")
MAX_DEPTH_PYRAMID_MIPS :: 16
// One storage image per depth-pyramid mip, per frame, per camera.
@(private = "file")
STORAGE_IMAGE_COUNT :: MAX_ACTIVE_CAMERAS * gpu.FRAMES_IN_FLIGHT * MAX_DEPTH_PYRAMID_MIPS
@(private = "file")
MATERIAL_BUDGET :: 1000
@(private = "file")
SAMPLER_BUDGET :: MATERIAL_BUDGET * 3

@(private = "file")
DESCRIPTOR_POOL_SIZES := [?]vk.DescriptorPoolSize {
  {.COMBINED_IMAGE_SAMPLER, SAMPLER_BUDGET},
  {.SAMPLED_IMAGE, SAMPLER_BUDGET},
  {.SAMPLER, SAMPLER_BUDGET},
  {.UNIFORM_BUFFER, 128},
  {.UNIFORM_BUFFER_DYNAMIC, 128},
  {.STORAGE_BUFFER, MATERIAL_BUDGET},
  {.STORAGE_IMAGE, STORAGE_IMAGE_COUNT},
}

@(private = "file")
DESCRIPTOR_POOL_MAX_SETS :: gpu.FRAMES_IN_FLIGHT + MATERIAL_BUDGET + STORAGE_IMAGE_COUNT
