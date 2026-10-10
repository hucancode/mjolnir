package render

import "bindless"
import cont "../containers"
import geom "../geometry"
import "gpu"
import "ambient"
import "debug_line"
import depth_pyramid_system "depth_pyramid"
import "direct_light"
import "forward"
import "geometry"
import "occlusion_culling"
import particles_compute "particles_compute"
import particles_render "particles_render"
import "post_process"
import "shadow"
import ui_render "ui"
import vk "vendor:vulkan"

@(private)
record_compute_commands :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  cull_camera_indices: []u32,
) -> vk.Result {
  cmd :=
    gctx.has_async_compute ? self.internal.compute_command_buffers[frame_index] : self.internal.command_buffers[frame_index]
  // Compute for frame N prepares data for frame N+1
  // Buffer indices with FRAMES_IN_FLIGHT=2: frame N uses buffer [N], produces data for buffer [N+1]
  next_frame_index := frame_next(frame_index)
  for cam_index in cull_camera_indices {
    cam := &self.cameras.entries[cam_index].item
    depth_pyramid_system.build_pyramid(
      &self.internal.depth_pyramid,
      cmd,
      self.node_count,
      &cam.depth_pyramid[frame_index],
      cam.depth_reduce_descriptor_sets[frame_index][:],
    ) // Build pyramid[N]
    prev_frame := frame_prev(next_frame_index)
    occlusion_culling.perform_culling(
      &self.internal.visibility,
      cmd,
      cam_index,
      next_frame_index,
      self.node_count,
      &cam.draws,
      cam.descriptor_set[next_frame_index],
      cam.depth_pyramid[prev_frame].width,
      cam.depth_pyramid[prev_frame].height,
    ) // Write draw_list[N+1]
  }
  particles_compute.simulate(
    &self.internal.particles_compute,
    cmd,
    self.internal.node_data_buffer.descriptor_set,
  )
  return .SUCCESS
}

@(private)
render_shadow_depth :: proc(
  self: ^Manager,
  frame_index: u32,
  cache: map[u32]shadow.ShadowFrameInfo,
) -> vk.Result {
  cmd := self.internal.command_buffers[frame_index]
  scene := scene_bindings(self, frame_index)
  light_node_indices := sorted_light_indices(self)
  for light_node_index in light_node_indices {
    light := self.internal.lights[light_node_index]
    info := cache[light_node_index]
    switch variant in light {
    case SpotLight, DirectionalLight:
      sm, has_shadow := &self.internal.shadow_maps[light_node_index]
      if !has_shadow do continue
      shadow.cull(
        &self.internal.shadow,
        cmd,
        self.node_count,
        geom.make_frustum(info.view_projection).planes,
        sm.draw_count[frame_index].buffer,
        sm.descriptor_sets[frame_index],
      )
      shadow.record_frustum(
        &self.internal.shadow,
        cmd,
        &self.texture_manager,
        scene,
        info.view_projection,
        sm.shadow_map_2d[frame_index],
        sm.draw_commands[frame_index],
        sm.draw_count[frame_index],
      )
    case PointLight:
      sm, has_shadow := &self.internal.shadow_map_cubes[light_node_index]
      if !has_shadow do continue
      shadow.cull(
        &self.internal.shadow,
        cmd,
        self.node_count,
        shadow.Sphere{variant.position, variant.radius},
        sm.draw_count[frame_index].buffer,
        sm.descriptor_sets[frame_index],
      )
      shadow.record_sphere(
        &self.internal.shadow,
        cmd,
        &self.texture_manager,
        scene,
        info.projection,
        info.near,
        info.far,
        variant.position,
        sm.shadow_map_cube[frame_index],
        sm.draw_commands[frame_index],
        sm.draw_count[frame_index],
      )
    }
  }
  return .SUCCESS
}

@(private)
record_geometry_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam_index: u32,
  cam: ^Camera,
  enabled_passes: PassTypeSet,
) -> vk.Result {
  if .GEOMETRY not_in enabled_passes do return .SUCCESS
  geometry.record(
    &self.internal.geometry,
    cam_index,
    self.internal.command_buffers[frame_index],
    &self.texture_manager,
    cam.attachments[.POSITION][frame_index],
    cam.attachments[.NORMAL][frame_index],
    cam.attachments[.ALBEDO][frame_index],
    cam.attachments[.METALLIC_ROUGHNESS][frame_index],
    cam.attachments[.EMISSIVE][frame_index],
    cam.attachments[.FINAL_IMAGE][frame_index],
    cam.attachments[.DEPTH][frame_index],
    scene_bindings(self, frame_index),
    cam.draws[.OPAQUE].commands[frame_index].buffer,
    cam.draws[.OPAQUE].count[frame_index].buffer,
    MAX_NODES_IN_SCENE,
  )
  return .SUCCESS
}

@(private)
record_lighting_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam_index: u32,
  cam: ^Camera,
  enabled_passes: PassTypeSet,
  cache: map[u32]shadow.ShadowFrameInfo,
) -> vk.Result {
  if .LIGHTING not_in enabled_passes do return .SUCCESS
  cmd := self.internal.command_buffers[frame_index]
  gbuffer := camera_gbuffer(cam, frame_index)
  ambient.record(
    &self.ambient,
    cam_index,
    cmd,
    &self.texture_manager,
    cam.attachments[.FINAL_IMAGE][frame_index],
    self.internal.camera_buffer.descriptor_sets[frame_index],
    gbuffer,
  )
  direct_light.begin_pass(
    &self.internal.direct_light,
    cam.attachments[.FINAL_IMAGE][frame_index],
    cam.attachments[.DEPTH][frame_index],
    &self.texture_manager,
    cmd,
    self.internal.camera_buffer.descriptor_sets[frame_index],
  )
  light_node_indices := sorted_light_indices(self)
  for light_node_index in light_node_indices {
    light := self.internal.lights[light_node_index]
    info := cache[light_node_index]
    switch variant in light {
    case PointLight:
      shadow_map_idx: u32 = 0xFFFFFFFF
      shadow_view_projection := matrix[4, 4]f32{}
      if sm, ok := self.internal.shadow_map_cubes[light_node_index]; ok {
        shadow_map_idx = sm.shadow_map_cube[frame_index].index
        shadow_view_projection = info.projection
      }
      direct_light.record_point_light(
        &self.internal.direct_light,
        cam_index,
        gbuffer,
        variant.color,
        variant.position,
        variant.radius,
        shadow_map_idx,
        shadow_view_projection,
        cmd,
      )
    case SpotLight:
      shadow_map_idx: u32 = 0xFFFFFFFF
      shadow_view_projection := matrix[4, 4]f32{}
      if sm, ok := self.internal.shadow_maps[light_node_index]; ok {
        shadow_map_idx = sm.shadow_map_2d[frame_index].index
        shadow_view_projection = info.view_projection
      }
      direct_light.record_spot_light(
        &self.internal.direct_light,
        cam_index,
        gbuffer,
        variant.color,
        variant.position,
        variant.direction,
        variant.radius,
        variant.angle_inner,
        variant.angle_outer,
        shadow_map_idx,
        shadow_view_projection,
        cmd,
      )
    case DirectionalLight:
      shadow_map_idx: u32 = 0xFFFFFFFF
      shadow_view_projection := matrix[4, 4]f32{}
      if sm, ok := self.internal.shadow_maps[light_node_index]; ok {
        shadow_map_idx = sm.shadow_map_2d[frame_index].index
        shadow_view_projection = info.view_projection
      }
      direct_light.record_directional_light(
        &self.internal.direct_light,
        cam_index,
        gbuffer,
        variant.color,
        variant.direction,
        shadow_map_idx,
        shadow_view_projection,
        cmd,
      )
    }
  }
  direct_light.end_pass(cmd)
  return .SUCCESS
}

@(private)
record_particles_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam_index: u32,
  cam: ^Camera,
  enabled_passes: PassTypeSet,
) -> vk.Result {
  if .PARTICLES not_in enabled_passes do return .SUCCESS
  particles_render.record(
    &self.internal.particles_render,
    self.internal.command_buffers[frame_index],
    cam_index,
    cam.attachments[.FINAL_IMAGE][frame_index],
    cam.attachments[.DEPTH][frame_index],
    &self.texture_manager,
    self.internal.camera_buffer.descriptor_sets[frame_index],
    self.texture_manager.descriptor_set,
    self.internal.particles_compute.compact_particle_buffer.buffer,
    self.internal.particles_compute.draw_command_buffer.buffer,
  )
  return .SUCCESS
}

// Forward pipelines in draw order, each gated by its pass.
@(private = "file")
FORWARD_PASSES := [?]struct {
  pipe: DrawPipeline,
  pass: PassType,
} {
  {.TRANSPARENT, .TRANSPARENCY},
  {.WIREFRAME, .WIREFRAME},
  {.RANDOM_COLOR, .RANDOM_COLOR},
  {.LINE_STRIP, .LINE_STRIP},
  {.SPRITE, .SPRITE},
}

@(private)
camera_gbuffer :: proc(cam: ^Camera, frame_index: u32) -> bindless.GBuffer {
  return {
    position           = cam.attachments[.POSITION][frame_index].index,
    normal             = cam.attachments[.NORMAL][frame_index].index,
    albedo             = cam.attachments[.ALBEDO][frame_index].index,
    metallic_roughness = cam.attachments[.METALLIC_ROUGHNESS][frame_index].index,
    emissive           = cam.attachments[.EMISSIVE][frame_index].index,
    depth              = cam.attachments[.DEPTH][frame_index].index,
  }
}

@(private)
scene_bindings :: proc(
  self: ^Manager,
  frame_index: u32,
) -> bindless.SceneBindings {
  return {
    layouts = {
      .CAMERA = self.internal.camera_buffer.set_layout,
      .TEXTURES = self.texture_manager.set_layout,
      .BONE = self.internal.bone_buffer.set_layout,
      .MATERIAL = self.internal.material_buffer.set_layout,
      .NODE_DATA = self.internal.node_data_buffer.set_layout,
      .MESH_DATA = self.internal.mesh_data_buffer.set_layout,
      .VERTEX_SKINNING = self.mesh_manager.vertex_skinning_buffer.set_layout,
      .SPRITE = self.internal.sprite_buffer.set_layout,
    },
    sets = {
      .CAMERA = self.internal.camera_buffer.descriptor_sets[frame_index],
      .TEXTURES = self.texture_manager.descriptor_set,
      .BONE = self.internal.bone_buffer.descriptor_sets[frame_index],
      .MATERIAL = self.internal.material_buffer.descriptor_set,
      .NODE_DATA = self.internal.node_data_buffer.descriptor_set,
      .MESH_DATA = self.internal.mesh_data_buffer.descriptor_set,
      .VERTEX_SKINNING = self.mesh_manager.vertex_skinning_buffer.descriptor_set,
      .SPRITE = self.internal.sprite_buffer.descriptor_set,
    },
    vertex_buffer = self.mesh_manager.vertex_buffer.buffer,
    index_buffer = self.mesh_manager.index_buffer.buffer,
  }
}

@(private)
record_transparency_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  gctx: ^gpu.GPUContext,
  cam_index: u32,
  cam: ^Camera,
  enabled_passes: PassTypeSet,
) -> vk.Result {
  if .TRANSPARENCY not_in enabled_passes do return .SUCCESS
  cmd := self.internal.command_buffers[frame_index]

  // Open a single render scope shared by all forward pipelines. Hoist all
  // draw-buffer barriers + depth layout transition here — Vulkan disallows
  // vkCmdPipelineBarrier inside a dynamic rendering instance.
  color_texture := bindless.get_texture_2d(
    &self.texture_manager,
    cam.attachments[.FINAL_IMAGE][frame_index],
  )
  depth_texture := bindless.get_texture_2d(
    &self.texture_manager,
    cam.attachments[.DEPTH][frame_index],
  )
  for f in FORWARD_PASSES {
    if f.pass not_in enabled_passes do continue
    cmds := &cam.draws[f.pipe].commands[frame_index]
    cnt := &cam.draws[f.pipe].count[frame_index]
    gpu.buffer_barrier(
      cmd,
      cmds.buffer,
      vk.DeviceSize(cmds.bytes_count),
      {.SHADER_WRITE},
      {.INDIRECT_COMMAND_READ},
      {.COMPUTE_SHADER},
      {.DRAW_INDIRECT},
    )
    gpu.buffer_barrier(
      cmd,
      cnt.buffer,
      vk.DeviceSize(cnt.bytes_count),
      {.SHADER_WRITE},
      {.INDIRECT_COMMAND_READ},
      {.COMPUTE_SHADER},
      {.DRAW_INDIRECT},
    )
  }
  gpu.memory_barrier(
    cmd,
    {.SHADER_READ},
    {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.FRAGMENT_SHADER},
    {.EARLY_FRAGMENT_TESTS},
  )
  gpu.begin_rendering(
    cmd,
    depth_texture.spec.extent,
    gpu.create_depth_attachment(depth_texture, .LOAD, .STORE),
    gpu.create_color_attachment(color_texture, .LOAD, .STORE),
  )
  gpu.set_viewport_scissor(cmd, depth_texture.spec.extent)

  scene := scene_bindings(self, frame_index)
  for f in FORWARD_PASSES {
    if f.pass not_in enabled_passes do continue
    forward.record(
      &self.internal.forward,
      cmd,
      f.pipe,
      cam_index,
      scene,
      cam.draws[f.pipe].commands[frame_index].buffer,
      cam.draws[f.pipe].count[frame_index].buffer,
      MAX_NODES_IN_SCENE,
    )
  }

  vk.CmdEndRendering(cmd)
  // Make depth writes visible to shader sampling (e.g. depth pyramid build
  // at start of next frame).
  gpu.memory_barrier(
    cmd,
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.LATE_FRAGMENT_TESTS},
    {.COMPUTE_SHADER, .FRAGMENT_SHADER},
  )
  return .SUCCESS
}

@(private)
record_debug_line_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam_index: u32,
  cam: ^Camera,
  swapchain_view: vk.ImageView,
  swapchain_extent: vk.Extent2D,
  enabled_passes: PassTypeSet,
) {
  if .DEBUG_LINE not_in enabled_passes do return
  depth := bindless.get_texture_2d(
    &self.texture_manager,
    cam.attachments[.DEPTH][frame_index],
  )
  if depth == nil do return
  debug_line.record(
    &self.internal.debug_line_renderer,
    self.internal.command_buffers[frame_index],
    frame_index,
    self.internal.camera_buffer.descriptor_sets[frame_index],
    cam_index,
    swapchain_view,
    swapchain_extent,
    depth,
  )
}

@(private)
record_post_process_pass :: proc(
  self: ^Manager,
  frame_index: u32,
  cam: ^Camera,
  swapchain_extent: vk.Extent2D,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
  enabled_passes: PassTypeSet,
) -> vk.Result {
  if .POST_PROCESS not_in enabled_passes do return .SUCCESS
  cmd := self.internal.command_buffers[frame_index]
  if final_image := bindless.get_texture_2d(
    &self.texture_manager,
    cam.attachments[.FINAL_IMAGE][frame_index],
  ); final_image != nil {
    gpu.memory_barrier(
      cmd,
      {.COLOR_ATTACHMENT_WRITE},
      {.SHADER_READ},
      {.COLOR_ATTACHMENT_OUTPUT},
      {.FRAGMENT_SHADER},
    )
  }
  gpu.image_discard_barrier(
    cmd,
    swapchain_image,
    {.COLOR_ATTACHMENT_WRITE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {.COLOR},
  )
  post_process.record(
    &self.post_process,
    cmd,
    swapchain_extent,
    swapchain_view,
    cam.attachments[.FINAL_IMAGE][frame_index].index,
    camera_gbuffer(cam, frame_index),
    &self.texture_manager,
  )
  return .SUCCESS
}

// record_frame drives the entire per-frame command sequence: shadow maps,
// per-camera passes (geometry, lighting, particles, transparency), debug,
// post-process, the 2D overlay (UI + debug UI), async compute, and the
// final swapchain transition to PRESENT_SRC — the one layout transition
// unified image layouts doesn't cover (the compositor is outside Vulkan).
@(private)
record_frame :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  frame_index: u32,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
  swapchain_extent: vk.Extent2D,
  debug_ui_enabled: bool,
) -> vk.Result {
  cmd := self.internal.command_buffers[frame_index]
  gpu.begin_record(cmd) or_return
  shadow_cache := build_shadow_cache(self)
  render_shadow_depth(self, frame_index, shadow_cache) or_return

  cull_indices := make(
    [dynamic]u32,
    0,
    len(self.cameras.entries),
    context.temp_allocator,
  )
  defer delete(cull_indices)
  for &entry, i in self.cameras.entries {
    if !entry.active do continue
    index, cam := u32(i), &entry.item
    if cam.enable_culling do append(&cull_indices, index)
    record_geometry_pass(self, frame_index, index, cam, cam.enabled_passes) or_return
    record_lighting_pass(self, frame_index, index, cam, cam.enabled_passes, shadow_cache) or_return
    record_particles_pass(self, frame_index, index, cam, cam.enabled_passes) or_return
    record_transparency_pass(self, frame_index, gctx, index, cam, cam.enabled_passes) or_return
  }

  main_camera_passes: PassTypeSet
  if main_cam, ok := cont.get(self.cameras, self.main_camera); ok {
    main_camera_passes = main_cam.enabled_passes
    record_post_process_pass(
      self,
      frame_index,
      main_cam,
      swapchain_extent,
      swapchain_image,
      swapchain_view,
      main_camera_passes,
    ) or_return
    record_debug_line_pass(
      self,
      frame_index,
      self.main_camera.index,
      main_cam,
      swapchain_view,
      swapchain_extent,
      main_camera_passes,
    )
  }
  ui_render.record(
    &self.internal.ui,
    &self.texture_manager,
    cmd,
    swapchain_view,
    swapchain_extent,
    frame_index,
    .UI in main_camera_passes,
    debug_ui_enabled,
  )

  // Compute (potentially on a separate async queue command buffer).
  compute_cmd := cmd
  if gctx.has_async_compute {
    compute_cmd = self.internal.compute_command_buffers[frame_index]
    gpu.begin_record(compute_cmd) or_return
  }
  record_compute_commands(self, frame_index, gctx, cull_indices[:]) or_return
  if gctx.has_async_compute {
    gpu.end_record(compute_cmd) or_return
  }


  present_barrier := vk.ImageMemoryBarrier2 {
    sType = .IMAGE_MEMORY_BARRIER_2,
    srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
    srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
    dstStageMask = {.BOTTOM_OF_PIPE},
    oldLayout = .GENERAL,
    newLayout = .PRESENT_SRC_KHR,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = swapchain_image,
    subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
  }
  present_dep := vk.DependencyInfo {
    sType                   = .DEPENDENCY_INFO,
    imageMemoryBarrierCount = 1,
    pImageMemoryBarriers    = &present_barrier,
  }
  vk.CmdPipelineBarrier2(cmd, &present_dep)
  gpu.end_record(cmd) or_return
  return .SUCCESS
}

// Command buffers recorded by record_frame, for submission.
@(private)
command_buffers :: proc(
  self: ^Manager,
  frame_index: u32,
) -> (
  graphics, compute: vk.CommandBuffer,
) {
  return self.internal.command_buffers[frame_index],
    self.internal.compute_command_buffers[frame_index]
}

// Render and present one frame: upload staged changes, acquire a swapchain
// image, record, submit and present, then advance deferred destruction. An
// out-of-date swapchain is rebuilt at `framebuffer_size`.
frame :: proc(
  self: ^Manager,
  framebuffer_size: [2]u32,
  dpi_scale: f32,
  debug_ui_enabled: bool,
) -> vk.Result {
  gctx := &self.gctx
  res := flush(self, gctx, self.frame_index)
  if res == .SUCCESS do res = present(self, debug_ui_enabled)
  // reclaims GPU resources freed FRAMES_IN_FLIGHT frames ago
  gpu.deferred_tick(gctx)
  bindless.texture_manager_tick(&self.texture_manager, gctx)
  if res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR {
    return recreate_swapchain(self, framebuffer_size, dpi_scale)
  }
  return res
}

@(private)
present :: proc(self: ^Manager, debug_ui_enabled: bool) -> vk.Result {
  gctx := &self.gctx
  sc := &self.swapchain
  gpu.acquire_next_image(gctx.device, sc, self.frame_index) or_return
  record_frame(
    self,
    gctx,
    self.frame_index,
    sc.images[sc.image_index],
    sc.views[sc.image_index],
    sc.extent,
    debug_ui_enabled,
  ) or_return
  graphics_cmd, compute_cmd := command_buffers(self, self.frame_index)
  gpu.submit_queue_and_present(gctx, sc, &graphics_cmd, &compute_cmd, self.frame_index) or_return
  self.frame_index = (self.frame_index + 1) % gpu.FRAMES_IN_FLIGHT
  return .SUCCESS
}

// Current swapchain size in pixels.
swapchain_extent :: proc(self: ^Manager) -> vk.Extent2D {
  return self.swapchain.extent
}
