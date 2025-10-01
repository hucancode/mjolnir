package mjolnir

import "core:log"
import "core:math"
import "core:math/linalg"
import "geometry"
import "gpu"
import "render/debug_ui"
import geometry_pass "render/geometry"
import "render/lighting"
import navigation_renderer "render/navigation"
import "render/particles"
import "render/post_process"
import "render/shadow"
import "render/targets"
import "render/text"
import "render/transparency"
import "resources"
import vk "vendor:vulkan"
import "world"

Renderer :: struct {
  shadow:                     shadow.Renderer,
  geometry:                   geometry_pass.Renderer,
  lighting:                   lighting.Renderer,
  transparency:               transparency.Renderer,
  particles:                  particles.Renderer,
  navigation:                 navigation_renderer.Renderer,
  post_process:               post_process.Renderer,
  text:                       text.Renderer,
  ui:                         debug_ui.Renderer,
  main_render_target_index:   int,
  render_targets:             [dynamic]targets.RenderTarget,
  primary_command_buffers:    [resources.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
}

renderer_init :: proc(
  self: ^Renderer,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  swapchain_extent: vk.Extent2D,
  swapchain_format: vk.Format,
  main_render_target: resources.Handle,
  dpi_scale: f32,
) -> vk.Result {
  lighting.init(
    &self.lighting,
    gpu_context,
    resources_manager,
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
    vk.Format.D32_SFLOAT,
  ) or_return
  geometry_pass.init(
    &self.geometry,
    gpu_context,
    swapchain_extent.width,
    swapchain_extent.height,
    resources_manager,
  ) or_return
  particles.init(&self.particles, gpu_context, resources_manager) or_return
  transparency.init(
    &self.transparency,
    gpu_context,
    swapchain_extent.width,
    swapchain_extent.height,
    resources_manager,
  ) or_return
  shadow.init(&self.shadow, gpu_context, resources_manager) or_return
  post_process.init(
    &self.post_process,
    gpu_context,
    swapchain_format,
    swapchain_extent.width,
    swapchain_extent.height,
    resources_manager,
  ) or_return
  text.init(
    &self.text,
    gpu_context,
    swapchain_format,
    swapchain_extent.width,
    swapchain_extent.height,
    resources_manager,
  ) or_return
  debug_ui.init(
    &self.ui,
    gpu_context,
    swapchain_format,
    swapchain_extent.width,
    swapchain_extent.height,
    dpi_scale,
    resources_manager,
  ) or_return
  navigation_renderer.init(
    &self.navigation,
    gpu_context,
    resources_manager,
  ) or_return

  self.main_render_target_index = -1
  self.render_targets = make([dynamic]targets.RenderTarget, 0)

  alloc_info := vk.CommandBufferAllocateInfo {
    sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool        = gpu_context.command_pool,
    level              = .PRIMARY,
    commandBufferCount = resources.MAX_FRAMES_IN_FLIGHT,
  }

  vk.AllocateCommandBuffers(
    gpu_context.device,
    &alloc_info,
    raw_data(self.primary_command_buffers[:]),
  ) or_return

  return .SUCCESS
}

renderer_shutdown :: proc(
  self: ^Renderer,
  device: vk.Device,
  command_pool: vk.CommandPool,
  resources_manager: ^resources.Manager,
) {
  vk.FreeCommandBuffers(
    device,
    command_pool,
    resources.MAX_FRAMES_IN_FLIGHT,
    raw_data(self.primary_command_buffers[:]),
  )
  self.primary_command_buffers = {}

  for &capture in self.render_targets {
    targets.render_target_destroy(
      &capture,
      device,
      command_pool,
      resources_manager,
    )
  }
  delete(self.render_targets)

  debug_ui.shutdown(&self.ui, device)
  text.shutdown(&self.text, device)
  navigation_renderer.shutdown(&self.navigation, device, command_pool)
  post_process.shutdown(
    &self.post_process,
    device,
    command_pool,
    resources_manager,
  )
  particles.shutdown(&self.particles, device, command_pool)
  transparency.shutdown(&self.transparency, device, command_pool)
  lighting.shutdown(&self.lighting, device, command_pool, resources_manager)
  geometry_pass.shutdown(&self.geometry, device, command_pool)
  shadow.shutdown(&self.shadow, device, command_pool)
}

resize :: proc(
  self: ^Renderer,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
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
    gpu_context,
    &self.post_process,
    extent.width,
    extent.height,
    color_format,
    resources_manager,
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

record_shadow_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  world_state: ^world.World,
  target: ^targets.RenderTarget,
) -> vk.Result {
  command_buffer := shadow.begin_record(&self.shadow, frame_index) or_return
  // Ensure world matrix staging buffer transfers complete before shadow rendering
  world_matrix_barrier := vk.BufferMemoryBarrier {
    sType               = .BUFFER_MEMORY_BARRIER,
    srcAccessMask       = {.TRANSFER_WRITE},
    dstAccessMask       = {.SHADER_READ, .UNIFORM_READ},
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    buffer              = resources_manager.world_matrix_buffer.device_buffer,
    offset              = 0,
    size                = vk.DeviceSize(vk.WHOLE_SIZE),
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.TRANSFER},
    {.VERTEX_SHADER},
    {},
    0,
    nil,
    1,
    &world_matrix_barrier,
    0,
    nil,
  )
  shadow_include := resources.NodeFlagSet{.VISIBLE, .CASTS_SHADOW}
  shadow_exclude := resources.NodeFlagSet {
    .MATERIAL_TRANSPARENT,
    .MATERIAL_WIREFRAME,
  }
  command_stride := world.draw_command_stride()
  // Get main camera frustum for culling lights outside view
  main_camera, camera_ok := resources.get_camera(
    resources_manager,
    target.camera,
  )
  if !camera_ok {
    log.errorf("Main camera not found")
    return .ERROR_UNKNOWN
  }
  main_frustum := geometry.camera_make_frustum(main_camera^)
  visible_count := 0
  for idx in 0 ..< len(resources_manager.lights.entries) {
    entry := &resources_manager.lights.entries[idx]
    if entry.generation > 0 && entry.active {
      light := &entry.item
      if !light.cast_shadow do continue
      // Directional lights are never culled
      if light.type != .DIRECTIONAL {
        world_matrix := gpu.staged_buffer_get(
          &resources_manager.world_matrix_buffer,
          light.node_handle.index,
        )
        light_position := world_matrix[3].xyz
        // Skip shadow rendering if light is outside camera frustum
        if !geometry.frustum_test_sphere(
          light_position,
          light.radius,
          &main_frustum,
        ) {
          continue
        }
      }
      visible_count += 1
      switch light.type {
      case .POINT:
        for face in 0 ..< 6 {
          target_idx := light.cube_shadow_target_index[face]
          if target_idx < 0 || target_idx >= len(self.render_targets) do continue
          found_target := &self.render_targets[target_idx]
          if found_target.camera.generation == 0 do continue
          vis_result := world.dispatch_visibility(
            world_state,
            gpu_context,
            command_buffer,
            frame_index,
            .SHADOW,
            world.VisibilityRequest {
              camera_index = found_target.camera.index,
              include_flags = shadow_include,
              exclude_flags = shadow_exclude,
            },
          )
          shadow_draw_buffer := vis_result.draw_buffer
          shadow_count_buffer := vis_result.count_buffer
          shadow.begin_pass(
            found_target,
            command_buffer,
            resources_manager,
            frame_index,
            u32(face),
          )
          shadow.render(
            &self.shadow,
            found_target^,
            command_buffer,
            resources_manager,
            frame_index,
            shadow_draw_buffer,
            shadow_count_buffer,
            command_stride,
          )
          shadow.end_pass(
            command_buffer,
            found_target,
            resources_manager,
            frame_index,
            u32(face),
          )
        }
      case .SPOT:
        target_idx := light.shadow_target_index
        if target_idx < 0 || target_idx >= len(self.render_targets) do continue
        found_target := &self.render_targets[target_idx]
        if found_target.camera.generation == 0 do continue
        vis_result := world.dispatch_visibility(
          world_state,
          gpu_context,
          command_buffer,
          frame_index,
          .SHADOW,
          world.VisibilityRequest {
            camera_index = found_target.camera.index,
            include_flags = shadow_include,
            exclude_flags = shadow_exclude,
          },
        )
        shadow_draw_buffer := vis_result.draw_buffer
        shadow_count_buffer := vis_result.count_buffer
        shadow.begin_pass(
          found_target,
          command_buffer,
          resources_manager,
          frame_index,
        )
        shadow.render(
          &self.shadow,
          found_target^,
          command_buffer,
          resources_manager,
          frame_index,
          shadow_draw_buffer,
          shadow_count_buffer,
          command_stride,
        )
        shadow.end_pass(
          command_buffer,
          found_target,
          resources_manager,
          frame_index,
        )
      case .DIRECTIONAL:
        target_idx := light.shadow_target_index
        if target_idx < 0 || target_idx >= len(self.render_targets) do continue
        found_target := &self.render_targets[target_idx]
        if found_target.camera.generation == 0 do continue
        vis_result := world.dispatch_visibility(
          world_state,
          gpu_context,
          command_buffer,
          frame_index,
          .SHADOW,
          world.VisibilityRequest {
            camera_index = found_target.camera.index,
            include_flags = shadow_include,
            exclude_flags = shadow_exclude,
          },
        )
        shadow_draw_buffer := vis_result.draw_buffer
        shadow_count_buffer := vis_result.count_buffer
        shadow.begin_pass(
          found_target,
          command_buffer,
          resources_manager,
          frame_index,
        )
        shadow.render(
          &self.shadow,
          found_target^,
          command_buffer,
          resources_manager,
          frame_index,
          shadow_draw_buffer,
          shadow_count_buffer,
          command_stride,
        )
        shadow.end_pass(
          command_buffer,
          found_target,
          resources_manager,
          frame_index,
        )
      }
    }
  }
  // log.debugf("Visible shadow-casting lights: %d", visible_count)
  shadow.end_record(command_buffer) or_return
  return .SUCCESS
}

record_geometry_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  world_state: ^world.World,
  target: ^targets.RenderTarget,
) -> vk.Result {
  command_buffer := geometry_pass.begin_record(
    &self.geometry,
    frame_index,
    target,
    resources_manager,
  ) or_return
  vis_result := world.dispatch_visibility(
    world_state,
    gpu_context,
    command_buffer,
    frame_index,
    .OPAQUE,
    world.VisibilityRequest {
      camera_index = target.camera.index,
      include_flags = {.VISIBLE},
      exclude_flags = {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME},
    },
  )
  draw_buffer := vis_result.draw_buffer
  count_buffer := vis_result.count_buffer
  command_stride := vis_result.command_stride
  geometry_pass.begin_depth_prepass(
    target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  geometry_pass.render_depth_prepass(
    &self.geometry,
    command_buffer,
    target.camera.index,
    resources_manager,
    frame_index,
    draw_buffer,
    count_buffer,
    command_stride,
  )
  geometry_pass.end_depth_prepass(command_buffer)
  geometry_pass.begin_pass(
    target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  geometry_pass.render(
    &self.geometry,
    target,
    command_buffer,
    resources_manager,
    frame_index,
    draw_buffer,
    count_buffer,
    command_stride,
  )
  geometry_pass.end_pass(
    target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  geometry_pass.end_record(
    command_buffer,
    target,
    resources_manager,
    frame_index,
  ) or_return
  return .SUCCESS
}

record_lighting_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  resources_manager: ^resources.Manager,
  target: ^targets.RenderTarget,
  color_format: vk.Format,
) -> vk.Result {
  command_buffer := lighting.begin_record(
    &self.lighting,
    frame_index,
    color_format,
  ) or_return
  lighting.begin_ambient_pass(
    &self.lighting,
    target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  lighting.render_ambient(
    &self.lighting,
    target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  lighting.end_ambient_pass(command_buffer)
  lighting.begin_pass(
    &self.lighting,
    target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  lighting.render(
    &self.lighting,
    target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  lighting.end_pass(command_buffer)
  lighting.end_record(command_buffer) or_return
  return .SUCCESS
}

record_particles_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  resources_manager: ^resources.Manager,
  target: ^targets.RenderTarget,
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
    target,
    resources_manager,
    frame_index,
  )
  particles.render(
    &self.particles,
    command_buffer,
    target.camera.index,
    resources_manager,
  )
  particles.end_pass(command_buffer)
  particles.end_record(command_buffer) or_return
  return .SUCCESS
}

record_transparency_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  world_state: ^world.World,
  target: ^targets.RenderTarget,
  color_format: vk.Format,
) -> vk.Result {
  command_buffer := transparency.begin_record(
    &self.transparency,
    frame_index,
    color_format,
  ) or_return
  transparency.begin_pass(
    &self.transparency,
    target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  navigation_renderer.render(
    &self.navigation,
    command_buffer,
    linalg.MATRIX4F32_IDENTITY,
    target.camera.index,
    resources_manager,
  )
  vis_transparent := world.dispatch_visibility(
    world_state,
    gpu_context,
    command_buffer,
    frame_index,
    .TRANSPARENT,
    world.VisibilityRequest {
      camera_index = target.camera.index,
      include_flags = {.VISIBLE, .MATERIAL_TRANSPARENT},
      exclude_flags = {},
    },
  )
  command_stride := vis_transparent.command_stride
  transparency.render(
    &self.transparency,
    self.transparency.transparent_pipeline,
    target,
    command_buffer,
    resources_manager,
    frame_index,
    vis_transparent.draw_buffer,
    vis_transparent.count_buffer,
    command_stride,
  )
  vis_wireframe := world.dispatch_visibility(
    world_state,
    gpu_context,
    command_buffer,
    frame_index,
    .WIREFRAME,
    world.VisibilityRequest {
      camera_index = target.camera.index,
      include_flags = {.VISIBLE, .MATERIAL_WIREFRAME},
      exclude_flags = {},
    },
  )
  transparency.render(
    &self.transparency,
    self.transparency.wireframe_pipeline,
    target,
    command_buffer,
    resources_manager,
    frame_index,
    vis_wireframe.draw_buffer,
    vis_wireframe.count_buffer,
    command_stride,
  )
  transparency.end_pass(&self.transparency, command_buffer)
  transparency.end_record(command_buffer) or_return
  return .SUCCESS
}

record_post_process_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  resources_manager: ^resources.Manager,
  target: ^targets.RenderTarget,
  color_format: vk.Format,
  swapchain_extent: vk.Extent2D,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
) -> vk.Result {
  command_buffer := post_process.begin_record(
    &self.post_process,
    frame_index,
    color_format,
    target,
    resources_manager,
    swapchain_image,
  ) or_return
  post_process.begin_pass(&self.post_process, command_buffer, swapchain_extent)
  post_process.render(
    &self.post_process,
    command_buffer,
    swapchain_extent,
    swapchain_view,
    target,
    resources_manager,
    frame_index,
  )
  post_process.end_pass(&self.post_process, command_buffer)
  post_process.end_record(command_buffer) or_return
  return .SUCCESS
}

renderer_add_render_target :: proc(
  self: ^Renderer,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  width, height: u32,
  color_format: vk.Format = vk.Format.R8G8B8A8_UNORM,
  depth_format: vk.Format = vk.Format.D32_SFLOAT,
  camera_position: [3]f32 = {0, 0, 3},
  camera_target: [3]f32 = {0, 0, 0},
  fov: f32 = 1.57079632679,
  near_plane: f32 = 0.1,
  far_plane: f32 = 100.0,
  enabled_passes: targets.PassTypeSet = {
    .SHADOW,
    .GEOMETRY,
    .LIGHTING,
    .TRANSPARENCY,
    .PARTICLES,
  },
) -> (
  index: int,
  ok: bool,
) {
  capture, capture_ok := targets.create_render_target(
    gpu_context,
    resources_manager,
    width,
    height,
    color_format,
    depth_format,
    camera_position,
    camera_target,
    fov,
    near_plane,
    far_plane,
    enabled_passes,
  )
  if !capture_ok do return -1, false

  append(&self.render_targets, capture)
  return len(self.render_targets) - 1, true
}

renderer_get_render_target :: proc(
  self: ^Renderer,
  index: int,
) -> (
  capture: ^targets.RenderTarget,
  ok: bool,
) {
  if index < 0 || index >= len(self.render_targets) do return nil, false
  return &self.render_targets[index], true
}

renderer_remove_render_target :: proc(
  self: ^Renderer,
  index: int,
  device: vk.Device,
  command_pool: vk.CommandPool,
  resources_manager: ^resources.Manager,
) {
  if index < 0 || index >= len(self.render_targets) do return

  capture := &self.render_targets[index]
  targets.render_target_destroy(
    capture,
    device,
    command_pool,
    resources_manager,
  )

  ordered_remove(&self.render_targets, index)
}

record_render_target :: proc(
  self: ^Renderer,
  capture_index: int,
  frame_index: u32,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  world_state: ^world.World,
  command_buffer: vk.CommandBuffer,
  color_format: vk.Format,
) -> vk.Result {
  capture, capture_ok := renderer_get_render_target(self, capture_index)
  if !capture_ok do return .ERROR_UNKNOWN

  // Update camera data
  targets.render_target_upload_camera_data(resources_manager, capture)

  // Query visibility for capture camera
  vis_result := world.query_visibility(
    world_state,
    gpu_context,
    command_buffer,
    frame_index,
    world.DrawCommandRequest {
      camera_handle = {index = capture.camera.index},
      include_flags = {.VISIBLE},
      exclude_flags = {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME},
      category = .CUSTOM0,
    },
  )

  draw_buffer := vis_result.draw_buffer
  count_buffer := vis_result.count_buffer

  // Render G-buffer pass
  if .GEOMETRY in capture.enabled_passes {
    geometry_pass.begin_pass(
      capture,
      command_buffer,
      resources_manager,
      frame_index,
      self_manage_depth = true,
    )

    geometry_pass.render(
      &self.geometry,
      capture,
      command_buffer,
      resources_manager,
      frame_index,
      draw_buffer,
      count_buffer,
      vis_result.command_stride,
    )

    geometry_pass.end_pass(
      capture,
      command_buffer,
      resources_manager,
      frame_index,
    )
  }

  // Render lighting pass
  if .LIGHTING in capture.enabled_passes {
    lighting.begin_ambient_pass(
      &self.lighting,
      capture,
      command_buffer,
      resources_manager,
      frame_index,
    )
    lighting.render_ambient(
      &self.lighting,
      capture,
      command_buffer,
      resources_manager,
      frame_index,
    )
    lighting.end_ambient_pass(command_buffer)

    lighting.begin_pass(
      &self.lighting,
      capture,
      command_buffer,
      resources_manager,
      frame_index,
    )
    lighting.render(
      &self.lighting,
      capture,
      command_buffer,
      resources_manager,
      frame_index,
    )
    lighting.end_pass(command_buffer)
  }

  return .SUCCESS
}

record_all_render_targets :: proc(
  self: ^Renderer,
  frame_index: u32,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  world_state: ^world.World,
  command_buffer: vk.CommandBuffer,
  color_format: vk.Format,
) -> vk.Result {
  for i in 0 ..< len(self.render_targets) {
    record_render_target(
      self,
      i,
      frame_index,
      gpu_context,
      resources_manager,
      world_state,
      command_buffer,
      color_format,
    ) or_return
  }
  return .SUCCESS
}

renderer_get_render_target_output :: proc(
  self: ^Renderer,
  capture_index: int,
  resources_manager: ^resources.Manager,
  frame_index: u32,
) -> (
  output: resources.Handle,
  ok: bool,
) {
  capture, capture_ok := renderer_get_render_target(self, capture_index)
  if !capture_ok do return {}, false

  return targets.get_final_image(capture, frame_index), true
}

// Setup shadow resources for a light
renderer_setup_light_shadows :: proc(
  self: ^Renderer,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  light_handle: resources.Handle,
) -> bool {
  light, ok := resources.get_light(resources_manager, light_handle)
  if !ok do return false

  if !light.cast_shadow do return true

  switch light.type {
  case .POINT:
    // Create cube shadow map texture
    cube_shadow_handle, _, ret := resources.create_empty_texture_cube(
      gpu_context,
      resources_manager,
      resources.SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    )
    if ret != .SUCCESS {
      log.errorf("Failed to create cube shadow texture: %v", ret)
      return false
    }
    light.shadow_map = cube_shadow_handle.index

    // Create 6 render targets for cube faces
    for face in 0 ..< 6 {
      target, target_ok := targets.create_render_target(
        gpu_context,
        resources_manager,
        resources.SHADOW_MAP_SIZE,
        resources.SHADOW_MAP_SIZE,
        .D32_SFLOAT,
        .D32_SFLOAT,
        enabled_passes = {.SHADOW},
      )
      if !target_ok {
        log.errorf(
          "Failed to create shadow render target for point light face %d",
          face,
        )
        return false
      }

      // Set depth texture to cube shadow map
      for frame_idx in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
        target.attachments[.DEPTH][frame_idx] = cube_shadow_handle
      }

      // Update camera to perspective for cube face
      camera, camera_ok := resources.get_camera(
        resources_manager,
        target.camera,
      )
      if camera_ok {
        camera^ = geometry.make_camera_perspective(
          math.PI * 0.5,
          1.0,
          0.1,
          light.radius,
        )
      }

      append(&self.render_targets, target)
      light.cube_shadow_target_index[face] = len(self.render_targets) - 1

      // Set camera_index to first cube face camera (face 0)
      if face == 0 {
        light.camera_index = target.camera.index
      }
    }

  case .SPOT:
    // Create shadow map texture
    shadow_handle, _, ret := resources.create_empty_texture_2d(
      gpu_context,
      resources_manager,
      resources.SHADOW_MAP_SIZE,
      resources.SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    )
    if ret != .SUCCESS {
      log.errorf("Failed to create spot shadow texture")
      return false
    }
    light.shadow_map = shadow_handle.index

    // Create render target
    target, target_ok := targets.create_render_target(
      gpu_context,
      resources_manager,
      resources.SHADOW_MAP_SIZE,
      resources.SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      .D32_SFLOAT,
      enabled_passes = {.SHADOW},
    )
    if !target_ok {
      log.errorf("Failed to create shadow render target for spot light")
      return false
    }

    // Set depth texture
    for frame_idx in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
      target.attachments[.DEPTH][frame_idx] = shadow_handle
    }

    // Update camera to match spot light FOV
    camera, camera_ok := resources.get_camera(resources_manager, target.camera)
    if camera_ok {
      fov := light.angle_outer * 2.0
      camera^ = geometry.make_camera_perspective(fov, 1.0, 0.1, light.radius)
    }

    append(&self.render_targets, target)
    light.shadow_target_index = len(self.render_targets) - 1
    light.camera_index = target.camera.index

  case .DIRECTIONAL:
    // Create shadow map texture
    shadow_handle, _, ret := resources.create_empty_texture_2d(
      gpu_context,
      resources_manager,
      resources.SHADOW_MAP_SIZE,
      resources.SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    )
    if ret != .SUCCESS {
      log.errorf("Failed to create directional shadow texture")
      return false
    }
    light.shadow_map = shadow_handle.index

    // Create render target
    target, target_ok := targets.create_render_target(
      gpu_context,
      resources_manager,
      resources.SHADOW_MAP_SIZE,
      resources.SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      .D32_SFLOAT,
      enabled_passes = {.SHADOW},
    )
    if !target_ok {
      log.errorf("Failed to create shadow render target for directional light")
      return false
    }

    // Set depth texture
    for frame_idx in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
      target.attachments[.DEPTH][frame_idx] = shadow_handle
    }

    // Create orthographic camera
    camera, camera_ok := resources.get_camera(resources_manager, target.camera)
    if camera_ok {
      ortho_size: f32 = 100.0
      camera^ = geometry.make_camera_ortho(ortho_size, ortho_size, 0.1, 100.0)
    }

    append(&self.render_targets, target)
    light.shadow_target_index = len(self.render_targets) - 1
    light.camera_index = target.camera.index
  }

  // Update light data in GPU buffer
  gpu.write(
    &resources_manager.lights_buffer,
    &light.data,
    int(light_handle.index),
  )

  return true
}

// Update shadow camera transforms for a light
renderer_update_light_shadow_cameras :: proc(
  self: ^Renderer,
  resources_manager: ^resources.Manager,
  light_handle: resources.Handle,
) {
  light, ok := resources.get_light(resources_manager, light_handle)
  if !ok || !light.cast_shadow do return

  world_matrix := gpu.staged_buffer_get(
    &resources_manager.world_matrix_buffer,
    light.node_handle.index,
  )
  position := world_matrix[3].xyz

  switch light.type {
  case .POINT:
    // Point light cube face directions
    dirs := [6][3]f32 {
      {1, 0, 0}, // +X
      {-1, 0, 0}, // -X
      {0, 1, 0}, // +Y
      {0, -1, 0}, // -Y
      {0, 0, 1}, // +Z
      {0, 0, -1}, // -Z
    }
    ups := [6][3]f32 {
      {0, -1, 0},
      {0, -1, 0},
      {0, 0, 1},
      {0, 0, -1},
      {0, -1, 0},
      {0, -1, 0},
    }

    for face in 0 ..< 6 {
      target_idx := light.cube_shadow_target_index[face]
      if target_idx < 0 || target_idx >= len(self.render_targets) do continue

      render_target := &self.render_targets[target_idx]
      camera, camera_ok := resources.get_camera(
        resources_manager,
        render_target.camera,
      )
      if !camera_ok do continue

      target := position + dirs[face]
      geometry.camera_look_at(camera, position, target, ups[face])
      targets.render_target_upload_camera_data(
        resources_manager,
        render_target,
      )
    }

  case .SPOT:
    target_idx := light.shadow_target_index
    if target_idx < 0 || target_idx >= len(self.render_targets) do return

    render_target := &self.render_targets[target_idx]
    camera, camera_ok := resources.get_camera(
      resources_manager,
      render_target.camera,
    )
    if !camera_ok do return

    // Extract forward direction from world matrix
    forward := world_matrix[2].xyz
    target := position + forward
    up := [3]f32{0, 1, 0}
    if linalg.abs(linalg.dot(forward, up)) > 0.99 {
      up = {1, 0, 0}
    }

    geometry.camera_look_at(camera, position, target, up)
    targets.render_target_upload_camera_data(resources_manager, render_target)

  case .DIRECTIONAL:
    target_idx := light.shadow_target_index
    if target_idx < 0 || target_idx >= len(self.render_targets) do return

    render_target := &self.render_targets[target_idx]
    camera, camera_ok := resources.get_camera(
      resources_manager,
      render_target.camera,
    )
    if !camera_ok do return

    // Get light direction from world matrix
    light_dir := linalg.normalize(world_matrix[2].xyz)

    // Cover a fixed area around scene origin
    scene_center := [3]f32{0, 0, 0}
    scene_radius: f32 = 50.0

    // Fit orthographic camera
    if ortho, ok := &camera.projection.(geometry.OrthographicProjection); ok {
      ortho_size := scene_radius * 1.5
      ortho.width = ortho_size
      ortho.height = ortho_size
      ortho.near = 0.1
      ortho.far = scene_radius * 3.0
    }

    // Position shadow camera
    shadow_distance := scene_radius * 2.0
    cam_position := scene_center - light_dir * shadow_distance
    target := scene_center

    up := [3]f32{0, 1, 0}
    if linalg.abs(linalg.dot(light_dir, up)) > 0.99 {
      up = {1, 0, 0}
    }

    geometry.camera_look_at(camera, cam_position, target, up)
    targets.render_target_upload_camera_data(resources_manager, render_target)
  }
}

// Update all lights' shadow camera transforms
renderer_update_all_light_shadow_cameras :: proc(
  self: ^Renderer,
  resources_manager: ^resources.Manager,
) {
  for idx in 0 ..< len(resources_manager.lights.entries) {
    entry := &resources_manager.lights.entries[idx]
    if entry.generation > 0 && entry.active {
      light_handle := resources.Handle {
        index      = u32(idx),
        generation = entry.generation,
      }
      renderer_update_light_shadow_cameras(
        self,
        resources_manager,
        light_handle,
      )
    }
  }
}
