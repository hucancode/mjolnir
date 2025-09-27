package mjolnir

import geometry_pass "render/geometry"
import "render/lighting"
import navigation_renderer "render/navigation"
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
import world "world"
import vk "vendor:vulkan"

Renderer :: struct {
  shadow:        shadow.Renderer,
  geometry:      geometry_pass.Renderer,
  lighting:      lighting.Renderer,
  transparency:  transparency.Renderer,
  particles:     particles.Renderer,
  post_process:  post_process.Renderer,
  ui:            debug_ui.Renderer,
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
  post_process.shutdown(&self.post_process, device, command_pool, resources_manager)
  particles.shutdown(&self.particles, device, command_pool)
  transparency.shutdown(&self.transparency, device, command_pool)
  lighting.shutdown(&self.lighting, device, command_pool, resources_manager)
  geometry_pass.shutdown(&self.geometry, device, command_pool)
  shadow.shutdown(&self.shadow, device, command_pool)
  targets.shutdown(&self.targets)
}

renderer_prepare_targets :: proc(
  self: ^Renderer,
  resources_manager: ^resources.Manager,
) {
  targets.begin_frame(&self.targets)
  if self.targets.main.generation != 0 {
    targets.track(&self.targets, self.targets.main)
  }

  for &entry in resources_manager.lights.entries {
    if !entry.active {
      continue
    }
    light := &entry.item
    if !light.cast_shadow || !light.enabled {
      continue
    }
    switch light.kind {
    case resources.LightKind.POINT:
      for target_handle in light.shadow.cube_render_targets {
        if target_handle.generation == 0 do continue
        resources.get_render_target(resources_manager, target_handle) or_continue
        targets.track(&self.targets, target_handle)
      }
    case resources.LightKind.SPOT:
      if light.shadow.render_target.generation == 0 do continue
      resources.get_render_target(resources_manager, light.shadow.render_target) or_continue
      targets.track(&self.targets, light.shadow.render_target)
    case resources.LightKind.DIRECTIONAL:
      // Directional shadows not yet implemented
    }
  }
  for &entry, idx in resources_manager.render_targets.entries do if entry.active {
    handle := resources.Handle{index = u32(idx), generation = entry.generation}
    if self.targets.main.generation != 0 && handle.index == self.targets.main.index do continue
    if targets.contains(&self.targets, handle) do continue
    targets.track(&self.targets, handle)
  }
}

render_subsystem_resize :: proc(
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
) -> vk.Result {
  command_buffer := shadow.begin_record(&self.shadow, frame_index) or_return
  shadow_include := resources.NodeFlagSet{.VISIBLE, .CASTS_SHADOW}
  shadow_exclude := resources.NodeFlagSet{
    .MATERIAL_TRANSPARENT,
    .MATERIAL_WIREFRAME,
  }
  command_stride := world.visibility_command_stride()
  for &entry, light_index in resources_manager.lights.entries {
    if !entry.active {
      continue
    }
    light := &entry.item
    if !light.cast_shadow || !light.enabled {
      continue
    }
    switch light.kind {
    case resources.LightKind.POINT:
      if light.shadow.shadow_map.generation == 0 {
        log.errorf("Point light %d has invalid shadow map handle", light_index)
        continue
      }
      for face in 0 ..< 6 {
        if light.shadow.cube_cameras[face].generation == 0 do continue
        target := resources.get(
          resources_manager.render_targets,
          light.shadow.cube_render_targets[face],
        )
        if target == nil do continue
        vis_result := world.dispatch_visibility(
          world_state,
          gpu_context,
          command_buffer,
          frame_index,
          world.VisibilityCategory.SHADOW,
          world.VisibilityRequest {
            camera_index  = light.shadow.cube_cameras[face].index,
            include_flags = shadow_include,
            exclude_flags = shadow_exclude,
          },
        )
        if vis_result.draw_buffer == 0 || vis_result.max_draws == 0 do continue
        shadow.begin_pass(target, command_buffer, resources_manager, frame_index, u32(face))
        shadow.render(
          &self.shadow,
          target^,
          command_buffer,
          resources_manager,
          frame_index,
          vis_result.draw_buffer,
          vis_result.max_draws,
          command_stride,
        )
        shadow.end_pass(command_buffer, target, resources_manager, frame_index, u32(face))
      }

    case resources.LightKind.SPOT:
      if light.shadow.camera.generation == 0 {
        log.errorf("Spot light %d has invalid camera handle", light_index)
        continue
      }
      target := resources.get(
        resources_manager.render_targets,
        light.shadow.render_target,
      )
      if target == nil {
        log.errorf("Spot light %d has invalid render target", light_index)
        continue
      }
      vis_result := world.dispatch_visibility(
        world_state,
        gpu_context,
        command_buffer,
        frame_index,
        world.VisibilityCategory.SHADOW,
        world.VisibilityRequest {
          camera_index  = light.shadow.camera.index,
          include_flags = shadow_include,
          exclude_flags = shadow_exclude,
        },
      )
      if vis_result.draw_buffer == 0 || vis_result.max_draws == 0 do continue
      shadow.begin_pass(target, command_buffer, resources_manager, frame_index)
      shadow.render(
        &self.shadow,
        target^,
        command_buffer,
        resources_manager,
        frame_index,
        vis_result.draw_buffer,
        vis_result.max_draws,
        command_stride,
      )
      shadow.end_pass(command_buffer, target, resources_manager, frame_index)

    case resources.LightKind.DIRECTIONAL:
      // Directional shadow rendering not yet implemented
    }
  }
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
    world.VisibilityCategory.OPAQUE,
    world.VisibilityRequest {
      camera_index  = main_render_target.camera.index,
      include_flags = {.VISIBLE},
      exclude_flags = {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME},
    },
  )
  draw_buffer := vis_result.draw_buffer
  draw_count := vis_result.max_draws
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
    draw_count,
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
    draw_count,
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
    command_buffer,
    resources_manager,
    main_render_target,
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
  navmesh_renderer: ^navigation_renderer.Renderer,
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
    navmesh_renderer,
    command_buffer,
    linalg.MATRIX4F32_IDENTITY,
    main_render_target.camera.index,
  )
  vis_transparent := world.dispatch_visibility(
    world_state,
    gpu_context,
    command_buffer,
    frame_index,
    world.VisibilityCategory.TRANSPARENT,
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
    vis_transparent.max_draws,
    command_stride,
  )
  vis_wireframe := world.dispatch_visibility(
    world_state,
    gpu_context,
    command_buffer,
    frame_index,
    world.VisibilityCategory.WIREFRAME,
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
    vis_wireframe.max_draws,
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
