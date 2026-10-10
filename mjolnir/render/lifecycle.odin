package render

import "bindless"
import "core:log"
import "core:strings"
import cont "../containers"
import "gpu"
import "ambient"
import "debug_line"
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
  shadow_include := transmute(u32)NodeFlagSet{.VISIBLE, .CASTS_SHADOW}
  shadow_exclude := transmute(u32)NodeFlagSet{
    .MATERIAL_TRANSPARENT,
    .MATERIAL_WIREFRAME,
    .MATERIAL_RANDOM_COLOR,
  }
  occlusion_culling.init(&self.internal.visibility, gctx, MAX_NODES_IN_SCENE) or_return
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
    self.internal.emitter_buffer.descriptor_set,
    self.internal.forcefield_buffer.set_layout,
    self.internal.forcefield_buffer.descriptor_set,
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

// Creates a window surface for `instance`; `user` is passed through from init.
SurfaceProc :: #type proc(user: rawptr, instance: vk.Instance) -> (vk.SurfaceKHR, vk.Result)

// Bring the renderer up on a window: instance, surface (through
// `create_surface(surface_user, instance)`), device, swapchain, every
// app-lifetime resource and an empty level with a main camera. Paired with
// shutdown.
init :: proc(
  self: ^Manager,
  app_name: string,
  instance_extensions: []cstring,
  get_instance_proc_addr: rawptr,
  create_surface: SurfaceProc,
  surface_user: rawptr,
  framebuffer_size: [2]u32,
  dpi_scale: f32,
) -> bool {
  res := init_vulkan(
    self,
    app_name,
    instance_extensions,
    get_instance_proc_addr,
    create_surface,
    surface_user,
    framebuffer_size,
    dpi_scale,
  )
  if res == .SUCCESS do res = setup_level(self)
  if res != .SUCCESS {
    log.errorf("Renderer init failed: %v", res)
    return false
  }
  return true
}

@(private = "file")
init_vulkan :: proc(
  self: ^Manager,
  app_name: string,
  instance_extensions: []cstring,
  get_instance_proc_addr: rawptr,
  create_surface: SurfaceProc,
  surface_user: rawptr,
  framebuffer_size: [2]u32,
  dpi_scale: f32,
) -> vk.Result {
  gctx := &self.gctx
  name := strings.clone_to_cstring(app_name, context.temp_allocator)
  gpu.instance_init(gctx, name, instance_extensions, get_instance_proc_addr) or_return
  gctx.surface = create_surface(surface_user, gctx.instance) or_return
  gpu.device_init(gctx) or_return
  gpu.swapchain_init(&self.swapchain, gctx, framebuffer_size) or_return
  swapchain_format := self.swapchain.format.format
  gpu.descriptor_pool_init(gctx, DESCRIPTOR_POOL_SIZES[:], DESCRIPTOR_POOL_MAX_SETS) or_return
  cont.init(&self.cameras, MAX_ACTIVE_CAMERAS)
  init_instances(self)
  init_resource_pools(self)
  gpu.allocate_command_buffer(gctx, self.internal.command_buffers[:]) or_return
  if gpu.has_async_compute(gctx) {
    gpu.allocate_compute_command_buffer(
      gctx,
      self.internal.compute_command_buffers[:],
    ) or_return
  }
  bindless.mesh_manager_init(&self.mesh_manager, gctx) or_return
  init_scene_buffers(self, gctx) or_return
  bindless.texture_manager_init(&self.texture_manager, gctx) or_return
  init_subsystems(self, gctx, swapchain_format, dpi_scale) or_return
  return .SUCCESS
}

// Level-lifetime resources: descriptors, per-level renderer state and the
// main camera. init runs it once; after teardown, call it to start the next
// level. Safe to call at any point outside frame; a no-op when the level is
// already set up. Load the environment map with load_environment_map afterwards.
setup :: proc(self: ^Manager) -> bool {
  res := setup_level(self)
  if res != .SUCCESS do log.errorf("Renderer level setup failed: %v", res)
  return res == .SUCCESS
}

@(private = "file")
setup_level :: proc(self: ^Manager) -> (ret: vk.Result) {
  if self.internal.level_ready do return .SUCCESS
  gctx := &self.gctx
  swapchain_extent := self.swapchain.extent
  self.internal.level_ready = true
  defer if ret != .SUCCESS do teardown(self)
  bindless.texture_manager_setup(&self.texture_manager)
  ambient.setup(&self.ambient, gctx, &self.texture_manager) or_return
  particles.reset(&self.internal.particles)
  post_process.setup(
    &self.post_process,
    gctx,
    &self.texture_manager,
    swapchain_extent,
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
  // texture_manager_teardown destroys the shadow textures
  for &sm in self.internal.shadow_maps do sm.textures = {}
  ui_render.teardown(&self.internal.ui, gctx)
  post_process.teardown(&self.post_process, gctx, &self.texture_manager)
  ambient.teardown(&self.ambient, gctx, &self.texture_manager)
  bindless.texture_manager_teardown(&self.texture_manager, gctx)
  // the GPU is idle: destroy what teardown queued for deferred destruction
  gpu.deferred_flush(gctx)
}

// Replace the environment map with the equirectangular HDR image at `path`
// and precompute image-based lighting from it. Level-lifetime: call after
// setup; teardown frees it. Without one, IBL and the skybox are black.
load_environment_map :: proc(self: ^Manager, path: string) -> bool {
  res := ambient.load_environment(&self.ambient, &self.gctx, &self.texture_manager, path)
  if res != .SUCCESS do log.warnf("Failed to load environment map %s: %v", path, res)
  return res == .SUCCESS
}

// Destroy everything init created; tears the level down first if needed.
shutdown :: proc(self: ^Manager) {
  teardown(self)
  gctx := &self.gctx
  vk.DeviceWaitIdle(gctx.device)
  gpu.free_command_buffer(gctx, ..self.internal.command_buffers[:])
  if gpu.has_async_compute(gctx) {
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
  occlusion_culling.shutdown(&self.internal.visibility, gctx)
  bindless.texture_manager_shutdown(&self.texture_manager, gctx)
  destroy_scene_buffers(self, gctx)
  bindless.mesh_manager_shutdown(&self.mesh_manager, gctx)
  cont.destroy(&self.cameras, proc(_: ^Camera) {})
  destroy_light_state(self, gctx)
  destroy_resource_pools(self)
  staging_destroy(&self.internal.staging)
  for _, p in self.internal.bones do delete(p.matrices)
  delete(self.internal.bones)
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
  resize_swapchain_cameras(self, old_extent, extent) or_return
  post_process.recreate_images(
    gctx,
    &self.post_process,
    &self.texture_manager,
    extent,
  ) or_return
  self.internal.ui.dpi_scale = dpi_scale
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
