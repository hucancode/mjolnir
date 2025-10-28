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
import "render/retained_ui"
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
  ui:           debug_ui.Renderer,
  retained_ui:  retained_ui.Manager,
  main_camera:  resources.Handle,
}

record_compute_bootstrap :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  world_state: ^world.World,
  compute_buffer: vk.CommandBuffer,
) -> vk.Result {
  vk.ResetCommandBuffer(compute_buffer, {}) or_return
  vk.BeginCommandBuffer(
    compute_buffer,
    &{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
  ) or_return
  // Generate culling for BOTH frames on bootstrap
  for frame_idx in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
    for &entry, cam_index in rm.cameras.entries {
      if !entry.active do continue
      if resources.PassType.GEOMETRY not_in entry.item.enabled_passes do continue
      cam := &entry.item
      world.visibility_system_dispatch_culling(
        &world_state.visibility,
        gctx,
        compute_buffer,
        cam,
        u32(cam_index),
        u32(frame_idx),
        {.VISIBLE},
        {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME},
        rm,
      )
    }
  }
  vk.EndCommandBuffer(compute_buffer) or_return
  // Submit and wait for completion before first frame starts
  if queue, ok := gctx.compute_queue.?; ok {
    // Async compute: use compute queue
    cmd_buf := compute_buffer
    submit_info := vk.SubmitInfo {
      sType              = .SUBMIT_INFO,
      commandBufferCount = 1,
      pCommandBuffers    = &cmd_buf,
    }
    vk.QueueSubmit(queue, 1, &submit_info, 0) or_return
    vk.QueueWaitIdle(queue) or_return
  } else {
    // Non-async: use graphics queue
    cmd_buf := compute_buffer
    submit_info := vk.SubmitInfo {
      sType              = .SUBMIT_INFO,
      commandBufferCount = 1,
      pCommandBuffers    = &cmd_buf,
    }
    vk.QueueSubmit(gctx.graphics_queue, 1, &submit_info, 0) or_return
    vk.QueueWaitIdle(gctx.graphics_queue) or_return
  }
  return .SUCCESS
}

record_compute_commands :: proc(
  self: ^Renderer,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  world_state: ^world.World,
  compute_buffer: vk.CommandBuffer,
) -> vk.Result {
  vk.ResetCommandBuffer(compute_buffer, {}) or_return
  vk.BeginCommandBuffer(
    compute_buffer,
    &{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
  ) or_return
  // Compute for NEXT frame
  next_frame_index := (frame_index + 1) % resources.MAX_FRAMES_IN_FLIGHT
  for &entry, cam_index in rm.cameras.entries {
    if !entry.active do continue
    if resources.PassType.GEOMETRY not_in entry.item.enabled_passes do continue
    cam := &entry.item
    // STEP 1: Build pyramid[next_frame] from depth[frame_index]
    // This uses the depth buffer that was just written by the previous frame's graphics pass
    world.visibility_system_dispatch_pyramid(
      &world_state.visibility,
      gctx,
      compute_buffer,
      cam,
      u32(cam_index),
      next_frame_index,
      rm,
    )
    // STEP 2: Cull using camera[next_frame] + pyramid[next_frame] → draw_list[next_frame]
    world.visibility_system_dispatch_culling(
      &world_state.visibility,
      gctx,
      compute_buffer,
      cam,
      u32(cam_index),
      next_frame_index,
      {.VISIBLE},
      {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME},
      rm,
    )
  }
  particles.simulate(
    &self.particles,
    compute_buffer,
    rm.world_matrix_descriptor_set,
    rm,
  )
  vk.EndCommandBuffer(compute_buffer) or_return
  return .SUCCESS
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
    {3, 4, 3}, // Camera slightly above and diagonal to origin
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
  debug_ui.init(
    &self.ui,
    gctx,
    swapchain_format,
    swapchain_extent.width,
    swapchain_extent.height,
    dpi_scale,
    rm,
  ) or_return
  retained_ui.init(
    &self.retained_ui,
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
  retained_ui.shutdown(&self.retained_ui, device)
  debug_ui.shutdown(&self.ui, device)
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
    resources.camera_upload_data(rm, cam, u32(cam_index), frame_index)
    world.visibility_system_dispatch_culling(
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
    world.visibility_system_dispatch_depth(
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
    world.visibility_system_dispatch_pyramid(
      &world_state.visibility,
      gctx,
      command_buffer,
      cam,
      u32(cam_index),
      frame_index,
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
  // ═══════════════════════════════════════════════════════════════════════════
  // GRAPHICS QUEUE: Frame N rendering
  // ═══════════════════════════════════════════════════════════════════════════
  // Uses draw_list[N-1] and camera[N-1] (prepared by frame N-1 compute)
  // This enables parallel execution with frame N compute (which prepares data for frame N+1)
  //
  // STEP 1: Render depth[N] using draw_list[N-1] and camera[N-1]
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
  // STEP 2: Render geometry pass using draw_list[N-1] and camera[N-1]
  prev_frame := (frame_index + resources.MAX_FRAMES_IN_FLIGHT - 1) % resources.MAX_FRAMES_IN_FLIGHT
  command_stride := u32(size_of(vk.DrawIndexedIndirectCommand))
  geometry_pass.begin_pass(camera_handle, command_buffer, rm, frame_index)
  geometry_pass.render(
    &self.geometry,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
    camera.late_draw_commands[prev_frame].buffer,
    camera.late_draw_count[prev_frame].buffer,
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
  // Cull transparent objects (no occlusion test, just frustum culling)
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
  )
  // Use previous frame's draw list for transparency rendering
  prev_frame := (frame_index + resources.MAX_FRAMES_IN_FLIGHT - 1) % resources.MAX_FRAMES_IN_FLIGHT
  command_stride := u32(size_of(vk.DrawIndexedIndirectCommand))
  // Render sprites with sprite pipeline
  transparency.render(
    &self.transparency,
    self.transparency.sprite_pipeline,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
    camera.late_draw_commands[prev_frame].buffer,
    camera.late_draw_count[prev_frame].buffer,
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
