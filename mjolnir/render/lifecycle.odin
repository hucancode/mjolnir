package render

import "core:log"
import "core:strings"
import cont "../containers"
import "gpu"
import vk "vendor:vulkan"

@(private)
init_subsystems :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  swapchain_format: vk.Format,
  dpi_scale: f32,
) -> vk.Result {
  layout := self.internal.scene.layout
  occlusion_init(self) or_return
  shadow_init(self) or_return
  direct_light_init(self) or_return
  material_pipelines_init(self) or_return
  particles_init(self) or_return
  post_process_init(&self.post_process, gctx, swapchain_format, layout) or_return
  debug_line_init(&self.internal.debug_line_renderer, gctx, layout, swapchain_format) or_return
  overlay_init(&self.internal.ui, gctx, layout, swapchain_format, dpi_scale) or_return
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
  init_descriptor_pool(gctx) or_return
  cont.init(&self.cameras, MAX_ACTIVE_CAMERAS, gpu.RETIRE_GRACE)
  init_instances(self)
  init_resource_pools(self)
  gpu.allocate_command_buffer(gctx, self.internal.command_buffers[:]) or_return
  if gpu.has_async_compute(gctx) {
    gpu.allocate_command_buffer(
      gctx,
      self.internal.compute_command_buffers[:],
      gctx.compute_command_pool,
    ) or_return
  }
  mesh_manager_init(&self.mesh_manager, gctx) or_return
  init_scene_buffers(self, gctx) or_return
  texture_manager_init(&self.texture_manager, gctx) or_return
  scene_descriptors_init(self) or_return
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
  texture_manager_setup(&self.texture_manager)
  ambient_setup(&self.ambient, gctx, &self.texture_manager) or_return
  particles_reset(&self.internal.particles, gctx) or_return
  overlay_setup(&self.internal.ui, gctx, &self.texture_manager) or_return
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
  cont.flush(&self.cameras, nil, nil)
  overlay_teardown(&self.internal.ui, gctx)
  post_process_teardown(&self.post_process, gctx, &self.texture_manager)
  ambient_teardown(&self.ambient, gctx, &self.texture_manager)
  texture_manager_teardown(&self.texture_manager, gctx)
  // the GPU is idle: destroy what teardown queued for deferred destruction
  gpu.deferred_flush(gctx)
}

// Replace the environment map with the equirectangular HDR image at `path`
// and precompute image-based lighting from it. Level-lifetime: call after
// setup; teardown frees it. Without one, IBL and the skybox are black.
load_environment_map :: proc(self: ^Manager, path: string) -> bool {
  res := ambient_load_environment(&self.ambient, &self.gctx, &self.texture_manager, self.internal.scene.layout, path)
  if res != .SUCCESS do log.warnf("Failed to load environment map %s: %v", path, res)
  return res == .SUCCESS
}

// Destroy everything init created; tears the level down first if needed.
shutdown :: proc(self: ^Manager) {
  teardown(self)
  gctx := &self.gctx
  vk.DeviceWaitIdle(gctx.device)
  gpu.free_command_buffer(gctx, self.internal.command_buffers[:])
  if gpu.has_async_compute(gctx) {
    gpu.free_command_buffer(gctx, self.internal.compute_command_buffers[:], gctx.compute_command_pool)
  }
  overlay_shutdown(&self.internal.ui, gctx)
  debug_line_shutdown(&self.internal.debug_line_renderer, gctx)
  post_process_shutdown(&self.post_process, gctx)
  particles_shutdown(&self.internal.particles, gctx)
  direct_light_shutdown(self)
  shadow_shutdown(&self.internal.shadow, gctx)
  material_pipelines_shutdown(self)
  occlusion_shutdown(&self.internal.visibility, gctx)
  scene_descriptors_shutdown(&self.internal.scene, gctx)
  texture_manager_shutdown(&self.texture_manager, gctx)
  destroy_scene_buffers(self, gctx)
  mesh_manager_shutdown(&self.mesh_manager, gctx)
  cont.destroy(&self.cameras, proc(_: ^Camera) {})
  destroy_light_state(self, gctx)
  destroy_resource_pools(self)
  staging_destroy(&self.internal.staging)
  for _, p in self.internal.bones do delete(p.matrices)
  delete(self.internal.bones)
  delete(self.instances)
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
  // re-created at the new extent by the next frame
  post_process_release_images(&self.post_process, gctx, &self.texture_manager)
  self.internal.ui.dpi_scale = dpi_scale
  return .SUCCESS
}

// Create the descriptor pool sized for exactly render's sets: one scene set
// per frame in flight and the bindless set.
@(private = "file")
init_descriptor_pool :: proc(gctx: ^gpu.GPUContext) -> vk.Result {
  sizes := make([dynamic]vk.DescriptorPoolSize, context.temp_allocator)
  add :: proc(sizes: ^[dynamic]vk.DescriptorPoolSize, type: vk.DescriptorType, count: u32) {
    for &s in sizes do if s.type == type {s.descriptorCount += count; return}
    append(sizes, vk.DescriptorPoolSize{type, count})
  }
  for type in SCENE_BINDING_TYPES do add(&sizes, type, gpu.FRAMES_IN_FLIGHT)
  for b in BINDLESS_BINDINGS do add(&sizes, b.type, b.count)
  return gpu.descriptor_pool_init(gctx, sizes[:], gpu.FRAMES_IN_FLIGHT + 1)
}
