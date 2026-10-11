#+private
package render

import "gpu"
import vk "vendor:vulkan"

SHADER_G_BUFFER_VERT :: #load("shader/gbuffer/vert.spv")
SHADER_G_BUFFER_FRAG :: #load("shader/gbuffer/frag.spv")

GBufferPushConstant :: struct {
  camera_index: u32,
}

GBufferRenderer :: struct {
  pipeline_layout: vk.PipelineLayout,
  pipeline:         vk.Pipeline,
}

gbuffer_init :: proc(r: ^Manager) -> vk.Result {
  self := &r.internal.geometry
  gctx := &r.gctx
  self.pipeline_layout = create_scene_pipeline_layout(
    r,
    MESH_SETS,
    {stageFlags = {.VERTEX, .FRAGMENT}, size = size_of(GBufferPushConstant)},
  ) or_return
  blend := [?]vk.PipelineColorBlendAttachmentState {
    gpu.BLEND_OVERRIDE, // normal
    gpu.BLEND_OVERRIDE, // albedo
    gpu.BLEND_OVERRIDE, // metallic/roughness
    gpu.BLEND_OVERRIDE, // emissive
  }
  color_formats := [?]vk.Format {
    .R8G8B8A8_UNORM, // normal
    .R8G8B8A8_UNORM, // albedo
    .R8G8B8A8_UNORM, // metallic/roughness
    .R16G16B16A16_SFLOAT, // emissive (HDR, feeds bloom)
  }
  self.pipeline = gpu.create_graphics_pipeline(
    gctx,
    {
      vert = SHADER_G_BUFFER_VERT,
      frag = SHADER_G_BUFFER_FRAG,
      specialization = &SHADER_SPEC_CONSTANTS,
      vertex_bindings = VERTEX_BINDING_DESCRIPTION[:],
      vertex_attributes = VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
      topology = .TRIANGLE_LIST,
      raster = gpu.STANDARD_RASTERIZER,
      depth = gpu.READ_WRITE_DEPTH_STATE,
      blend = blend[:],
      color_formats = color_formats[:],
      depth_format = .D32_SFLOAT,
      layout = self.pipeline_layout,
    },
  ) or_return
  return .SUCCESS
}

// Record one camera's G-buffer pass: discard, draw the opaque list the cull
// pass wrote, then publish the targets to the lighting pass.
gbuffer_record :: proc(r: ^Manager, frame_index: u32, cam_index: u32, cam: ^Camera) {
  self := &r.internal.geometry
  command_buffer := r.internal.command_buffers[frame_index]
  commands := &cam.draws.commands[frame_index]
  count := &cam.draws.count[frame_index]
  if commands.buffer == 0 || count.buffer == 0 do return
  indirect_barrier(command_buffer, commands, count)
  normal_texture := camera_image(r, cam, .NORMAL, frame_index)
  albedo_texture := camera_image(r, cam, .ALBEDO, frame_index)
  metallic_roughness_texture := camera_image(r, cam, .METALLIC_ROUGHNESS, frame_index)
  emissive_texture := camera_image(r, cam, .EMISSIVE, frame_index)
  final_texture := camera_image(r, cam, .FINAL_IMAGE, frame_index)
  depth_texture := camera_image(r, cam, .DEPTH, frame_index)
  // Discard previous contents of the G-buffer + final image + depth.
  for img in ([?]vk.Image {
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
    gpu.create_color_attachment(normal_texture.view),
    gpu.create_color_attachment(albedo_texture.view),
    gpu.create_color_attachment(metallic_roughness_texture.view),
    gpu.create_color_attachment(emissive_texture.view),
  )
  gpu.set_viewport_scissor(command_buffer, depth_texture.extent)
  bind_scene(r, command_buffer, frame_index, self.pipeline, self.pipeline_layout, MESH_SETS)
  push_constants := GBufferPushConstant {
    camera_index = cam_index,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(GBufferPushConstant),
    &push_constants,
  )
  vk.CmdDrawIndexedIndirectCount(
    command_buffer,
    commands.buffer,
    0,
    count.buffer,
    0,
    MAX_NODES_IN_SCENE,
    u32(size_of(vk.DrawIndexedIndirectCommand)),
  )
  vk.CmdEndRendering(command_buffer)
  // Make G-buffer + depth writes visible to the lighting pass that follows:
  // sampled by its shaders and depth-tested by its light volumes.
  gpu.memory_barrier(
    command_buffer,
    {.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ, .DEPTH_STENCIL_ATTACHMENT_READ},
    {.COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS},
    {.COMPUTE_SHADER, .FRAGMENT_SHADER, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
  )
}

gbuffer_shutdown :: proc(self: ^GBufferRenderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  self.pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}
