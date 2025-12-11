package render

import alg "../algebra"
import cont "../containers"
import "../gpu"
import "../resources"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "debug_draw"
import "debug_ui"
import "geometry"
import "lighting"
import "particles"
import "post_process"
import "retained_ui"
import "transparency"
import vk "vendor:vulkan"
import "visibility"

FRAMES_IN_FLIGHT :: #config(FRAMES_IN_FLIGHT, 2)

Manager :: struct {
  geometry:     geometry.Renderer,
  lighting:     lighting.Renderer,
  transparency: transparency.Renderer,
  particles:    particles.Renderer,
  debug_draw:   debug_draw.Renderer,
  post_process: post_process.Renderer,
  debug_ui:     debug_ui.Renderer,
  retained_ui:  retained_ui.Manager,
  main_camera:  resources.CameraHandle,
  visibility:   visibility.VisibilitySystem,
}

record_compute_commands :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  compute_buffer: vk.CommandBuffer,
) -> vk.Result {
  gpu.begin_record(compute_buffer) or_return
  // Compute for frame N prepares data for frame N+1
  // Buffer indices with FRAMES_IN_FLIGHT=2: frame N uses buffer [N], produces data for buffer [N+1]
  next_frame_index := alg.next(frame_index, FRAMES_IN_FLIGHT)
  for &entry, cam_index in rm.cameras.entries do if entry.active {
    cam := &entry.item
    resources.camera_upload_data(rm, u32(cam_index), frame_index)
    visibility.build_pyramid(&self.visibility, gctx, compute_buffer, cam, u32(cam_index), frame_index,  rm)// Build pyramid[N]
    visibility.perform_culling(&self.visibility, gctx, compute_buffer, cam, u32(cam_index), next_frame_index,  {.VISIBLE}, {}, rm)// Write draw_list[N+1]
  }
  for &entry, cam_index in rm.spherical_cameras.entries do if entry.active {
    cam := &entry.item
    resources.spherical_camera_upload_data(rm, cam, u32(cam_index), frame_index)
    visibility.perform_sphere_culling(&self.visibility, gctx, compute_buffer, cam, u32(cam_index), next_frame_index,  {.VISIBLE}, {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME}, rm)// Write draw_list[N+1]
  }
  particles.simulate(
    &self.particles,
    compute_buffer,
    rm.world_matrix_buffer.descriptor_set,
    rm,
  )
  gpu.end_record(compute_buffer) or_return
  return .SUCCESS
}

init :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  swapchain_extent: vk.Extent2D,
  swapchain_format: vk.Format,
  dpi_scale: f32,
) -> (
  ret: vk.Result,
) {
  camera_handle, camera, ok := cont.alloc(&rm.cameras, resources.CameraHandle)
  if !ok {
    return .ERROR_INITIALIZATION_FAILED
  }
  defer if ret != .SUCCESS {
    cont.free(&rm.cameras, camera_handle)
  }
  resources.camera_init(
    camera,
    gctx,
    rm,
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
    .D32_SFLOAT,
    {.SHADOW, .GEOMETRY, .LIGHTING, .TRANSPARENCY, .PARTICLES, .DEBUG_DRAW, .POST_PROCESS},
    {3, 4, 3}, // Camera slightly above and diagonal to origin
    {0, 0, 0}, // Looking at origin
    math.PI * 0.5, // FOV
    0.1, // near plane
    100.0, // far plane
  ) or_return
  self.main_camera = camera_handle
  visibility.init(
    &self.visibility,
    gctx,
    rm,
    swapchain_extent.width,
    swapchain_extent.height,
  ) or_return
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    resources.camera_allocate_descriptors(
      gctx,
      rm,
      camera,
      u32(frame),
      &self.visibility.normal_cam_descriptor_layout,
      &self.visibility.depth_reduce_descriptor_layout,
    ) or_return
  }
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
    &self.debug_ui,
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
  debug_draw.init(&self.debug_draw, gctx, rm) or_return
  return .SUCCESS
}

shutdown :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) {
  retained_ui.shutdown(&self.retained_ui, gctx)
  debug_ui.shutdown(&self.debug_ui, gctx)
  debug_draw.shutdown(&self.debug_draw, gctx)
  post_process.shutdown(&self.post_process, gctx, rm)
  particles.shutdown(&self.particles, gctx)
  transparency.shutdown(&self.transparency, gctx)
  lighting.shutdown(&self.lighting, gctx, rm)
  geometry.shutdown(&self.geometry, gctx)
  visibility.shutdown(&self.visibility, gctx)
}

resize :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  extent: vk.Extent2D,
  color_format: vk.Format,
  dpi_scale: f32,
) -> vk.Result {
  lighting.recreate_images(
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

render_camera_depth :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  for &entry, cam_index in rm.cameras.entries do if entry.active {
    cam := &entry.item
    visibility.render_depth(&self.visibility, gctx, command_buffer, cam, u32(cam_index), frame_index, {.VISIBLE}, {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME}, rm)
  }
  for &entry, cam_index in rm.spherical_cameras.entries do if entry.active {
    cam := &entry.item
    visibility.render_sphere_depth(&self.visibility, gctx, command_buffer, cam, u32(cam_index), frame_index, {.VISIBLE}, {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME}, rm)
  }
  return .SUCCESS
}

record_geometry_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  camera_handle: resources.CameraHandle,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil do return .ERROR_UNKNOWN
  geometry.begin_pass(camera_handle, command_buffer, rm, frame_index)
  geometry.render(
    &self.geometry,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
    camera.opaque_draw_commands[frame_index].buffer,
    camera.opaque_draw_count[frame_index].buffer,
  )
  geometry.end_pass(camera_handle, command_buffer, rm, frame_index)
  return .SUCCESS
}

record_lighting_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  rm: ^resources.Manager,
  camera_handle: resources.CameraHandle,
  color_format: vk.Format,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
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
  return .SUCCESS
}

record_particles_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  rm: ^resources.Manager,
  camera_handle: resources.CameraHandle,
  color_format: vk.Format,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  particles.begin_pass(
    &self.particles,
    command_buffer,
    camera_handle,
    rm,
    frame_index,
  )
  particles.render(&self.particles, command_buffer, camera_handle.index, rm)
  particles.end_pass(command_buffer)
  return .SUCCESS
}

record_transparency_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  camera_handle: resources.CameraHandle,
  color_format: vk.Format,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  camera, ok := cont.get(rm.cameras, camera_handle)
  if !ok do return .ERROR_UNKNOWN
  // Barrier: Wait for compute to finish before reading draw commands
  gpu.buffer_barrier(
    command_buffer,
    camera.transparent_draw_commands[frame_index].buffer,
    vk.DeviceSize(camera.transparent_draw_commands[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    camera.transparent_draw_count[frame_index].buffer,
    vk.DeviceSize(camera.transparent_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    camera.sprite_draw_commands[frame_index].buffer,
    vk.DeviceSize(camera.sprite_draw_commands[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    camera.sprite_draw_count[frame_index].buffer,
    vk.DeviceSize(camera.sprite_draw_count[frame_index].bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  transparency.begin_pass(
    &self.transparency,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
  )
  transparency.render(
    &self.transparency,
    self.transparency.transparent_pipeline,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
    camera.transparent_draw_commands[frame_index].buffer,
    camera.transparent_draw_count[frame_index].buffer,
  )
  transparency.render(
    &self.transparency,
    self.transparency.sprite_pipeline,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
    camera.sprite_draw_commands[frame_index].buffer,
    camera.sprite_draw_count[frame_index].buffer,
  )
  transparency.end_pass(&self.transparency, command_buffer)
  return .SUCCESS
}

record_debug_draw_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  rm: ^resources.Manager,
  camera_handle: resources.CameraHandle,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  debug_draw.update(&self.debug_draw, rm)
  debug_draw.begin_pass(
    &self.debug_draw,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
  )
  debug_draw.render(
    &self.debug_draw,
    camera_handle,
    command_buffer,
    rm,
    frame_index,
  )
  debug_draw.end_pass(&self.debug_draw, command_buffer)
  return .SUCCESS
}

record_post_process_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  rm: ^resources.Manager,
  camera_handle: resources.CameraHandle,
  color_format: vk.Format,
  swapchain_extent: vk.Extent2D,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
  command_buffer: vk.CommandBuffer,
) -> vk.Result {
  if camera, ok := cont.get(rm.cameras, camera_handle); ok {
    if final_image, ok := cont.get(
      rm.images_2d,
      camera.attachments[.FINAL_IMAGE][frame_index],
    ); ok {
      gpu.image_barrier(
        command_buffer,
        final_image.image,
        .COLOR_ATTACHMENT_OPTIMAL,
        .SHADER_READ_ONLY_OPTIMAL,
        {.COLOR_ATTACHMENT_WRITE},
        {.SHADER_READ},
        {.COLOR_ATTACHMENT_OUTPUT},
        {.FRAGMENT_SHADER},
        {.COLOR},
      )
    }
  }
  gpu.image_barrier(
    command_buffer,
    swapchain_image,
    .UNDEFINED,
    .COLOR_ATTACHMENT_OPTIMAL,
    {},
    {.COLOR_ATTACHMENT_WRITE},
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.COLOR},
  )
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
  return .SUCCESS
}
