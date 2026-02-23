package ambient

import "../../gpu"
import "../camera"
import d "../data"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

SHADER_VERT :: #load("../../shader/lighting_ambient/vert.spv")
SHADER_FRAG :: #load("../../shader/lighting_ambient/frag.spv")
TEXTURE_LUT_GGX :: #load("../../assets/lut_ggx.png")

PushConstant :: struct {
  camera_index:           u32,
  environment_index:      u32,
  brdf_lut_index:         u32,
  position_texture_index: u32,
  normal_texture_index:   u32,
  albedo_texture_index:   u32,
  metallic_texture_index: u32,
  emissive_texture_index: u32,
  environment_max_lod:    f32,
  ibl_intensity:          f32,
}

Renderer :: struct {
  pipeline:            vk.Pipeline,
  pipeline_layout:     vk.PipelineLayout,
  environment_map:     gpu.Texture2DHandle,
  brdf_lut:            gpu.Texture2DHandle,
  environment_max_lod: f32,
  ibl_intensity:       f32,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  camera_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  log.debug("Ambient lighting renderer init")
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
  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  shader_stages := gpu.create_vert_frag_stages(
    vert_module,
    frag_module,
    &shared.SHADER_SPEC_CONSTANTS,
  )
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &gpu.COLOR_ONLY_RENDERING_INFO,
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
  log.info("Ambient lighting pipeline initialized successfully")
  return .SUCCESS
}

setup :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) -> (
  ret: vk.Result,
) {
  env_map, env_result := gpu.create_texture_2d_from_path(
    gctx,
    texture_manager,
    "assets/Cannon_Exterior.hdr",
    .R32G32B32A32_SFLOAT,
    true,
    {.SAMPLED},
    true,
  )
  if env_result == .SUCCESS {
    self.environment_map = env_map
  } else {
    log.warn("HDR environment map not found, using default ambient lighting")
    self.environment_map = {}
  }
  defer if ret != .SUCCESS {
    gpu.free_texture_2d(texture_manager, gctx, self.environment_map)
  }
  environment_map := gpu.get_texture_2d(texture_manager, self.environment_map)
  if environment_map != nil {
    self.environment_max_lod =
      f32(
        gpu.calculate_mip_levels(
          environment_map.spec.width,
          environment_map.spec.height,
        ),
      ) -
      1.0
  } else {
    self.environment_max_lod = 0.0
  }
  brdf_handle := gpu.create_texture_2d_from_data(
    gctx,
    texture_manager,
    TEXTURE_LUT_GGX,
  ) or_return
  defer if ret != .SUCCESS {
    gpu.free_texture_2d(texture_manager, gctx, brdf_handle)
  }
  self.brdf_lut = brdf_handle
  self.ibl_intensity = 1.0
  log.info("Ambient lighting GPU resources setup")
  return .SUCCESS
}

teardown :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) {
  gpu.free_texture_2d(texture_manager, gctx, self.environment_map)
  self.environment_map = {}
  gpu.free_texture_2d(texture_manager, gctx, self.brdf_lut)
  self.brdf_lut = {}
}

shutdown :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  self.pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}

begin_pass :: proc(
  self: ^Renderer,
  camera: ^camera.Camera,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
  cameras_descriptor_set: vk.DescriptorSet,
  frame_index: u32,
) {
  color_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.FINAL_IMAGE][frame_index],
  )
  gpu.begin_rendering(
    command_buffer,
    color_texture.spec.extent,
    nil,
    gpu.create_color_attachment(color_texture),
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
    cameras_descriptor_set, // set = 0 (per-frame camera buffer)
    texture_manager.descriptor_set, // set = 1 (bindless textures)
  )
}

render :: proc(
  self: ^Renderer,
  camera_handle: u32,
  camera: ^camera.Camera,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
) {
  push := PushConstant {
    camera_index           = camera_handle,
    environment_index      = self.environment_map.index,
    brdf_lut_index         = self.brdf_lut.index,
    position_texture_index = camera.attachments[.POSITION][frame_index].index,
    normal_texture_index   = camera.attachments[.NORMAL][frame_index].index,
    albedo_texture_index   = camera.attachments[.ALBEDO][frame_index].index,
    metallic_texture_index = camera.attachments[.METALLIC_ROUGHNESS][frame_index].index,
    emissive_texture_index = camera.attachments[.EMISSIVE][frame_index].index,
    environment_max_lod    = self.environment_max_lod,
    ibl_intensity          = self.ibl_intensity,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    {.FRAGMENT},
    0,
    size_of(PushConstant),
    &push,
  )
  vk.CmdDraw(command_buffer, 3, 1, 0, 0) // fullscreen triangle
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}
