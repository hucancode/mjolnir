package mjolnir

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "gpu"
import "render/debug_ui"
import geometry_pass "render/geometry"
import "render/lighting"
import navigation_renderer "render/navigation"
import "render/particles"
import "render/post_process"
import "render/text"
import "render/transparency"
import "resources"
import vk "vendor:vulkan"
import "world"

Renderer :: struct {
  geometry:     geometry_pass.Renderer,
  lighting:     lighting.Renderer,
  transparency: transparency.Renderer,
  particles:    particles.Renderer,
  navigation:   navigation_renderer.Renderer,
  post_process: post_process.Renderer,
  text:         text.Renderer,
  ui:           debug_ui.Renderer,
  main_camera:  resources.Handle, // Main camera for rendering
}

renderer_init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  swapchain_extent: vk.Extent2D,
  swapchain_format: vk.Format,
  dpi_scale: f32,
) -> vk.Result {
  main_camera_handle, main_camera_ptr, main_camera_ok := resources.alloc(
    &rm.cameras,
  )
  if !main_camera_ok {
    log.error("Failed to allocate main camera")
    return .ERROR_INITIALIZATION_FAILED
  }
  init_result := resources.camera_init(
    main_camera_ptr,
    gctx,
    rm,
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
    .D32_SFLOAT,
    {.SHADOW, .GEOMETRY, .LIGHTING, .TRANSPARENCY, .PARTICLES, .POST_PROCESS},
    {10, 16, 10}, // Camera slightly above and diagonal to origin
    {0, 0, 0}, // Looking at origin
    math.PI * 0.5, // FOV
    0.1, // near plane
    100.0, // far plane
  )
  if init_result != .SUCCESS {
    log.error("Failed to initialize main camera")
    resources.free(&rm.cameras, main_camera_handle)
    return .ERROR_INITIALIZATION_FAILED
  }
  self.main_camera = main_camera_handle
  lighting.init(
    &self.lighting,
    gctx,
    rm,
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
    vk.Format.D32_SFLOAT,
  ) or_return
  geometry_pass.init(
    &self.geometry,
    gctx,
    swapchain_extent.width,
    swapchain_extent.height,
    rm,
  ) or_return
  particles.init(&self.particles, gctx, rm) or_return
  transparency.init(
    &self.transparency,
    gctx,
    swapchain_extent.width,
    swapchain_extent.height,
    rm,
  ) or_return
  post_process.init(
    &self.post_process,
    gctx,
    swapchain_format,
    swapchain_extent.width,
    swapchain_extent.height,
    rm,
  ) or_return
  text.init(
    &self.text,
    gctx,
    swapchain_format,
    swapchain_extent.width,
    swapchain_extent.height,
    rm,
  ) or_return
  debug_ui.init(
    &self.ui,
    gctx,
    swapchain_format,
    swapchain_extent.width,
    swapchain_extent.height,
    dpi_scale,
    rm,
  ) or_return
  navigation_renderer.init(&self.navigation, gctx, rm) or_return

  return .SUCCESS
}

renderer_shutdown :: proc(
  self: ^Renderer,
  device: vk.Device,
  command_pool: vk.CommandPool,
  rm: ^resources.Manager,
) {
  debug_ui.shutdown(&self.ui, device)
  text.shutdown(&self.text, device)
  navigation_renderer.shutdown(&self.navigation, device, command_pool)
  post_process.shutdown(&self.post_process, device, command_pool, rm)
  particles.shutdown(&self.particles, device, command_pool)
  transparency.shutdown(&self.transparency, device, command_pool)
  lighting.shutdown(&self.lighting, device, command_pool, rm)
  geometry_pass.shutdown(&self.geometry, device, command_pool)
}

resize :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  extent: vk.Extent2D,
  color_format: vk.Format,
  dpi_scale: f32,
) -> vk.Result {
  lighting.lighting_recreate_images(
    &self.lighting,
    extent.width,
    extent.height,
    color_format,
    vk.Format.D32_SFLOAT,
  ) or_return
  post_process.recreate_images(
    gctx,
    &self.post_process,
    extent.width,
    extent.height,
    color_format,
    rm,
  ) or_return
  text.recreate_images(&self.text, extent.width, extent.height) or_return
  debug_ui.recreate_images(
    &self.ui,
    color_format,
    extent.width,
    extent.height,
    dpi_scale,
  ) or_return
  return .SUCCESS
}

// Records shadow pass commands directly into the provided command buffer
record_camera_visibility :: proc(
  self: ^Renderer,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  world_state: ^world.World,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  // Iterate through all regular cameras with shadow pass enabled
  for &entry, cam_index in rm.cameras.entries {
    if !entry.active do continue
    if resources.PassType.SHADOW not_in entry.item.enabled_passes do continue

    cam := &entry.item

    // Upload camera data to GPU buffer
    resources.camera_upload_data(rm, cam, u32(cam_index))

    // Dispatch visibility - records compute culling + depth rendering
    world.visibility_system_dispatch(
      &world_state.visibility,
      gctx,
      command_buffer,
      cam,
      u32(cam_index),
      frame_index,
      {.VISIBLE},
      {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME},
      rm,
    )
  }

  // Iterate through all spherical cameras (all have shadow pass by design)
  for &entry, cam_index in rm.spherical_cameras.entries {
    if !entry.active do continue

    spherical_cam := &entry.item

    // Upload camera data to GPU buffer
    resources.spherical_camera_upload_data(rm, spherical_cam, u32(cam_index))

    // Dispatch visibility - records compute culling + depth rendering
    world.visibility_system_dispatch_spherical(
      &world_state.visibility,
      gctx,
      command_buffer,
      spherical_cam,
      u32(cam_index),
      {.VISIBLE},
      {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME},
      rm,
    )
  }

  return .SUCCESS
}

record_geometry_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  world_state: ^world.World,
  camera_handle: resources.Handle,
) -> vk.Result {
  command_buffer := geometry_pass.begin_record(
    &self.geometry,
    frame_index,
    camera_handle,
    rm,
  ) or_return

  camera := resources.get(rm.cameras, camera_handle)
  if camera == nil {
    log.error("Failed to get camera for geometry pass")
    return .ERROR_UNKNOWN
  }

  // STEP 1: Execute culling pass (late pass) - writes draw list
  world.visibility_system_dispatch_culling(
    &world_state.visibility,
    gctx,
    command_buffer,
    camera,
    camera_handle.index,
    frame_index,
    {.VISIBLE},
    {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME},
    rm,
  )

  // STEP 2: Render depth - reads draw list, writes depth[N]
  world.visibility_system_dispatch_depth(
    &world_state.visibility,
    gctx,
    command_buffer,
    camera,
    camera_handle.index,
    frame_index,
    {.VISIBLE},
    {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME},
    rm,
  )

  // STEP 3: Build pyramid - reads depth[N], builds pyramid[N]
  world.visibility_system_dispatch_pyramid(
    &world_state.visibility,
    gctx,
    command_buffer,
    camera,
    camera_handle.index,
    frame_index,
    rm,
  )

  // STEP 4: Render geometry color - reads draw list, reads depth[N] for depth testing
  command_stride := u32(size_of(vk.DrawIndexedIndirectCommand))
  geometry_pass.begin_pass(camera_handle, command_buffer, rm, frame_index)
  geometry_pass.render(
    &self.geometry,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
    camera.late_draw_commands[frame_index].buffer,
    camera.late_draw_count[frame_index].buffer,
    command_stride,
  )
  geometry_pass.end_pass(camera_handle, command_buffer, rm, frame_index)

  geometry_pass.end_record(
    command_buffer,
    camera_handle,
    rm,
    frame_index,
  ) or_return
  return .SUCCESS
}

record_lighting_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  rm: ^resources.Manager,
  camera_handle: resources.Handle,
  color_format: vk.Format,
) -> vk.Result {
  command_buffer := lighting.begin_record(
    &self.lighting,
    frame_index,
    camera_handle,
    rm,
    color_format,
  ) or_return
  lighting.begin_ambient_pass(
    &self.lighting,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
  )
  lighting.render_ambient(
    &self.lighting,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
  )
  lighting.end_ambient_pass(command_buffer)
  lighting.begin_pass(
    &self.lighting,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
  )
  lighting.render(
    &self.lighting,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
  )
  lighting.end_pass(command_buffer)
  lighting.end_record(command_buffer) or_return
  return .SUCCESS
}

record_particles_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  rm: ^resources.Manager,
  camera_handle: resources.Handle,
  color_format: vk.Format,
) -> vk.Result {
  command_buffer := particles.begin_record(
    &self.particles,
    frame_index,
    color_format,
  ) or_return
  particles.begin_pass(
    &self.particles,
    command_buffer,
    camera_handle,
    rm,
    frame_index,
  )
  particles.render(&self.particles, command_buffer, camera_handle.index, rm)
  particles.end_pass(command_buffer)
  particles.end_record(command_buffer) or_return
  return .SUCCESS
}

// TODO: we need a better design for transparency pass, skip for now
record_transparency_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  world_state: ^world.World,
  camera_handle: resources.Handle,
  color_format: vk.Format,
) -> vk.Result {
  command_buffer := transparency.begin_record(
    &self.transparency,
    frame_index,
    camera_handle,
    rm,
    color_format,
  ) or_return
  transparency.begin_pass(
    &self.transparency,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
  )
  navigation_renderer.render(
    &self.navigation,
    command_buffer,
    linalg.MATRIX4F32_IDENTITY,
    camera_handle.index,
    rm,
  )

  camera := resources.get(rm.cameras, camera_handle)
  if camera == nil {
    log.error("Failed to get camera for transparency pass")
    return .ERROR_UNKNOWN
  }

  // Cull transparent objects (depth already rendered in geometry pass)
  // Disable occlusion culling for transparent objects to avoid rejecting sprites
  world.visibility_system_dispatch_culling(
    &world_state.visibility,
    gctx,
    command_buffer,
    camera,
    camera_handle.index,
    frame_index,
    {.VISIBLE, .MATERIAL_TRANSPARENT},
    {},
    rm,
    occlusion_enabled = false,
  )
  command_stride := u32(size_of(vk.DrawIndexedIndirectCommand))

  // Render sprites with sprite pipeline
  transparency.render(
    &self.transparency,
    self.transparency.sprite_pipeline,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
    camera.late_draw_commands[frame_index].buffer,
    camera.late_draw_count[frame_index].buffer,
    command_stride,
  )

  // Cull wireframe objects
  // world.visibility_system_dispatch_culling(
  //   &world_state.visibility,
  //   gctx,
  //   command_buffer,
  //   camera,
  //   camera_handle.index,
  //   frame_index,
  //   {.VISIBLE, .MATERIAL_WIREFRAME},
  //   {},
  //   rm,
  // )
  // transparency.render(
  //   &self.transparency,
  //   self.transparency.wireframe_pipeline,
  //   camera_handle,
  //   command_buffer,
  //   rm,
  //   frame_index,
  //   camera.late_draw_commands[frame_index].buffer,
  //   camera.late_draw_count[frame_index].buffer,
  //   command_stride,
  // )
  transparency.end_pass(&self.transparency, command_buffer)
  transparency.end_record(command_buffer) or_return
  return .SUCCESS
}

record_post_process_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  rm: ^resources.Manager,
  camera_handle: resources.Handle,
  color_format: vk.Format,
  swapchain_extent: vk.Extent2D,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
) -> vk.Result {
  command_buffer := post_process.begin_record(
    &self.post_process,
    frame_index,
    color_format,
    camera_handle,
    rm,
    swapchain_image,
  ) or_return
  post_process.begin_pass(&self.post_process, command_buffer, swapchain_extent)
  post_process.render(
    &self.post_process,
    command_buffer,
    swapchain_extent,
    swapchain_view,
    camera_handle,
    rm,
    frame_index,
  )
  post_process.end_pass(&self.post_process, command_buffer)
  post_process.end_record(command_buffer) or_return
  return .SUCCESS
}
