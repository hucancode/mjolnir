package mjolnir

import geometry_pass "render/geometry"
import lighting "render/lighting"
import particles "render/particles"
import post_process "render/post_process"
import shadow "render/shadow"
import targets "render/targets"
import transparency "render/transparency"
import debug_ui "render/debug_ui"
import "core:log"
import "core:math/linalg"
import "geometry"
import "gpu"
import "resources"
import vk "vendor:vulkan"

Renderer :: struct {
  shadow:        shadow.Renderer,
  geometry:      geometry_pass.Renderer,
  ambient:       lighting.RendererAmbient,
  lighting:      lighting.RendererLighting,
  transparency:  transparency.Renderer,
  particles:     particles.RendererParticle,
  post_process:  post_process.RendererPostProcess,
  ui:            debug_ui.RendererUI,
  targets:       targets.Manager,

  shadow_commands:        [resources.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  geometry_commands:      [resources.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  lighting_commands:      [resources.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  transparency_commands:  [resources.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  post_process_commands:  [resources.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
}

@(private = "file")
allocate_secondary_buffers :: proc(
  gpu_context: ^gpu.GPUContext,
  buffers: []vk.CommandBuffer,
) -> vk.Result {
  vk.AllocateCommandBuffers(
    gpu_context.device,
    &vk.CommandBufferAllocateInfo{
      sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool        = gpu_context.command_pool,
      level              = .SECONDARY,
      commandBufferCount = u32(len(buffers)),
    },
    raw_data(buffers),
  ) or_return
  return .SUCCESS
}

@(private = "file")
free_secondary_buffers :: proc(
  device: vk.Device,
  pool: vk.CommandPool,
  buffers: []vk.CommandBuffer,
) {
  if len(buffers) == 0 do return
  vk.FreeCommandBuffers(device, pool, u32(len(buffers)), raw_data(buffers))
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
  allocate_secondary_buffers(
    gpu_context,
    self.shadow_commands[:],
  ) or_return
  allocate_secondary_buffers(
    gpu_context,
    self.geometry_commands[:],
  ) or_return
  allocate_secondary_buffers(
    gpu_context,
    self.lighting_commands[:],
  ) or_return
  allocate_secondary_buffers(
    gpu_context,
    self.transparency_commands[:],
  ) or_return
  allocate_secondary_buffers(
    gpu_context,
    self.post_process_commands[:],
  ) or_return

  lighting.lighting_init(
    &self.lighting,
    gpu_context,
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
    vk.Format.D32_SFLOAT,
    resources_manager,
  ) or_return
  lighting.ambient_init(
    &self.ambient,
    gpu_context,
    resources_manager,
    swapchain_extent.width,
    swapchain_extent.height,
    swapchain_format,
  ) or_return
  geometry_pass.init(
    &self.geometry,
    gpu_context,
    swapchain_extent.width,
    swapchain_extent.height,
    resources_manager,
  ) or_return
  geometry_pass.init_depth_prepass(
    &self.geometry,
    gpu_context,
    swapchain_extent,
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
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
) {
  debug_ui.shutdown(&self.ui, gpu_context)
  post_process.shutdown(&self.post_process, gpu_context, resources_manager)
  particles.shutdown(&self.particles, gpu_context)
  transparency.shutdown(&self.transparency, gpu_context)
  lighting.lighting_shutdown(&self.lighting, gpu_context)
  lighting.ambient_shutdown(&self.ambient, gpu_context, resources_manager)
  geometry_pass.shutdown(&self.geometry, gpu_context)
  shadow.shutdown(&self.shadow, gpu_context)
  targets.shutdown(&self.targets)

  free_secondary_buffers(
    gpu_context.device,
    gpu_context.command_pool,
    self.shadow_commands[:],
  )
  free_secondary_buffers(
    gpu_context.device,
    gpu_context.command_pool,
    self.geometry_commands[:],
  )
  free_secondary_buffers(
    gpu_context.device,
    gpu_context.command_pool,
    self.lighting_commands[:],
  )
  free_secondary_buffers(
    gpu_context.device,
    gpu_context.command_pool,
    self.transparency_commands[:],
  )
  free_secondary_buffers(
    gpu_context.device,
    gpu_context.command_pool,
    self.post_process_commands[:],
  )
}

renderer_set_main_target :: proc(
  self: ^Renderer,
  handle: resources.Handle,
) {
  self.targets.main = handle
}

renderer_prepare_targets :: proc(
  self: ^Renderer,
  resources_manager: ^resources.Manager,
  lights: []lighting.LightInfo,
  active_light_count: u32,
) {
  targets.begin_frame(&self.targets)
  if self.targets.main.generation != 0 {
    targets.track(&self.targets, self.targets.main)
  }

  for light in lights[:active_light_count] {
    if !light.light_cast_shadow do continue
    switch light.light_kind {
    case .POINT:
      for target_handle in light.cube_render_targets {
        resources.get_render_target(resources_manager, target_handle) or_continue
        targets.track(&self.targets, target_handle)
      }
    case .SPOT:
      resources.get_render_target(resources_manager, light.render_target) or_continue
      targets.track(&self.targets, light.render_target)
    case .DIRECTIONAL:
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
  visibility_culler: ^VisibilityCuller,
  lights: []lighting.LightInfo,
  active_light_count: u32,
) -> vk.Result {
  command_buffer := self.shadow_commands[frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  rendering_info := vk.CommandBufferInheritanceRenderingInfo{
    sType = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    depthAttachmentFormat = .D32_SFLOAT,
  }
  inheritance := vk.CommandBufferInheritanceInfo {
    sType = .COMMAND_BUFFER_INHERITANCE_INFO,
    pNext = &rendering_info,
  }
  vk.BeginCommandBuffer(
    command_buffer,
    &vk.CommandBufferBeginInfo{
      sType = .COMMAND_BUFFER_BEGIN_INFO,
      flags = {.ONE_TIME_SUBMIT},
      pInheritanceInfo = &inheritance,
    },
  ) or_return

  shadow_include := resources.NodeFlagSet{.VISIBLE, .CASTS_SHADOW}
  shadow_exclude := resources.NodeFlagSet{
    .MATERIAL_TRANSPARENT,
    .MATERIAL_WIREFRAME,
  }
  command_stride := visibility_culler_command_stride()

  for &light_info, light_index in lights[:active_light_count] {
    if !light_info.light_cast_shadow do continue

    switch light_info.light_kind {
    case .POINT:
      if light_info.shadow_map.generation == 0 {
        log.errorf("Point light %d has invalid shadow map handle", light_index)
        continue
      }
      for face in 0 ..< 6 {
        target := resources.get(
          resources_manager.render_targets,
          light_info.cube_render_targets[face],
        )
        if target == nil do continue
        visibility_culler_dispatch(
          visibility_culler,
          gpu_context,
          command_buffer,
          frame_index,
          light_info.cube_cameras[face].index,
          shadow_include,
          shadow_exclude,
        )
        shadow_draw_buffer := visibility_culler_command_buffer(
          visibility_culler,
          frame_index,
        )
        shadow_draw_count := visibility_culler_max_draw_count(visibility_culler)
        shadow.begin_pass(
          target,
          command_buffer,
          resources_manager,
          frame_index,
          u32(face),
        )
        shadow.render(
          &self.shadow,
          target^,
          command_buffer,
          resources_manager,
          frame_index,
          shadow_draw_buffer,
          shadow_draw_count,
          command_stride,
        )
        shadow.end_pass(
          command_buffer,
          target,
          resources_manager,
          frame_index,
          u32(face),
        )
      }

    case .SPOT:
      if light_info.shadow_map.generation == 0 {
        log.errorf("Spot light %d has invalid shadow map handle", light_index)
        continue
      }
      shadow_target := resources.get(
        resources_manager.render_targets,
        light_info.render_target,
      )
      if shadow_target == nil do continue

      visibility_culler_dispatch(
        visibility_culler,
        gpu_context,
        command_buffer,
        frame_index,
        light_info.camera.index,
        shadow_include,
        shadow_exclude,
      )
      shadow_draw_buffer := visibility_culler_command_buffer(
        visibility_culler,
        frame_index,
      )
      shadow_draw_count := visibility_culler_max_draw_count(
        visibility_culler,
      )
      shadow.begin_pass(
        shadow_target,
        command_buffer,
        resources_manager,
        frame_index,
      )
      shadow.render(
        &self.shadow,
        shadow_target^,
        command_buffer,
        resources_manager,
        frame_index,
        shadow_draw_buffer,
        shadow_draw_count,
        command_stride,
      )
      shadow.end_pass(
        command_buffer,
        shadow_target,
        resources_manager,
        frame_index,
      )

    case .DIRECTIONAL:
      // Directional shadow rendering not yet implemented
    }
  }

  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}

record_geometry_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  visibility_culler: ^VisibilityCuller,
  main_render_target: ^resources.RenderTarget,
) -> vk.Result {
  command_buffer := self.geometry_commands[frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  color_formats := [?]vk.Format {
    .R32G32B32A32_SFLOAT,
    .R8G8B8A8_UNORM,
    .R8G8B8A8_UNORM,
    .R8G8B8A8_UNORM,
    .R8G8B8A8_UNORM,
  }
  rendering_info := vk.CommandBufferInheritanceRenderingInfo{
    sType = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    colorAttachmentCount = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
    depthAttachmentFormat = .D32_SFLOAT,
  }
  inheritance := vk.CommandBufferInheritanceInfo {
    sType = .COMMAND_BUFFER_INHERITANCE_INFO,
    pNext = &rendering_info,
  }
  vk.BeginCommandBuffer(
    command_buffer,
    &vk.CommandBufferBeginInfo{
      sType = .COMMAND_BUFFER_BEGIN_INFO,
      flags = {.ONE_TIME_SUBMIT},
      pInheritanceInfo = &inheritance,
    },
  ) or_return

  depth_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_depth_texture(main_render_target, frame_index),
  )
  if depth_texture != nil {
    gpu.transition_image(
      command_buffer,
      depth_texture.image,
      .UNDEFINED,
      .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
      {.DEPTH},
      {.TOP_OF_PIPE},
      {.EARLY_FRAGMENT_TESTS},
      {},
      {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    )
  }

  visibility_culler_dispatch(
    visibility_culler,
    gpu_context,
    command_buffer,
    frame_index,
    main_render_target.camera.index,
    {.VISIBLE},
    {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME},
  )
  draw_buffer := visibility_culler_command_buffer(
    visibility_culler,
    frame_index,
  )
  draw_count := visibility_culler_max_draw_count(visibility_culler)
  command_stride := visibility_culler_command_stride()

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

  if depth_texture != nil {
    gpu.transition_image(
      command_buffer,
      depth_texture.image,
      .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
      .SHADER_READ_ONLY_OPTIMAL,
      {.DEPTH},
      {.LATE_FRAGMENT_TESTS},
      {.FRAGMENT_SHADER},
      {.SHADER_READ},
    )
  }

  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}

record_lighting_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  resources_manager: ^resources.Manager,
  main_render_target: ^resources.RenderTarget,
  lights: []lighting.LightInfo,
  active_light_count: u32,
  color_format: vk.Format,
) -> vk.Result {
  command_buffer := self.lighting_commands[frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  color_formats := [1]vk.Format{color_format}
  rendering_info := vk.CommandBufferInheritanceRenderingInfo{
    sType = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    colorAttachmentCount = 1,
    pColorAttachmentFormats = &color_formats[0],
    depthAttachmentFormat = .D32_SFLOAT,
  }
  inheritance := vk.CommandBufferInheritanceInfo {
    sType = .COMMAND_BUFFER_INHERITANCE_INFO,
    pNext = &rendering_info,
  }
  vk.BeginCommandBuffer(
    command_buffer,
    &vk.CommandBufferBeginInfo{
      sType = .COMMAND_BUFFER_BEGIN_INFO,
      flags = {.ONE_TIME_SUBMIT},
      pInheritanceInfo = &inheritance,
    },
  ) or_return

  lighting.ambient_begin_pass(
    &self.ambient,
    main_render_target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  lighting.ambient_render(
    &self.ambient,
    main_render_target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  lighting.ambient_end_pass(command_buffer)

  lighting.lighting_begin_pass(
    &self.lighting,
    main_render_target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  lighting.lighting_render(
    &self.lighting,
    lights[:active_light_count],
    main_render_target,
    command_buffer,
    resources_manager,
    frame_index,
  )
  lighting.lighting_end_pass(command_buffer)

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

  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}

record_transparency_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  visibility_culler: ^VisibilityCuller,
  main_render_target: ^resources.RenderTarget,
  navmesh_renderer: ^RendererNavMesh,
  color_format: vk.Format,
) -> vk.Result {
  command_buffer := self.transparency_commands[frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  color_formats := [1]vk.Format{color_format}
  rendering_info := vk.CommandBufferInheritanceRenderingInfo{
    sType = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    colorAttachmentCount = 1,
    pColorAttachmentFormats = &color_formats[0],
    depthAttachmentFormat = .D32_SFLOAT,
  }
  inheritance := vk.CommandBufferInheritanceInfo {
    sType = .COMMAND_BUFFER_INHERITANCE_INFO,
    pNext = &rendering_info,
  }
  vk.BeginCommandBuffer(
    command_buffer,
    &vk.CommandBufferBeginInfo{
      sType = .COMMAND_BUFFER_BEGIN_INFO,
      flags = {.ONE_TIME_SUBMIT},
      pInheritanceInfo = &inheritance,
    },
  ) or_return

  transparency.begin_pass(
    &self.transparency,
    main_render_target,
    command_buffer,
    resources_manager,
    frame_index,
  )

  navmesh_render(
    navmesh_renderer,
    command_buffer,
    linalg.MATRIX4F32_IDENTITY,
    main_render_target.camera.index,
  )

  visibility_culler_dispatch(
    visibility_culler,
    gpu_context,
    command_buffer,
    frame_index,
    main_render_target.camera.index,
    {.VISIBLE, .MATERIAL_TRANSPARENT},
  )

  draw_buffer := visibility_culler_command_buffer(
    visibility_culler,
    frame_index,
  )
  draw_count := visibility_culler_max_draw_count(visibility_culler)
  command_stride := visibility_culler_command_stride()
  transparency.render(
    &self.transparency,
    self.transparency.transparent_pipeline,
    main_render_target,
    command_buffer,
    resources_manager,
    frame_index,
    draw_buffer,
    draw_count,
    command_stride,
  )

  visibility_culler_dispatch(
    visibility_culler,
    gpu_context,
    command_buffer,
    frame_index,
    main_render_target.camera.index,
    {.VISIBLE, .MATERIAL_WIREFRAME},
  )
  wireframe_draw_buffer := visibility_culler_command_buffer(
    visibility_culler,
    frame_index,
  )
  wireframe_draw_count := visibility_culler_max_draw_count(visibility_culler)
  transparency.render(
    &self.transparency,
    self.transparency.wireframe_pipeline,
    main_render_target,
    command_buffer,
    resources_manager,
    frame_index,
    wireframe_draw_buffer,
    wireframe_draw_count,
    command_stride,
  )
  transparency.end_pass(&self.transparency, command_buffer)

  vk.EndCommandBuffer(command_buffer) or_return
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
  command_buffer := self.post_process_commands[frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  color_formats := [1]vk.Format{color_format}
  rendering_info := vk.CommandBufferInheritanceRenderingInfo{
    sType = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    colorAttachmentCount = 1,
    pColorAttachmentFormats = &color_formats[0],
  }
  inheritance := vk.CommandBufferInheritanceInfo {
    sType = .COMMAND_BUFFER_INHERITANCE_INFO,
    pNext = &rendering_info,
  }
  vk.BeginCommandBuffer(
    command_buffer,
    &vk.CommandBufferBeginInfo{
      sType = .COMMAND_BUFFER_BEGIN_INFO,
      flags = {.ONE_TIME_SUBMIT},
      pInheritanceInfo = &inheritance,
    },
  ) or_return

  final_image := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_final_image(main_render_target, frame_index),
  )
  if final_image != nil {
    gpu.transition_image_to_shader_read(command_buffer, final_image.image)
  }

  post_process.begin_pass(
    &self.post_process,
    command_buffer,
    swapchain_extent,
  )
  gpu.transition_image(
    command_buffer,
    swapchain_image,
    .UNDEFINED,
    .COLOR_ATTACHMENT_OPTIMAL,
    {.COLOR},
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {},
    {.COLOR_ATTACHMENT_WRITE},
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

  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}

simulate_particles :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  camera: geometry.Camera,
  world_matrix_set: vk.DescriptorSet,
) {
  particles.simulate(
    &self.particles,
    command_buffer,
    camera,
    world_matrix_set,
  )
}
