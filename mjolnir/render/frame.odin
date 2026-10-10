package render

import "bindless"
import cont "../containers"
import geom "../geometry"
import "gpu"
import "ambient"
import "debug_line"
import "direct_light"
import "forward"
import "geometry"
import "occlusion_culling"
import "particles"
import "post_process"
import "shadow"
import ui_render "ui"
import vk "vendor:vulkan"

@(private)
record_compute_commands :: proc(
  self: ^Manager,
  frame_index: u32,
  cmd: vk.CommandBuffer,
) {
  // Compute for frame N builds pyramid[N] and writes the draw lists of
  // frame N+1, culled against pyramid[N].
  next_frame_index := (frame_index + 1) % gpu.FRAMES_IN_FLIGHT
  it := cont.iterator(&self.cameras)
  for cam, handle in cont.next(&it, CameraHandle) {
    occlusion_culling.build_pyramid(
      &self.internal.visibility,
      cmd,
      &self.texture_manager,
      &cam.depth_pyramid[frame_index],
      cam.depth_reduce_descriptor_sets[frame_index][:],
    )
    occlusion_culling.perform_culling(
      &self.internal.visibility,
      cmd,
      handle.index,
      next_frame_index,
      self.node_count,
      &cam.draws,
      cam.descriptor_set[next_frame_index],
    )
  }
  particles.simulate(
    &self.internal.particles,
    cmd,
    self.internal.node_data_buffer.descriptor_set,
  )
}

@(private)
render_shadow_depth :: proc(
  self: ^Manager,
  frame_index: u32,
  lights: []FrameLight,
) -> vk.Result {
  cmd := self.internal.command_buffers[frame_index]
  scene := scene_bindings(self, frame_index)
  for &fl in lights {
    sm := fl.shadow_map
    if sm == nil do continue
    info := fl.info
    draw_commands := sm.draws.commands[frame_index]
    draw_count := sm.draws.count[frame_index]
    switch fl.type {
    case .SPOT, .DIRECTIONAL:
      shadow.cull(
        &self.internal.shadow,
        cmd,
        self.node_count,
        geom.make_frustum(info.view_projection).planes,
        draw_count.buffer,
        sm.descriptor_sets[frame_index],
      )
      shadow.record_frustum(
        &self.internal.shadow,
        cmd,
        &self.texture_manager,
        scene,
        info.view_projection,
        bindless.Texture2DHandle(sm.textures[frame_index]),
        draw_commands,
        draw_count,
      )
    case .POINT:
      shadow.cull(
        &self.internal.shadow,
        cmd,
        self.node_count,
        shadow.box_planes(fl.params.position, fl.params.radius),
        draw_count.buffer,
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
        fl.params.position,
        bindless.TextureCubeHandle(sm.textures[frame_index]),
        draw_commands,
        draw_count,
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
) -> vk.Result {
  // The cull pass wrote every draw list of this camera; the geometry and
  // forward passes read them.
  cmd := self.internal.command_buffers[frame_index]
  commands := &cam.draws.commands[frame_index]
  count := &cam.draws.count[frame_index]
  gpu.buffer_barrier(
    cmd,
    commands.buffer,
    vk.DeviceSize(commands.bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    cmd,
    count.buffer,
    vk.DeviceSize(count.bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  geometry.record(
    &self.internal.geometry,
    cam_index,
    cmd,
    &self.texture_manager,
    cam.attachments[.POSITION][frame_index],
    cam.attachments[.NORMAL][frame_index],
    cam.attachments[.ALBEDO][frame_index],
    cam.attachments[.METALLIC_ROUGHNESS][frame_index],
    cam.attachments[.EMISSIVE][frame_index],
    cam.attachments[.FINAL_IMAGE][frame_index],
    cam.attachments[.DEPTH][frame_index],
    scene_bindings(self, frame_index),
    cam.draws.commands[frame_index].buffer,
    cam.draws.count[frame_index].buffer,
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
  lights: []FrameLight,
) -> vk.Result {
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
    self.mesh_manager.vertex_buffer.buffer,
    self.mesh_manager.index_buffer.buffer,
  )
  sphere := cont.get(self.meshes, self.builtin_meshes[.SPHERE])
  cone := cont.get(self.meshes, self.builtin_meshes[.CONE])
  for &fl in lights {
    shadow_map: u32 = direct_light.NO_SHADOW
    shadow_view_projection: matrix[4, 4]f32
    if sm := fl.shadow_map; sm != nil {
      shadow_map = sm.textures[frame_index].index
      shadow_view_projection = fl.info.projection if sm.cube else fl.info.view_projection
    }
    direct_light.record_light(
      &self.internal.direct_light,
      cmd,
      fl.type,
      fl.params,
      cone.allocations if fl.type == .SPOT else sphere.allocations,
      cam_index,
      gbuffer,
      shadow_map,
      shadow_view_projection,
    )
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
) -> vk.Result {
  particles.record(
    &self.internal.particles,
    self.internal.command_buffers[frame_index],
    cam_index,
    cam.attachments[.FINAL_IMAGE][frame_index],
    cam.attachments[.DEPTH][frame_index],
    &self.texture_manager,
    self.internal.camera_buffer.descriptor_sets[frame_index],
    self.texture_manager.descriptor_set,
  )
  return .SUCCESS
}

// Forward pipelines in draw order.
@(private = "file")
FORWARD_PIPELINES := [?]bindless.DrawPipeline{.TRANSPARENT, .WIREFRAME, .RANDOM_COLOR, .SPRITE}

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
      .VERTEX_SKINNING = self.mesh_manager.skinning_set_layout,
      .SPRITE = self.internal.sprite_buffer.set_layout,
    },
    sets = {
      .CAMERA = self.internal.camera_buffer.descriptor_sets[frame_index],
      .TEXTURES = self.texture_manager.descriptor_set,
      .BONE = self.internal.bone_buffer.descriptor_sets[frame_index],
      .MATERIAL = self.internal.material_buffer.descriptor_set,
      .NODE_DATA = self.internal.node_data_buffer.descriptor_set,
      .MESH_DATA = self.internal.mesh_data_buffer.descriptor_set,
      .VERTEX_SKINNING = self.mesh_manager.skinning_set,
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
  cam_index: u32,
  cam: ^Camera,
) -> vk.Result {
  cmd := self.internal.command_buffers[frame_index]

  // Open a single render scope shared by all forward pipelines. The depth
  // barrier goes first: Vulkan disallows vkCmdPipelineBarrier inside a
  // dynamic rendering instance.
  color_texture := bindless.get_texture_2d(
    &self.texture_manager,
    cam.attachments[.FINAL_IMAGE][frame_index],
  )
  depth_texture := bindless.get_texture_2d(
    &self.texture_manager,
    cam.attachments[.DEPTH][frame_index],
  )
  gpu.memory_barrier(
    cmd,
    {.SHADER_READ},
    {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.FRAGMENT_SHADER},
    {.EARLY_FRAGMENT_TESTS},
  )
  gpu.begin_rendering(
    cmd,
    depth_texture.extent,
    gpu.create_depth_attachment(depth_texture.view, .LOAD, .STORE),
    gpu.create_color_attachment(color_texture.view, .LOAD, .STORE),
  )
  gpu.set_viewport_scissor(cmd, depth_texture.extent)

  scene := scene_bindings(self, frame_index)
  for pipe in FORWARD_PIPELINES {
    forward.record(
      &self.internal.forward,
      cmd,
      pipe,
      cam_index,
      scene,
      cam.draws.commands[frame_index].buffer,
      cam.draws.count[frame_index].buffer,
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
) {
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
) -> vk.Result {
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
  frame_index: u32,
  swapchain_image: vk.Image,
  swapchain_view: vk.ImageView,
  swapchain_extent: vk.Extent2D,
  debug_ui_enabled: bool,
) -> vk.Result {
  cmd := self.internal.command_buffers[frame_index]
  gpu.begin_record(cmd) or_return
  lights := self.internal.frame_lights[:]
  render_shadow_depth(self, frame_index, lights) or_return

  it := cont.iterator(&self.cameras)
  for cam, handle in cont.next(&it, CameraHandle) {
    index := handle.index
    record_geometry_pass(self, frame_index, index, cam) or_return
    record_lighting_pass(self, frame_index, index, cam, lights) or_return
    record_particles_pass(self, frame_index, index, cam) or_return
    record_transparency_pass(self, frame_index, index, cam) or_return
  }

  main_cam, has_main := cont.get(self.cameras, self.main_camera)
  if has_main {
    record_post_process_pass(
      self,
      frame_index,
      main_cam,
      swapchain_extent,
      swapchain_image,
      swapchain_view,
    ) or_return
    record_debug_line_pass(
      self,
      frame_index,
      self.main_camera.index,
      main_cam,
      swapchain_view,
      swapchain_extent,
    )
  }
  ui_render.record(
    &self.internal.ui,
    &self.texture_manager,
    cmd,
    swapchain_view,
    swapchain_extent,
    frame_index,
    has_main,
    debug_ui_enabled,
  )

  // Compute (potentially on a separate async queue command buffer).
  compute_cmd := cmd
  if gpu.has_async_compute(&self.gctx) {
    compute_cmd = self.internal.compute_command_buffers[frame_index]
    gpu.begin_record(compute_cmd) or_return
  }
  record_compute_commands(self, frame_index, compute_cmd)
  if gpu.has_async_compute(&self.gctx) {
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

// Render and present one frame: upload staged changes, acquire a swapchain
// image, record, submit and present, then advance deferred destruction. An
// out-of-date swapchain is rebuilt at `framebuffer_size`. Renders nothing
// while no level is set up.
frame :: proc(
  self: ^Manager,
  framebuffer_size: [2]u32,
  dpi_scale: f32,
  debug_ui_enabled: bool,
) -> vk.Result {
  if !self.internal.level_ready do return .SUCCESS
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
    self.frame_index,
    sc.images[sc.image_index],
    sc.views[sc.image_index],
    sc.extent,
    debug_ui_enabled,
  ) or_return
  graphics_cmd := self.internal.command_buffers[self.frame_index]
  compute_cmd := self.internal.compute_command_buffers[self.frame_index]
  gpu.submit_queue_and_present(gctx, sc, &graphics_cmd, &compute_cmd, self.frame_index) or_return
  self.frame_index = (self.frame_index + 1) % gpu.FRAMES_IN_FLIGHT
  return .SUCCESS
}
