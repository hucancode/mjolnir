package skybox

import "../../gpu"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

SHADER_VERT :: #load("../../shader/skybox/vert.spv")
SHADER_FRAG :: #load("../../shader/skybox/frag.spv")

PushConstant :: struct {
  camera_index:           u32,
  environment_index:      u32,
  position_texture_index: u32,
  intensity:              f32,
  lod:                    f32,
}

Renderer :: struct {
  pipeline:        vk.Pipeline,
  pipeline_layout: vk.PipelineLayout,
  intensity:       f32,
  lod:             f32,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  camera_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  log.debug("Skybox renderer init")
  self.intensity = 1.0
  self.lod = 0.0
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.FRAGMENT},
      size = size_of(PushConstant),
    },
    camera_set_layout,
    textures_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  }
  vert_module := gpu.create_shader_module(gctx.device, SHADER_VERT) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(gctx.device, SHADER_FRAG) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  shader_stages := gpu.create_vert_frag_stages(
    vert_module,
    frag_module,
    &shared.SHADER_SPEC_CONSTANTS,
  )
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &gpu.HDR_COLOR_ONLY_RENDERING_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &gpu.VERTEX_INPUT_NONE,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.DOUBLE_SIDED_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pColorBlendState    = &gpu.COLOR_BLENDING_OVERRIDE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = self.pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.pipeline,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  }
  log.info("Skybox pipeline initialized successfully")
  return .SUCCESS
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  self.pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}

record :: proc(
  self: ^Renderer,
  camera_handle: u32,
  command_buffer: vk.CommandBuffer,
  texture_manager: ^gpu.TextureManager,
  final_image_handle: gpu.Texture2DHandle,
  cameras_descriptor_set: vk.DescriptorSet,
  environment_index: u32,
  position_texture_idx: u32,
) {
  if environment_index == 0 do return
  color_texture := gpu.get_texture_2d(texture_manager, final_image_handle)
  gpu.begin_rendering(
    command_buffer,
    color_texture.spec.extent,
    nil,
    gpu.create_color_attachment(color_texture, .LOAD, .STORE),
  )
  gpu.set_viewport_scissor(
    command_buffer,
    color_texture.spec.extent,
    flip_y = false,
  )
  gpu.bind_graphics_pipeline(
    command_buffer,
    self.pipeline,
    self.pipeline_layout,
    cameras_descriptor_set,
    texture_manager.descriptor_set,
  )
  push := PushConstant {
    camera_index           = camera_handle,
    environment_index      = environment_index,
    position_texture_index = position_texture_idx,
    intensity              = self.intensity,
    lod                    = self.lod,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    {.FRAGMENT},
    0,
    size_of(PushConstant),
    &push,
  )
  vk.CmdDraw(command_buffer, 3, 1, 0, 0)
  vk.CmdEndRendering(command_buffer)
}
