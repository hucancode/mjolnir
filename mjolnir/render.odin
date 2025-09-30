package mjolnir

import geometry_pass "render/geometry"
import navigation_renderer "render/navigation"
import "render/lighting"
import "render/particles"
import "render/post_process"
import "render/shadow"
import "render/targets"
import "render/transparency"
import "render/debug_ui"
import "core:log"
import "core:math/linalg"
import "geometry"
import "gpu"
import "resources"
import "world"
import vk "vendor:vulkan"

Renderer :: struct {
  shadow:        shadow.Renderer,
  geometry:      geometry_pass.Renderer,
  lighting:      lighting.Renderer,
  transparency:  transparency.Renderer,
  particles:     particles.Renderer,
  post_process:  post_process.Renderer,
  ui:            debug_ui.Renderer,
  navigation:    navigation_renderer.Renderer,
  targets:       targets.Manager,
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
  debug_ui.init(
    &self.ui,
    gpu_context,
    swapchain_format,
    swapchain_extent.width,
    swapchain_extent.height,
    dpi_scale,
    resources_manager,
  ) or_return
  navigation_renderer.init(&self.navigation, gpu_context, resources_manager) or_return
  targets.init(&self.targets, main_render_target)
  return .SUCCESS
}

renderer_shutdown :: proc(
  self: ^Renderer,
  device: vk.Device,
  command_pool: vk.CommandPool,
  resources_manager: ^resources.Manager,
) {
  debug_ui.shutdown(&self.ui, device)
  navigation_renderer.shutdown(&self.navigation, device, command_pool)
  post_process.shutdown(&self.post_process, device, command_pool, resources_manager)
  particles.shutdown(&self.particles, device, command_pool)
  transparency.shutdown(&self.transparency, device, command_pool)
  lighting.shutdown(&self.lighting, device, command_pool, resources_manager)
  geometry_pass.shutdown(&self.geometry, device, command_pool)
  shadow.shutdown(&self.shadow, device, command_pool)
  targets.shutdown(&self.targets)
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
  main_render_target: ^resources.RenderTarget,
) -> vk.Result {
  command_buffer := shadow.begin_record(&self.shadow, frame_index) or_return
  // Ensure world matrix staging buffer transfers complete before shadow rendering
  world_matrix_barrier := vk.BufferMemoryBarrier {
    sType = .BUFFER_MEMORY_BARRIER,
    srcAccessMask = {.TRANSFER_WRITE},
    dstAccessMask = {.SHADER_READ, .UNIFORM_READ},
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    buffer = resources_manager.world_matrix_buffer.device_buffer,
    offset = 0,
    size = vk.DeviceSize(vk.WHOLE_SIZE),
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.TRANSFER},
    {.VERTEX_SHADER},
    {},
    0, nil,
    1, &world_matrix_barrier,
    0, nil,
  )
  shadow_include := resources.NodeFlagSet{.VISIBLE, .CASTS_SHADOW}
  shadow_exclude := resources.NodeFlagSet{
    .MATERIAL_TRANSPARENT,
    .MATERIAL_WIREFRAME,
  }
  command_stride := world.draw_command_stride()
  // Get main camera frustum for culling lights outside view
  main_camera, camera_ok := resources.get_camera(resources_manager, main_render_target.camera)
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
        if !geometry.frustum_test_sphere(light_position, light.radius, &main_frustum) {
          continue
        }
      }
      visible_count += 1
      switch light.type {
      case .POINT:
        for face in 0 ..< 6 {
          if light.cube_render_targets[face].generation == 0 do continue
          found_target := resources.get_render_target(resources_manager, light.cube_render_targets[face]) or_continue
          vis_result := world.dispatch_visibility(
            world_state,
            gpu_context,
            command_buffer,
            frame_index,
            .SHADOW,
            world.VisibilityRequest {
              camera_index  = found_target.camera.index,
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
        if light.shadow_render_target.generation == 0 do continue
        found_target := resources.get_render_target(resources_manager, light.shadow_render_target) or_continue
        vis_result := world.dispatch_visibility(
          world_state,
          gpu_context,
          command_buffer,
          frame_index,
          .SHADOW,
          world.VisibilityRequest {
            camera_index  = found_target.camera.index,
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
        if light.shadow_render_target.generation == 0 do continue
        found_target := resources.get_render_target(
          resources_manager,
          light.shadow_render_target,
        ) or_continue
        vis_result := world.dispatch_visibility(
          world_state,
          gpu_context,
          command_buffer,
          frame_index,
          .SHADOW,
          world.VisibilityRequest {
            camera_index  = found_target.camera.index,
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
  main_render_target: ^resources.RenderTarget,
) -> vk.Result {
  command_buffer := geometry_pass.begin_record(
    &self.geometry,
    frame_index,
    main_render_target,
    resources_manager,
  ) or_return
  vis_result := world.dispatch_visibility(
    world_state,
    gpu_context,
    command_buffer,
    frame_index,
    .OPAQUE,
    world.VisibilityRequest {
      camera_index  = main_render_target.camera.index,
      include_flags = {.VISIBLE},
      exclude_flags = {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME},
    },
  )
  draw_buffer := vis_result.draw_buffer
  count_buffer := vis_result.count_buffer
  command_stride := vis_result.command_stride
  geometry_pass.begin_depth_prepass(
    main_render_target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  geometry_pass.render_depth_prepass(
    &self.geometry,
    command_buffer,
    main_render_target.camera.index,
    resources_manager,
    frame_index,
    draw_buffer,
    count_buffer,
    command_stride,
  )
  geometry_pass.end_depth_prepass(command_buffer)
  geometry_pass.begin_pass(
    main_render_target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  geometry_pass.render(
    &self.geometry,
    main_render_target,
    command_buffer,
    resources_manager,
    frame_index,
    draw_buffer,
    count_buffer,
    command_stride,
  )
  geometry_pass.end_pass(
    main_render_target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  geometry_pass.end_record(
    command_buffer,
    main_render_target,
    resources_manager,
    frame_index,
  ) or_return
  return .SUCCESS
}

record_lighting_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  resources_manager: ^resources.Manager,
  main_render_target: ^resources.RenderTarget,
  color_format: vk.Format,
) -> vk.Result {
  command_buffer := lighting.begin_record(&self.lighting, frame_index, color_format) or_return
  lighting.begin_ambient_pass(
    &self.lighting,
    main_render_target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  lighting.render_ambient(
    &self.lighting,
    main_render_target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  lighting.end_ambient_pass(command_buffer)
  lighting.begin_pass(
    &self.lighting,
    main_render_target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  lighting.render(
    &self.lighting,
    main_render_target,
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
  main_render_target: ^resources.RenderTarget,
  color_format: vk.Format,
) -> vk.Result {
  command_buffer := particles.begin_record(&self.particles, frame_index, color_format) or_return
  particles.begin_pass(
    &self.particles,
    command_buffer,
    main_render_target,
    resources_manager,
    frame_index,
  )
  particles.render(
    &self.particles,
    command_buffer,
    main_render_target.camera.index,
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
  main_render_target: ^resources.RenderTarget,
  color_format: vk.Format,
) -> vk.Result {
  command_buffer := transparency.begin_record(&self.transparency, frame_index, color_format) or_return
  transparency.begin_pass(
    &self.transparency,
    main_render_target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  navigation_renderer.render(
    &self.navigation,
    command_buffer,
    linalg.MATRIX4F32_IDENTITY,
    main_render_target.camera.index,
    resources_manager,
  )
  vis_transparent := world.dispatch_visibility(
    world_state,
    gpu_context,
    command_buffer,
    frame_index,
    .TRANSPARENT,
    world.VisibilityRequest {
      camera_index  = main_render_target.camera.index,
      include_flags = {.VISIBLE, .MATERIAL_TRANSPARENT},
      exclude_flags = {},
    },
  )
  command_stride := vis_transparent.command_stride
  transparency.render(
    &self.transparency,
    self.transparency.transparent_pipeline,
    main_render_target,
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
      camera_index  = main_render_target.camera.index,
      include_flags = {.VISIBLE, .MATERIAL_WIREFRAME},
      exclude_flags = {},
    },
  )
  transparency.render(
    &self.transparency,
    self.transparency.wireframe_pipeline,
    main_render_target,
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
  main_render_target: ^resources.RenderTarget,
  color_format: vk.Format,
  swapchain_extent: vk.Extent2D,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
) -> vk.Result {
  command_buffer := post_process.begin_record(
    &self.post_process,
    frame_index,
    color_format,
    main_render_target,
    resources_manager,
    swapchain_image,
  ) or_return
  post_process.begin_pass(
    &self.post_process,
    command_buffer,
    swapchain_extent,
  )
  post_process.render(
    &self.post_process,
    command_buffer,
    swapchain_extent,
    swapchain_view,
    main_render_target,
    resources_manager,
    frame_index,
  )
  post_process.end_pass(
    &self.post_process,
    command_buffer,
  )
  post_process.end_record(command_buffer) or_return
  return .SUCCESS
}
