package geometry_pass

import "../bindless"
import "../gpu"
import "core:log"
import vk "vendor:vulkan"

@(private)
SHADER_G_BUFFER_VERT :: #load("../shader/gbuffer/vert.spv")
@(private)
SHADER_G_BUFFER_FRAG :: #load("../shader/gbuffer/frag.spv")

@(private)
PushConstant :: struct {
  camera_index: u32,
}

Renderer :: struct {
  pipeline_layout: vk.PipelineLayout,
  pipeline:         vk.Pipeline,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  scene: bindless.SceneBindings,
) -> (
  ret: vk.Result,
) {
  self.pipeline_layout = bindless.create_scene_pipeline_layout(
    gctx,
    scene,
    bindless.MESH_SETS,
    {stageFlags = {.VERTEX, .FRAGMENT}, size = size_of(PushConstant)},
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
    self.pipeline_layout = 0
  }
  if self.pipeline_layout == 0 {
    return .ERROR_INITIALIZATION_FAILED
  }
  log.info("About to build G-buffer pipelines...")
  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_G_BUFFER_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_G_BUFFER_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  blend := [?]vk.PipelineColorBlendAttachmentState {
    gpu.BLEND_OVERRIDE, // position
    gpu.BLEND_OVERRIDE, // normal
    gpu.BLEND_OVERRIDE, // albedo
    gpu.BLEND_OVERRIDE, // metallic/roughness
    gpu.BLEND_OVERRIDE, // emissive
  }
  color_formats := [?]vk.Format {
    .R32G32B32A32_SFLOAT, // position
    .R8G8B8A8_UNORM, // normal
    .R8G8B8A8_UNORM, // albedo
    .R8G8B8A8_UNORM, // metallic/roughness
    .R8G8B8A8_UNORM, // emissive
  }
  self.pipeline = gpu.create_graphics_pipeline(
    gctx,
    {
      vert = vert_module,
      frag = frag_module,
      specialization = &bindless.SHADER_SPEC_CONSTANTS,
      vertex_bindings = bindless.VERTEX_BINDING_DESCRIPTION[:],
      vertex_attributes = bindless.VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
      topology = .TRIANGLE_LIST,
      raster = gpu.STANDARD_RASTERIZER,
      depth = gpu.READ_WRITE_DEPTH_STATE,
      blend = blend[:],
      color_formats = color_formats[:],
      depth_format = .D32_SFLOAT,
      layout = self.pipeline_layout,
    },
  ) or_return
  log.info("G-buffer renderer initialized successfully")
  return .SUCCESS
}

// record performs the full G-buffer pass: barriers + begin_rendering + draw
// + end_rendering + barriers. Owns its own begin/end so the orchestrator does
// not coordinate them.
record :: proc(
  self: ^Renderer,
  camera_handle: u32,
  command_buffer: vk.CommandBuffer,
  texture_manager: ^bindless.TextureManager,
  position_handle: bindless.Texture2DHandle,
  normal_handle: bindless.Texture2DHandle,
  albedo_handle: bindless.Texture2DHandle,
  metallic_roughness_handle: bindless.Texture2DHandle,
  emissive_handle: bindless.Texture2DHandle,
  final_image_handle: bindless.Texture2DHandle,
  depth_handle: bindless.Texture2DHandle,
  scene: bindless.SceneBindings,
  draw_buffer: vk.Buffer,
  count_buffer: vk.Buffer,
  max_draws: u32,
) {
  if draw_buffer == 0 || count_buffer == 0 {
    return
  }
  position_texture := bindless.get_texture_2d(texture_manager, position_handle)
  normal_texture := bindless.get_texture_2d(texture_manager, normal_handle)
  albedo_texture := bindless.get_texture_2d(texture_manager, albedo_handle)
  metallic_roughness_texture := bindless.get_texture_2d(
    texture_manager,
    metallic_roughness_handle,
  )
  emissive_texture := bindless.get_texture_2d(texture_manager, emissive_handle)
  final_texture := bindless.get_texture_2d(texture_manager, final_image_handle)
  depth_texture := bindless.get_texture_2d(texture_manager, depth_handle)
  // Discard previous contents of the G-buffer + final image + depth.
  for img in ([?]vk.Image {
       position_texture.image,
       normal_texture.image,
       albedo_texture.image,
       metallic_roughness_texture.image,
       emissive_texture.image,
       final_texture.image,
     }) {
    gpu.image_discard_barrier(
      command_buffer,
      img,
      {.COLOR_ATTACHMENT_WRITE},
      {.COLOR_ATTACHMENT_OUTPUT},
      {.COLOR},
    )
  }
  gpu.image_discard_barrier(
    command_buffer,
    depth_texture.image,
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.EARLY_FRAGMENT_TESTS},
    {.DEPTH},
  )
  gpu.begin_rendering(
    command_buffer,
    depth_texture.extent,
    gpu.create_depth_attachment(depth_texture.view),
    gpu.create_color_attachment(position_texture.view),
    gpu.create_color_attachment(normal_texture.view),
    gpu.create_color_attachment(albedo_texture.view),
    gpu.create_color_attachment(metallic_roughness_texture.view),
    gpu.create_color_attachment(emissive_texture.view),
  )
  gpu.set_viewport_scissor(command_buffer, depth_texture.extent)
  bindless.bind_scene(
    command_buffer,
    self.pipeline,
    self.pipeline_layout,
    scene,
    bindless.MESH_SETS,
  )
  push_constants := PushConstant {
    camera_index = camera_handle,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(PushConstant),
    &push_constants,
  )
  vk.CmdDrawIndexedIndirectCount(
    command_buffer,
    draw_buffer,
    0,
    count_buffer,
    0,
    max_draws,
    u32(size_of(vk.DrawIndexedIndirectCommand)),
  )
  vk.CmdEndRendering(command_buffer)
  // Make G-buffer + depth writes visible to the lighting pass that follows.
  gpu.memory_barrier(
    command_buffer,
    {.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS},
    {.COMPUTE_SHADER, .FRAGMENT_SHADER},
  )
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  self.pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}
