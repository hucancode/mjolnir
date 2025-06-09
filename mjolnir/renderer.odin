package mjolnir

import "core:fmt"
import "core:log"
import "core:math"
import linalg "core:math/linalg"
import "core:slice"
import "core:time"
import "geometry"
import "resource"
import glfw "vendor:glfw"
import mu "vendor:microui"
import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 2

BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}
BG_DARK_GRAY :: [4]f32{0.0117, 0.0117, 0.0117, 1.0}
BG_ORANGE_GRAY :: [4]f32{0.0179, 0.0179, 0.0117, 1.0}

SingleLightUniform :: struct {
  view_proj:  linalg.Matrix4f32,
  color:      linalg.Vector4f32,
  position:   linalg.Vector4f32,
  direction:  linalg.Vector4f32,
  kind:       enum u32 {
    POINT       = 0,
    DIRECTIONAL = 1,
    SPOT        = 2,
  },
  angle:      f32, // For spotlight: cone angle
  radius:     f32, // For point/spot: attenuation radius
  has_shadow: b32,
}

SceneUniform :: struct {
  view:       linalg.Matrix4f32,
  projection: linalg.Matrix4f32,
  time:       f32,
}

SceneLightUniform :: struct {
  lights:      [MAX_LIGHTS]SingleLightUniform,
  light_count: u32,
}

push_light :: proc(self: ^SceneLightUniform, light: SingleLightUniform) {
  if self.light_count < MAX_LIGHTS {
    self.lights[self.light_count] = light
    self.light_count += 1
  }
}

clear_lights :: proc(self: ^SceneLightUniform) {
  self.light_count = 0
}

Renderer :: struct {
  frames:      [MAX_FRAMES_IN_FLIGHT]Frame,
  frame_index: u32,
  main:        RendererMain,
  shadow:      RendererShadow,
  particle:    RendererParticle,
  postprocess: RendererPostProcess,
  meshes:      resource.Pool(Mesh),
  materials:   resource.Pool(Material),
  textures:    resource.Pool(Texture),
}

renderer_init :: proc(
  self: ^Renderer,
  width: u32,
  height: u32,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> vk.Result {
  log.infof("Initializing mesh pool... ")
  resource.pool_init(&self.meshes)
  log.infof("Initializing materials pool... ")
  resource.pool_init(&self.materials)
  log.infof("Initializing textures pool... ")
  resource.pool_init(&self.textures)
  log.infof("All resource pools initialized successfully")
  self.main.depth_buffer = create_depth_image(width, height) or_return
  renderer_main_init(&self.main, color_format, depth_format) or_return
  renderer_particle_init(&self.particle) or_return
  renderer_shadow_init(
    &self.shadow,
    self.main.camera_descriptor_set_layout,
    self.main.skinning_descriptor_set_layout,
    depth_format,
  ) or_return
  renderer_postprocess_init(
    &self.postprocess,
    color_format,
    width,
    height,
  ) or_return
  self.frame_index = 0
  for &frame in self.frames {
    frame_init(
      &frame,
      color_format,
      width,
      height,
      // TODO: Eliminate this dependency if possible
      self.main.camera_descriptor_set_layout,
    ) or_return
  }
  return .SUCCESS
}

renderer_deinit :: proc(self: ^Renderer) {
  vk.DeviceWaitIdle(g_device)
  resource.pool_deinit(self.textures, texture_deinit)
  resource.pool_deinit(self.meshes, mesh_deinit)
  resource.pool_deinit(self.materials, material_deinit)
  renderer_main_deinit(&self.main)
  renderer_shadow_deinit(&self.shadow)
  renderer_postprocess_deinit(&self.postprocess)
  renderer_particle_deinit(&self.particle)
  for &frame in self.frames do frame_deinit(&frame)
}

renderer_recreate_images :: proc(
  self: ^Renderer,
  new_format: vk.Format,
  new_extent: vk.Extent2D,
) -> vk.Result {
  vk.DeviceWaitIdle(g_device)
  image_buffer_deinit(&self.main.depth_buffer)
  for &frame in self.frames {
    frame_deinit_images(&frame)
  }
  self.main.depth_buffer = create_depth_image(
    new_extent.width,
    new_extent.height,
  ) or_return
  for &frame in self.frames {
    frame_recreate_images(
      &frame,
      new_format,
      new_extent.width,
      new_extent.height,
    ) or_return
  }
  return .SUCCESS
}

renderer_get_in_flight_fence :: proc(self: ^Renderer) -> vk.Fence {
  return self.frames[self.frame_index].fence
}

renderer_get_image_available_semaphore :: proc(
  self: ^Renderer,
) -> vk.Semaphore {
  return self.frames[self.frame_index].image_available_semaphore
}

renderer_get_render_finished_semaphore :: proc(
  self: ^Renderer,
) -> vk.Semaphore {
  return self.frames[self.frame_index].render_finished_semaphore
}

renderer_get_command_buffer :: proc(self: ^Renderer) -> vk.CommandBuffer {
  if self == nil {
    return vk.CommandBuffer{}
  }
  if self.frame_index >= len(self.frames) {
    log.errorf(
      "Error: Invalid frame index",
      self.frame_index,
      "vs",
      len(self.frames),
    )
    return vk.CommandBuffer{}
  }
  cmd_buffer := self.frames[self.frame_index].command_buffer
  if cmd_buffer == nil {
    log.errorf("Error: Command buffer is nil for frame", self.frame_index)
    return vk.CommandBuffer{}
  }
  return cmd_buffer
}

renderer_get_main_pass_image :: proc(self: ^Renderer) -> vk.Image {
  return self.frames[self.frame_index].main_pass_image.image
}

renderer_get_main_pass_view :: proc(self: ^Renderer) -> vk.ImageView {
  return self.frames[self.frame_index].main_pass_image.view
}

renderer_get_postprocess_pass_image :: proc(
  self: ^Renderer,
  i: int,
) -> vk.Image {
  return self.frames[self.frame_index].postprocess_images[i].image
}

renderer_get_postprocess_pass_view :: proc(
  self: ^Renderer,
  i: int,
) -> vk.ImageView {
  return self.frames[self.frame_index].postprocess_images[i].view
}

renderer_get_camera_uniform :: proc(
  self: ^Renderer,
) -> ^DataBuffer(SceneUniform) {
  return &self.frames[self.frame_index].camera_uniform
}

renderer_get_light_uniform :: proc(
  self: ^Renderer,
) -> ^DataBuffer(SceneLightUniform) {
  return &self.frames[self.frame_index].light_uniform
}

renderer_get_shadow_map :: proc(
  self: ^Renderer,
  light_idx: int,
) -> ^DepthTexture {
  return &self.frames[self.frame_index].shadow_maps[light_idx]
}

renderer_get_cube_shadow_map :: proc(
  self: ^Renderer,
  light_idx: int,
) -> ^CubeDepthTexture {
  return &self.frames[self.frame_index].cube_shadow_maps[light_idx]
}

renderer_get_camera_descriptor_set :: proc(
  self: ^Renderer,
) -> vk.DescriptorSet {
  return self.frames[self.frame_index].camera_descriptor_set
}

renderer_get_shadow_map_descriptor_set :: proc(
  self: ^Renderer,
) -> vk.DescriptorSet {
  return self.frames[self.frame_index].shadow_map_descriptor_set
}

renderer_get_cube_shadow_map_descriptor_set :: proc(
  self: ^Renderer,
) -> vk.DescriptorSet {
  return self.frames[self.frame_index].cube_shadow_map_descriptor_set
}

renderer_grayscale :: proc(
  self: ^Renderer,
  strength: f32 = 1.0,
  weights: [3]f32 = {0.299, 0.587, 0.114},
) {
  effect_add_grayscale(&self.postprocess, strength, weights)
}

renderer_blur :: proc(self: ^Renderer, radius: f32) {
  effect_add_blur(&self.postprocess, radius)
}

renderer_bloom :: proc(
  self: ^Renderer,
  threshold: f32 = 0.2,
  intensity: f32 = 1.0,
  blur_radius: f32 = 4.0,
) {
  effect_add_bloom(&self.postprocess, threshold, intensity, blur_radius)
}

renderer_tonemap :: proc(
  self: ^Renderer,
  exposure: f32 = 1.0,
  gamma: f32 = 2.2,
) {
  effect_add_tonemap(&self.postprocess, exposure, gamma)
}

renderer_outline :: proc(self: ^Renderer, thickness: f32, color: [3]f32) {
  effect_add_outline(&self.postprocess, thickness, color)
}

renderer_clear_effects :: proc(self: ^Renderer) {
  effect_clear(&self.postprocess)
}

renderer_postprocess_update_input :: proc(
  self: ^Renderer,
  set_idx: int,
  input_view: vk.ImageView,
) -> vk.Result {
  return postprocess_update_input(&self.postprocess, set_idx, input_view)
}

prepare_light :: proc(node: ^Node, cb_context: rawptr) -> bool {
  ctx := (^CollectLightsContext)(cb_context)
  uniform: SingleLightUniform
  #partial switch data in node.attachment {
  case PointLightAttachment:
    uniform.kind = .POINT
    uniform.color = data.color
    uniform.radius = data.radius
    uniform.has_shadow = b32(data.cast_shadow)
    uniform.position =
      node.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
    push_light(ctx.light_uniform, uniform)
  case DirectionalLightAttachment:
    uniform.kind = .DIRECTIONAL
    uniform.color = data.color
    uniform.has_shadow = b32(data.cast_shadow)
    uniform.position =
      node.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
    uniform.direction =
      node.transform.world_matrix * linalg.Vector4f32{0, 0, 1, 0} // Assuming +Z is forward
    push_light(ctx.light_uniform, uniform)
  case SpotLightAttachment:
    uniform.kind = .SPOT
    uniform.color = data.color
    uniform.radius = data.radius
    uniform.has_shadow = b32(data.cast_shadow)
    uniform.angle = data.angle
    uniform.position =
      node.transform.world_matrix * linalg.Vector4f32{0, 0, 0, 1}
    uniform.direction =
      node.transform.world_matrix * linalg.Vector4f32{0, 0, 1, 0}
    push_light(ctx.light_uniform, uniform)
  }
  return true
}

render :: proc(engine: ^Engine) -> vk.Result {
  current_fence := renderer_get_in_flight_fence(&engine.renderer)
  log.debug("waiting for fence...")
  vk.WaitForFences(g_device, 1, &current_fence, true, math.max(u64)) or_return
  current_image_available_semaphore := renderer_get_image_available_semaphore(
    &engine.renderer,
  )
  image_idx := swapchain_acquire_next_image(
    &engine.swapchain,
    current_image_available_semaphore,
  ) or_return
  log.debug("reseting fence...")
  vk.ResetFences(g_device, 1, &current_fence) or_return
  mu.begin(&engine.ui.ctx)
  command_buffer := renderer_get_command_buffer(&engine.renderer)
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  begin_info := vk.CommandBufferBeginInfo {
    sType = .COMMAND_BUFFER_BEGIN_INFO,
    flags = {.ONE_TIME_SUBMIT},
  }
  log.debug("begining command...")
  vk.BeginCommandBuffer(command_buffer, &begin_info) or_return
  elapsed_seconds := time.duration_seconds(time.since(engine.start_timestamp))
  scene_uniform := SceneUniform {
    view       = geometry.calculate_view_matrix(engine.scene.camera),
    projection = geometry.calculate_projection_matrix(engine.scene.camera),
    time       = f32(elapsed_seconds),
  }
  light_uniform: SceneLightUniform
  camera_frustum := geometry.camera_make_frustum(engine.scene.camera)
  collect_ctx := CollectLightsContext {
    engine        = engine,
    light_uniform = &light_uniform,
  }
  if !traverse_scene(&engine.scene, &collect_ctx, prepare_light) {
    log.errorf("[RENDER] Error during light collection")
  }
  log.debug("============ rendering shadow pass...============ ")
  render_shadow_pass(engine, &light_uniform, command_buffer) or_return
  log.debug("============ rendering main pass... =============")
  prepare_image_for_render(
    command_buffer,
    renderer_get_main_pass_image(&engine.renderer),
  )
  render_main_pass(
    engine,
    command_buffer,
    camera_frustum,
    engine.swapchain.extent,
  ) or_return
  data_buffer_write(
    renderer_get_camera_uniform(&engine.renderer),
    &scene_uniform,
  )
  data_buffer_write(
    renderer_get_light_uniform(&engine.renderer),
    &light_uniform,
  )
  if engine.render2d_proc != nil {
    engine.render2d_proc(engine, &engine.ui.ctx)
  }
  mu.end(&engine.ui.ctx)
  ui_render(&engine.ui, command_buffer)
  vk.CmdEndRenderingKHR(command_buffer)
  prepare_image_for_shader_read(
    command_buffer,
    renderer_get_main_pass_image(&engine.renderer),
  )
  prepare_image_for_render(command_buffer, engine.swapchain.images[image_idx])
  log.debug("============ rendering post processes... =============")
  render_postprocess_stack(
    &engine.renderer.postprocess,
    command_buffer,
    renderer_get_main_pass_view(&engine.renderer),
    engine.swapchain.views[image_idx],
    engine.swapchain.extent,
  )
  prepare_image_for_present(command_buffer, engine.swapchain.images[image_idx])
  vk.EndCommandBuffer(command_buffer) or_return
  current_render_finished_semaphore := renderer_get_render_finished_semaphore(
    &engine.renderer,
  )
  wait_stage_mask: vk.PipelineStageFlags = {.COLOR_ATTACHMENT_OUTPUT}
  submit_info := vk.SubmitInfo {
    sType                = .SUBMIT_INFO,
    waitSemaphoreCount   = 1,
    pWaitSemaphores      = &current_image_available_semaphore,
    pWaitDstStageMask    = &wait_stage_mask,
    commandBufferCount   = 1,
    pCommandBuffers      = &command_buffer,
    signalSemaphoreCount = 1,
    pSignalSemaphores    = &current_render_finished_semaphore,
  }
  log.debug("============ submitting queue... =============")
  vk.QueueSubmit(g_graphics_queue, 1, &submit_info, current_fence) or_return
  present_result := swapchain_present(
    &engine.swapchain,
    &current_render_finished_semaphore,
    image_idx,
  )
  if present_result != .SUCCESS {
    return present_result
  }
  engine.renderer.frame_index =
    (engine.renderer.frame_index + 1) % MAX_FRAMES_IN_FLIGHT
  return .SUCCESS
}
