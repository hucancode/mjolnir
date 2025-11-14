package mjolnir

import cont "containers"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "gpu"
import "render/debug_ui"
import "render/geometry"
import "render/lighting"
import "render/navigation"
import "render/particles"
import "render/post_process"
import "render/retained_ui"
import "render/transparency"
import "resources"
import vk "vendor:vulkan"
import "world"

Renderer :: struct {
  geometry:     geometry.Renderer,
  lighting:     lighting.Renderer,
  transparency: transparency.Renderer,
  particles:    particles.Renderer,
  navigation:   navigation.Renderer,
  post_process: post_process.Renderer,
  ui:           debug_ui.Renderer,
  retained_ui:  retained_ui.Manager,
  main_camera:  resources.Handle,
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
  // Compute for frame N prepares data for frame N+1
  // Buffer indices with MAX_FRAMES_IN_FLIGHT=2: frame N uses buffer [N], produces data for buffer [N+1]
  next_frame_index := (frame_index + 1) % resources.MAX_FRAMES_IN_FLIGHT
  for &entry, cam_index in rm.cameras.entries {
    if !entry.active do continue
    if resources.PassType.GEOMETRY not_in entry.item.enabled_passes do continue
    cam := &entry.item
    // STEP 1: Build pyramid[N] from depth[N-1]
    // This allows Compute N to build pyramid[N] from Render N-1's depth
    world.visibility_system_dispatch_pyramid(
      &world_state.visibility,
      gctx,
      compute_buffer,
      cam,
      u32(cam_index),
      frame_index, // Build pyramid[N]
      rm,
    )
    // STEP 2: Cull using camera[N] + pyramid[N] → draw_list[N+1]
    // Reads pyramid[frame_index], writes draw_list[next_frame_index]
    // This produces draw_list[N+1] for use by Render N+1
    world.visibility_system_dispatch_culling(
      &world_state.visibility,
      gctx,
      compute_buffer,
      cam,
      u32(cam_index),
      next_frame_index, // Write draw_list[N+1]
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
) -> (ret: vk.Result) {
  main_camera_handle, main_camera_ptr, main_camera_ok := cont.alloc(
    &rm.cameras,
  )
  if !main_camera_ok {
    log.error("Failed to allocate main camera")
    return .ERROR_INITIALIZATION_FAILED
  }
  defer if ret != .SUCCESS {
    cont.free(&rm.cameras, main_camera_handle)
  }
  resources.camera_init(
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
  ) or_return
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
  geometry.init(
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
  navigation.init(&self.navigation, gctx, rm) or_return
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
  navigation.shutdown(&self.navigation, device, command_pool)
  post_process.shutdown(&self.post_process, device, command_pool, rm)
  particles.shutdown(&self.particles, device, command_pool)
  transparency.shutdown(&self.transparency, device, command_pool)
  lighting.shutdown(&self.lighting, device, command_pool, rm)
  geometry.shutdown(&self.geometry, device, command_pool)
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
    // Upload camera data to GPU buffer (per-frame to avoid frame overlap)
    resources.spherical_camera_upload_data(
      rm,
      spherical_cam,
      u32(cam_index),
      frame_index,
    )
    // Dispatch visibility - records compute culling + depth rendering
    world.visibility_system_dispatch_spherical(
      &world_state.visibility,
      gctx,
      command_buffer,
      spherical_cam,
      u32(cam_index),
      frame_index,
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
  command_buffer := geometry.begin_record(
    &self.geometry,
    frame_index,
    camera_handle,
    rm,
  ) or_return
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil {
    log.error("Failed to get camera for geometry pass")
    return .ERROR_UNKNOWN
  }
  // ═══════════════════════════════════════════════════════════════════════════
  // GRAPHICS QUEUE: Frame N rendering
  // ═══════════════════════════════════════════════════════════════════════════
  // Uses draw_list[N] (prepared by frame N-1 compute) and camera[N] (current frame)
  // Runs in parallel with frame N compute (which prepares draw_list[N+1] for frame N+1)
  //
  // STEP 1: Render depth[N] using draw_list[N], camera[N]
  // This depth will be read by frame N+1 compute for pyramid building
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
  // STEP 2: Render geometry pass using draw_list[N], camera[N]
  // draw_list[frame_index] was written by Compute N-1, safe to read during Render N
  command_stride := u32(size_of(vk.DrawIndexedIndirectCommand))
  geometry.begin_pass(camera_handle, command_buffer, rm, frame_index)
  geometry.render(
    &self.geometry,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
    camera.late_draw_commands[frame_index].buffer,
    camera.late_draw_count[frame_index].buffer,
    command_stride,
  )
  geometry.end_pass(camera_handle, command_buffer, rm, frame_index)
  geometry.end_record(command_buffer, camera_handle, rm, frame_index) or_return
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
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil {
    log.error("Failed to get camera for transparency pass")
    return .ERROR_UNKNOWN
  }
  command_stride := u32(size_of(vk.DrawIndexedIndirectCommand))
  // Single dispatch to generate all 3 draw lists (late, transparent, sprite)
  world.visibility_system_dispatch_culling(
    &world_state.visibility,
    gctx,
    command_buffer,
    camera,
    camera_handle.index,
    frame_index,
    {.VISIBLE},
    {},
    rm,
  )
  // Barrier: Wait for compute to finish before reading draw commands
  compute_done := [?]vk.BufferMemoryBarrier {
    {
      sType = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.SHADER_WRITE},
      dstAccessMask = {.INDIRECT_COMMAND_READ},
      buffer = camera.transparent_draw_commands[frame_index].buffer,
      size = vk.DeviceSize(
        camera.transparent_draw_commands[frame_index].bytes_count,
      ),
    },
    {
      sType = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.SHADER_WRITE},
      dstAccessMask = {.INDIRECT_COMMAND_READ},
      buffer = camera.transparent_draw_count[frame_index].buffer,
      size = vk.DeviceSize(
        camera.transparent_draw_count[frame_index].bytes_count,
      ),
    },
    {
      sType = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.SHADER_WRITE},
      dstAccessMask = {.INDIRECT_COMMAND_READ},
      buffer = camera.sprite_draw_commands[frame_index].buffer,
      size = vk.DeviceSize(
        camera.sprite_draw_commands[frame_index].bytes_count,
      ),
    },
    {
      sType = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.SHADER_WRITE},
      dstAccessMask = {.INDIRECT_COMMAND_READ},
      buffer = camera.sprite_draw_count[frame_index].buffer,
      size = vk.DeviceSize(camera.sprite_draw_count[frame_index].bytes_count),
    },
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
    {},
    0,
    nil,
    len(compute_done),
    raw_data(compute_done[:]),
    0,
    nil,
  )
  transparency.begin_pass(
    &self.transparency,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
  )
  navigation.render(
    &self.navigation,
    command_buffer,
    linalg.MATRIX4F32_IDENTITY,
    camera_handle.index,
    rm,
  )
  // Render transparent meshes with transparent pipeline
  transparency.render(
    &self.transparency,
    self.transparency.transparent_pipeline,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
    camera.transparent_draw_commands[frame_index].buffer,
    camera.transparent_draw_count[frame_index].buffer,
    command_stride,
  )
  // Render sprites with sprite pipeline
  transparency.render(
    &self.transparency,
    self.transparency.sprite_pipeline,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
    camera.sprite_draw_commands[frame_index].buffer,
    camera.sprite_draw_count[frame_index].buffer,
    command_stride,
  )
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
