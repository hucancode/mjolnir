package mjolnir

import "core:log"
import "core:math"
import "core:slice"
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

ShadowSlot :: struct {
  depth_texture_2d:    resources.Handle, // 2D depth texture for spot/directional
  depth_texture_cube:  resources.Handle, // Cube depth texture for point
  render_target:       targets.RenderTarget, // For spot/directional
  cube_render_targets: [6]targets.RenderTarget, // For point lights
  light_handle:        resources.Handle, // Light currently using this slot
  is_cube:             bool, // True if this is a cube shadow slot
  last_rendered_frame: u64, // Frame number when last rendered
  needs_render:        bool, // True if shadow needs to be rendered this frame
}

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
  shadow_slots:               [resources.MAX_SHADOW_MAPS]ShadowSlot,
  frame_counter:              u64,
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

  // Initialize shadow pool
  renderer_init_shadow_pool(self, gpu_context, resources_manager) or_return
  self.frame_counter = 0
  return .SUCCESS
}

renderer_init_shadow_pool :: proc(
  self: ^Renderer,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
) -> vk.Result {
  for i in 0 ..< resources.MAX_SHADOW_MAPS {
    slot := &self.shadow_slots[i]

    // Create 2D depth texture for spot/directional lights
    depth_2d, _, result := resources.create_empty_texture_2d(
      gpu_context,
      resources_manager,
      resources.SHADOW_MAP_SIZE,
      resources.SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    )
    if result != .SUCCESS {
      log.errorf("Failed to create 2D shadow map for slot %d", i)
      return result
    }
    slot.depth_texture_2d = depth_2d

    // Create cube depth texture for point lights
    depth_cube, _, result_cube := resources.create_empty_texture_cube(
      gpu_context,
      resources_manager,
      resources.SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    )
    if result_cube != .SUCCESS {
      log.errorf("Failed to create cube shadow map for slot %d", i)
      return result_cube
    }
    slot.depth_texture_cube = depth_cube

    // Create render target for 2D shadows (spot/directional)
    external_depth: [resources.MAX_FRAMES_IN_FLIGHT]resources.Handle
    for j in 0 ..< resources.MAX_FRAMES_IN_FLIGHT do external_depth[j] = depth_2d

    init_result := targets.render_target_init(
      &slot.render_target,
      gpu_context,
      resources_manager,
      resources.SHADOW_MAP_SIZE,
      resources.SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      .D32_SFLOAT,
      enabled_passes = {.SHADOW},
      external_depth_textures = external_depth,
    )
    if init_result != .SUCCESS {
      log.errorf("Failed to create render target for slot %d", i)
      return init_result
    }

    // Create 6 render targets for cube shadows (point lights)
    external_cube_depth: [resources.MAX_FRAMES_IN_FLIGHT]resources.Handle
    for j in 0 ..< resources.MAX_FRAMES_IN_FLIGHT do external_cube_depth[j] = depth_cube

    for face in 0 ..< 6 {
      init_result_cube := targets.render_target_init(
        &slot.cube_render_targets[face],
        gpu_context,
        resources_manager,
        resources.SHADOW_MAP_SIZE,
        resources.SHADOW_MAP_SIZE,
        .D32_SFLOAT,
        .D32_SFLOAT,
        enabled_passes = {.SHADOW},
        external_depth_textures = external_cube_depth,
      )
      if init_result_cube != .SUCCESS {
        log.errorf("Failed to create cube render target for slot %d face %d", i, face)
        return init_result_cube
      }

      // Set cube face camera to 90 degree FOV
      camera, camera_ok := resources.get_camera(
        resources_manager,
        slot.cube_render_targets[face].camera,
      )
      if camera_ok {
        camera^ = geometry.make_camera_perspective(math.PI * 0.5, 1.0, 0.1, 100.0)
      }
    }

    slot.light_handle = {}
    slot.is_cube = false
    slot.last_rendered_frame = 0
    slot.needs_render = false
  }

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

  // Clean up shadow pool
  for i in 0 ..< resources.MAX_SHADOW_MAPS {
    slot := &self.shadow_slots[i]

    // Destroy render targets
    targets.render_target_destroy(&slot.render_target, device, command_pool, resources_manager)
    for face in 0 ..< 6 {
      targets.render_target_destroy(&slot.cube_render_targets[face], device, command_pool, resources_manager)
    }

    // Free depth textures
    if slot.depth_texture_2d.generation > 0 {
      if item, freed := resources.free(&resources_manager.image_2d_buffers, slot.depth_texture_2d); freed {
        gpu.image_buffer_destroy(device, item)
      }
    }
    if slot.depth_texture_cube.generation > 0 {
      if item, freed := resources.free(&resources_manager.image_cube_buffers, slot.depth_texture_cube); freed {
        gpu.cube_depth_texture_destroy(device, item)
      }
    }
  }

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

LightImportance :: struct {
  importance:   f32,
  light_handle: resources.Handle,
  light_type:   resources.LightType,
}

renderer_assign_shadow_slots :: proc(
  self: ^Renderer,
  resources_manager: ^resources.Manager,
  main_camera: ^geometry.Camera,
) {
  // Calculate importance for all shadow-casting lights
  light_importances := make([dynamic]LightImportance, 0, len(resources_manager.lights.entries))
  defer delete(light_importances)
  for entry, idx in resources_manager.lights.entries do if entry.active {
    light := entry.item
    if !light.cast_shadow do continue
    // Get light position from world matrix
    world_matrix := gpu.staged_buffer_get(&resources_manager.world_matrix_buffer, light.node_handle.index)
    light_position := world_matrix[3].xyz
    // Calculate distance to main camera
    distance := max(1.0, linalg.length2(light_position - main_camera.position))
    importance: f32 = 1000000.0
    if light.type != .DIRECTIONAL {
      volume := light.radius * light.radius
      importance = volume / distance / distance
    }
    light_handle := resources.Handle{index = u32(idx), generation = entry.generation}
    append(&light_importances, LightImportance{importance, light_handle, light.type})
  }
  slice.sort_by(light_importances[:], proc(a, b: LightImportance) -> bool {
    return a.importance > b.importance
  })
  // First pass: Determine which lights keep their slots and which are evicted
  top_count := min(len(light_importances), resources.MAX_SHADOW_MAPS)
  top_lights := light_importances[:top_count]
  // Mark slots that should be retained
  slots_to_keep := [resources.MAX_SHADOW_MAPS]bool{}
  lights_needing_slots := make([dynamic]LightImportance, 0, top_count)
  defer delete(lights_needing_slots)
  importance_ranks := map[resources.Handle]int{}
  defer delete(importance_ranks)
  for light_importance, idx in light_importances {
    importance_ranks[light_importance.light_handle] = idx
  }
  for light_importance in top_lights {
    light, ok := resources.get_light(resources_manager, light_importance.light_handle)
    if !ok do continue
    // Check if this light already has a slot assigned
    if light.shadow_slot_index >= 0 && light.shadow_slot_index < resources.MAX_SHADOW_MAPS {
      // This light keeps its slot
      slots_to_keep[light.shadow_slot_index] = true
    } else {
      // This light needs a new slot
      append(&lights_needing_slots, light_importance)
    }
  }
  // shadow that are previously in the top list must drop out of top 120% in order to be evicted
  // otherwise, they stay in the current slot
  extended_limit := 0
  if len(light_importances) > 0 {
    extended_limit = (int(resources.MAX_SHADOW_MAPS) * 6 + 4) / 5 // ceil(MAX_SHADOW_MAPS * 1.2)
    if extended_limit < top_count {
      extended_limit = top_count
    }
    if extended_limit > len(light_importances) {
      extended_limit = len(light_importances)
    }
  }
  if extended_limit > top_count {
    for slot_idx in 0 ..< resources.MAX_SHADOW_MAPS {
      if slots_to_keep[slot_idx] do continue

      slot := &self.shadow_slots[slot_idx]
      if slot.light_handle.generation == 0 do continue

      if rank, found := importance_ranks[slot.light_handle]; found && rank < extended_limit {
        slots_to_keep[slot_idx] = true
      }
    }
  }

  // Evict lights that are no longer in the top list
  for slot_idx in 0 ..< resources.MAX_SHADOW_MAPS {
    if slots_to_keep[slot_idx] do continue

    slot := &self.shadow_slots[slot_idx]
    if slot.light_handle.generation > 0 {
      // Evict this light
      if old_light, ok := resources.get_light(resources_manager, slot.light_handle); ok {
        old_light.shadow_slot_index = -1
        old_light.shadow_map = 0xFFFFFFFF
        gpu.write(&resources_manager.lights_buffer, &old_light.data, int(slot.light_handle.index))
      }
      slot.light_handle = {}
      slot.needs_render = false
    }
  }

  // Second pass: Assign vacant slots to newly promoted lights
  for light_importance in lights_needing_slots {
    light, ok := resources.get_light(resources_manager, light_importance.light_handle)
    if !ok do continue

    // Find a vacant slot
    vacant_slot_idx := -1
    for slot_idx in 0 ..< resources.MAX_SHADOW_MAPS {
      if self.shadow_slots[slot_idx].light_handle.generation == 0 {
        vacant_slot_idx = slot_idx
        break
      }
    }

    if vacant_slot_idx < 0 do continue // No vacant slots

    slot := &self.shadow_slots[vacant_slot_idx]
    is_point := light.type == .POINT

    slot.is_cube = is_point
    slot.light_handle = light_importance.light_handle
    slot.needs_render = true // New assignment always needs render
    light.shadow_slot_index = vacant_slot_idx

    // Set shadow map index and camera index
    if is_point {
      light.shadow_map = slot.depth_texture_cube.index
      light.camera_index = slot.cube_render_targets[0].camera.index
    } else {
      light.shadow_map = slot.depth_texture_2d.index
      light.camera_index = slot.render_target.camera.index
    }

    gpu.write(&resources_manager.lights_buffer, &light.data, int(light_importance.light_handle.index))
  }

  // Update needs_render flag for lights that kept their slots
  for slot_idx in 0 ..< resources.MAX_SHADOW_MAPS {
    if !slots_to_keep[slot_idx] do continue

    slot := &self.shadow_slots[slot_idx]
    if slot.light_handle.generation == 0 do continue

    light, ok := resources.get_light(resources_manager, slot.light_handle)
    if !ok do continue

    // Only re-render if light has moved
    slot.needs_render = light.has_moved
  }
  for entry, idx in resources_manager.lights.entries do if entry.active {
    light := entry.item
    if light.cast_shadow && light.shadow_slot_index == -1 {
      light.shadow_map = 0xFFFFFFFF
      gpu.write(&resources_manager.lights_buffer, &light.data, int(idx))
    }
  }
}

renderer_check_light_movement :: proc(
  self: ^Renderer,
  resources_manager: ^resources.Manager,
) {
  for entry, idx in resources_manager.lights.entries do if entry.active {
    light := entry.item
    if !light.cast_shadow do continue
    world_matrix := gpu.staged_buffer_get(&resources_manager.world_matrix_buffer, light.node_handle.index)
    // Check if matrix changed (simple element-wise comparison)
    has_moved := false
    for i in 0 ..< 4 {
      for j in 0 ..< 4 {
        if linalg.abs(world_matrix[i][j] - light.last_world_matrix[i][j]) > 0.001 {
          has_moved = true
          break
        }
      }
      if has_moved do break
    }

    light.has_moved = has_moved
    if has_moved {
      light.last_world_matrix = world_matrix^
    }
  }
}

record_shadow_pass :: proc(
  self: ^Renderer,
  frame_index: u32,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  world_state: ^world.World,
  target: ^targets.RenderTarget,
) -> vk.Result {
  main_camera, camera_ok := resources.get_camera(resources_manager, target.camera)
  if !camera_ok {
    log.errorf("Main camera not found")
    return .ERROR_UNKNOWN
  }

  // Check which lights have moved
  renderer_check_light_movement(self, resources_manager)

  // Assign shadow slots based on importance
  renderer_assign_shadow_slots(self, resources_manager, main_camera)

  command_buffer := shadow.begin_record(&self.shadow, frame_index) or_return

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
  shadow_exclude := resources.NodeFlagSet{.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME}
  command_stride := world.draw_command_stride()

  // Render shadows for assigned slots
  rendered_count := 0
  for slot_idx in 0 ..< resources.MAX_SHADOW_MAPS {
    slot := &self.shadow_slots[slot_idx]
    if slot.light_handle.generation == 0 do continue

    light, ok := resources.get_light(resources_manager, slot.light_handle)
    if !ok do continue

    // Skip rendering if shadow doesn't need update
    if !slot.needs_render do continue

    // Update shadow cameras
    renderer_update_shadow_camera_for_light(self, resources_manager, slot, light)

    rendered_count += 1
    slot.last_rendered_frame = self.frame_counter

    switch light.type {
    case .POINT:
      for face in 0 ..< 6 {
        render_target := &slot.cube_render_targets[face]
        vis_result := world.dispatch_visibility(
          world_state,
          gpu_context,
          command_buffer,
          frame_index,
          .SHADOW,
          world.VisibilityRequest {
            camera_index = render_target.camera.index,
            include_flags = shadow_include,
            exclude_flags = shadow_exclude,
          },
        )
        shadow.begin_pass(render_target, command_buffer, resources_manager, frame_index, u32(face))
        shadow.render(
          &self.shadow,
          render_target^,
          command_buffer,
          resources_manager,
          frame_index,
          vis_result.draw_buffer,
          vis_result.count_buffer,
          command_stride,
        )
        shadow.end_pass(command_buffer, render_target, resources_manager, frame_index, u32(face))
      }

    case .SPOT, .DIRECTIONAL:
      render_target := &slot.render_target
      vis_result := world.dispatch_visibility(
        world_state,
        gpu_context,
        command_buffer,
        frame_index,
        .SHADOW,
        world.VisibilityRequest {
          camera_index = render_target.camera.index,
          include_flags = shadow_include,
          exclude_flags = shadow_exclude,
        },
      )
      shadow.begin_pass(render_target, command_buffer, resources_manager, frame_index)
      shadow.render(
        &self.shadow,
        render_target^,
        command_buffer,
        resources_manager,
        frame_index,
        vis_result.draw_buffer,
        vis_result.count_buffer,
        command_stride,
      )
      shadow.end_pass(command_buffer, render_target, resources_manager, frame_index)
    }
  }

  shadow.end_record(command_buffer) or_return
  self.frame_counter += 1
  return .SUCCESS
}

renderer_update_shadow_camera_for_light :: proc(
  self: ^Renderer,
  resources_manager: ^resources.Manager,
  slot: ^ShadowSlot,
  light: ^resources.Light,
) {
  world_matrix := gpu.staged_buffer_get(&resources_manager.world_matrix_buffer, light.node_handle.index)
  position := world_matrix[3].xyz

  switch light.type {
  case .POINT:
    dirs := [6][3]f32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
    ups := [6][3]f32{{0, -1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}, {0, -1, 0}, {0, -1, 0}}

    for face in 0 ..< 6 {
      render_target := &slot.cube_render_targets[face]
      camera, camera_ok := resources.get_camera(resources_manager, render_target.camera)
      if !camera_ok do continue

      // Update camera far plane to match light radius
      if perspective, ok := &camera.projection.(geometry.PerspectiveProjection); ok {
        perspective.far = light.radius
      }

      target := position + dirs[face]
      geometry.camera_look_at(camera, position, target, ups[face])
      targets.render_target_upload_camera_data(resources_manager, render_target)
    }

  case .SPOT:
    render_target := &slot.render_target
    camera, camera_ok := resources.get_camera(resources_manager, render_target.camera)
    if !camera_ok do return

    // Update camera to match spot light parameters
    if perspective, ok := &camera.projection.(geometry.PerspectiveProjection); ok {
      perspective.fov = light.angle_outer * 2.0
      perspective.far = light.radius
    }

    forward := world_matrix[2].xyz
    target := position + forward
    up := [3]f32{0, 1, 0}
    if linalg.abs(linalg.dot(forward, up)) > 0.99 {
      up = {1, 0, 0}
    }

    geometry.camera_look_at(camera, position, target, up)
    targets.render_target_upload_camera_data(resources_manager, render_target)

  case .DIRECTIONAL:
    render_target := &slot.render_target
    camera, camera_ok := resources.get_camera(resources_manager, render_target.camera)
    if !camera_ok do return

    light_dir := linalg.normalize(world_matrix[2].xyz)
    scene_center := [3]f32{0, 0, 0}
    scene_radius: f32 = 50.0

    if ortho, ok := &camera.projection.(geometry.OrthographicProjection); ok {
      ortho_size := scene_radius * 1.5
      ortho.width = ortho_size
      ortho.height = ortho_size
      ortho.near = 0.1
      ortho.far = scene_radius * 3.0
    }

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
  visibility_request := world.VisibilityRequest {
    camera_index = target.camera.index,
    include_flags = {.VISIBLE},
    exclude_flags = {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME},
  }

  early_visibility := world.dispatch_visibility_with_occlusion(
    world_state,
    gpu_context,
    resources_manager,
    command_buffer,
    frame_index,
    .OPAQUE,
    visibility_request,
    &world_state.depth_pyramid,
    true,
  )

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
    early_visibility.draw_buffer,
    early_visibility.count_buffer,
    early_visibility.command_stride,
  )
  geometry_pass.end_depth_prepass(command_buffer)

  depth_handle := targets.get_depth_texture(target, frame_index)
  depth_texture := resources.get(
    resources_manager.image_2d_buffers,
    depth_handle,
  )
  if depth_texture == nil {
    return .ERROR_UNKNOWN
  }

  depth_to_sample := vk.ImageMemoryBarrier {
    sType               = .IMAGE_MEMORY_BARRIER,
    srcAccessMask       = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    dstAccessMask       = {.SHADER_READ},
    oldLayout           = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    newLayout           = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
    image               = depth_texture.image,
    subresourceRange    = {
      aspectMask     = {.DEPTH},
      baseMipLevel   = 0,
      levelCount     = 1,
      baseArrayLayer = 0,
      layerCount     = 1,
    },
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
    {.COMPUTE_SHADER},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &depth_to_sample,
  )

  world.ensure_depth_pyramid(
    world_state,
    gpu_context,
    target.extent.width,
    target.extent.height,
  ) or_return

  world.generate_depth_pyramid(
    world_state,
    gpu_context,
    command_buffer,
    depth_texture.view,
    target.extent.width,
    target.extent.height,
  )

  depth_to_attachment := vk.ImageMemoryBarrier {
    sType               = .IMAGE_MEMORY_BARRIER,
    srcAccessMask       = {.SHADER_READ},
    dstAccessMask       = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    oldLayout           = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
    newLayout           = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    image               = depth_texture.image,
    subresourceRange    = {
      aspectMask     = {.DEPTH},
      baseMipLevel   = 0,
      levelCount     = 1,
      baseArrayLayer = 0,
      layerCount     = 1,
    },
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &depth_to_attachment,
  )

  vis_result := world.dispatch_visibility_with_occlusion(
    world_state,
    gpu_context,
    resources_manager,
    command_buffer,
    frame_index,
    .OPAQUE,
    visibility_request,
    &world_state.depth_pyramid,
    false,
  )
  draw_buffer := vis_result.draw_buffer
  count_buffer := vis_result.count_buffer
  command_stride := vis_result.command_stride
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
