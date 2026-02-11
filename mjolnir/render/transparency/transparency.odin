package transparency

import cont "../../containers"
import d "../data"
import "../../geometry"
import "../../gpu"
import "../camera"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

SHADER_TRANSPARENT_VERT :: #load("../../shader/transparent/vert.spv")
SHADER_TRANSPARENT_FRAG :: #load("../../shader/transparent/frag.spv")
SHADER_SPRITE_VERT := #load("../../shader/sprite/vert.spv")
SHADER_SPRITE_FRAG := #load("../../shader/sprite/frag.spv")
SHADER_WIREFRAME_VERT := #load("../../shader/wireframe/vert.spv")
SHADER_WIREFRAME_FRAG := #load("../../shader/wireframe/frag.spv")

Renderer :: struct {
  transparent_pipeline: vk.Pipeline,
  wireframe_pipeline:   vk.Pipeline,
  sprite_pipeline:      vk.Pipeline,
}

PushConstant :: struct {
  camera_index: u32,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  width, height: u32,
  general_pipeline_layout: vk.PipelineLayout,
  sprite_pipeline_layout: vk.PipelineLayout,
) -> (
  ret: vk.Result,
) {
  log.info("Initializing transparent renderer")
  if general_pipeline_layout == 0 {
    return .ERROR_INITIALIZATION_FAILED
  }
  create_transparent_pipelines(
    gctx,
    self,
    general_pipeline_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.transparent_pipeline, nil)
  }
  create_wireframe_pipelines(gctx, self, general_pipeline_layout) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.wireframe_pipeline, nil)
  }
  create_sprite_pipeline(gctx, self, sprite_pipeline_layout) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.sprite_pipeline, nil)
  }
  log.info("Transparent renderer initialized successfully")
  return .SUCCESS
}

create_transparent_pipelines :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  pipeline_layout: vk.PipelineLayout,
) -> vk.Result {
  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_TRANSPARENT_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_TRANSPARENT_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(geometry.VERTEX_BINDING_DESCRIPTION),
    pVertexBindingDescriptions      = raw_data(
      geometry.VERTEX_BINDING_DESCRIPTION[:],
    ),
    vertexAttributeDescriptionCount = len(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS,
    ),
    pVertexAttributeDescriptions    = raw_data(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
    ),
  }
  shader_stages := gpu.create_vert_frag_stages(
    vert_module,
    frag_module,
    &shared.SHADER_SPEC_CONSTANTS,
  )
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.STANDARD_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = pipeline_layout,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.transparent_pipeline,
  ) or_return
  return .SUCCESS
}

create_wireframe_pipelines :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  pipeline_layout: vk.PipelineLayout,
) -> vk.Result {
  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_WIREFRAME_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_WIREFRAME_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(geometry.VERTEX_BINDING_DESCRIPTION),
    pVertexBindingDescriptions      = raw_data(
      geometry.VERTEX_BINDING_DESCRIPTION[:],
    ),
    vertexAttributeDescriptionCount = len(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS,
    ),
    pVertexAttributeDescriptions    = raw_data(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
    ),
  }
  shader_stages := gpu.create_vert_frag_stages(vert_module, frag_module)
  create_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.LINE_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = pipeline_layout,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &create_info,
    nil,
    &self.wireframe_pipeline,
  ) or_return
  return .SUCCESS
}

create_sprite_pipeline :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  pipeline_layout: vk.PipelineLayout,
) -> vk.Result {
  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_SPRITE_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_SPRITE_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(geometry.VERTEX_BINDING_DESCRIPTION),
    pVertexBindingDescriptions      = raw_data(
      geometry.VERTEX_BINDING_DESCRIPTION[:],
    ),
    vertexAttributeDescriptionCount = len(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS,
    ),
    pVertexAttributeDescriptions    = raw_data(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
    ),
  }
  shader_stages := gpu.create_vert_frag_stages(vert_module, frag_module)
  create_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.DOUBLE_SIDED_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = pipeline_layout,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &create_info,
    nil,
    &self.sprite_pipeline,
  ) or_return
  log.info("Sprite pipeline created successfully")
  return .SUCCESS
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.transparent_pipeline, nil)
  self.transparent_pipeline = 0
  vk.DestroyPipeline(gctx.device, self.wireframe_pipeline, nil)
  self.wireframe_pipeline = 0
  vk.DestroyPipeline(gctx.device, self.sprite_pipeline, nil)
  self.sprite_pipeline = 0
}

begin_pass :: proc(
  self: ^Renderer,
  camera_gpu: ^camera.CameraGPU,
  camera_cpu: ^camera.Camera,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
) {
  color_texture := gpu.get_texture_2d(texture_manager,
    camera_gpu.attachments[.FINAL_IMAGE][frame_index],
  )
  if color_texture == nil {
    log.error("Transparent lighting missing color attachment")
    return
  }
  depth_texture := gpu.get_texture_2d(texture_manager,
    camera_gpu.attachments[.DEPTH][frame_index],
  )
  if depth_texture == nil {
    log.error("Transparent lighting missing depth attachment")
    return
  }
  gpu.begin_rendering(
    command_buffer,
    camera_cpu.extent[0],
    camera_cpu.extent[1],
    gpu.create_depth_attachment(depth_texture, .LOAD, .STORE),
    gpu.create_color_attachment(color_texture, .LOAD, .STORE),
  )
  gpu.set_viewport_scissor(command_buffer, camera_cpu.extent[0], camera_cpu.extent[1])
}

render :: proc(
  self: ^Renderer,
  camera_gpu: ^camera.CameraGPU,
  pipeline: vk.Pipeline,
  general_pipeline_layout: vk.PipelineLayout,
  sprite_pipeline_layout: vk.PipelineLayout,
  textures_descriptor_set: vk.DescriptorSet,
  bone_descriptor_set: vk.DescriptorSet,
  material_descriptor_set: vk.DescriptorSet,
  world_matrix_descriptor_set: vk.DescriptorSet,
  node_data_descriptor_set: vk.DescriptorSet,
  mesh_data_descriptor_set: vk.DescriptorSet,
  sprite_descriptor_set: vk.DescriptorSet,
  vertex_skinning_descriptor_set: vk.DescriptorSet,
  vertex_buffer: vk.Buffer,
  index_buffer: vk.Buffer,
  camera_handle: d.CameraHandle,
  frame_index: u32,
  command_buffer: vk.CommandBuffer,
  draw_buffer: vk.Buffer,
  count_buffer: vk.Buffer,
) {
  if draw_buffer == 0 || count_buffer == 0 {
    log.warn("Transparency render: draw_buffer or count_buffer is null")
    return
  }
  // Determine which pipeline layout to use
  pipeline_layout := pipeline == self.sprite_pipeline ? sprite_pipeline_layout : general_pipeline_layout

  if pipeline == self.sprite_pipeline {
    // Sprite pipeline: 5 descriptor sets (0, 1, 2, 3, 4)
    gpu.bind_graphics_pipeline(
      command_buffer,
      pipeline,
      pipeline_layout,
      camera_gpu.camera_buffer_descriptor_sets[frame_index], // Set 0
      textures_descriptor_set, // Set 1
      world_matrix_descriptor_set, // Set 2
      node_data_descriptor_set, // Set 3
      sprite_descriptor_set, // Set 4
    )
  } else {
    // General pipeline: 8 descriptor sets (0-7)
    gpu.bind_graphics_pipeline(
      command_buffer,
      pipeline,
      pipeline_layout,
      camera_gpu.camera_buffer_descriptor_sets[frame_index], // Set 0
      textures_descriptor_set, // Set 1
      bone_descriptor_set, // Set 2
      material_descriptor_set, // Set 3
      world_matrix_descriptor_set, // Set 4
      node_data_descriptor_set, // Set 5
      mesh_data_descriptor_set, // Set 6
      vertex_skinning_descriptor_set, // Set 7
    )
  }

  push_constants := PushConstant {
    camera_index = camera_handle.index,
  }
  vk.CmdPushConstants(
    command_buffer,
    pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(PushConstant),
    &push_constants,
  )
  vertex_buffers := [?]vk.Buffer{vertex_buffer}
  vertex_offsets := [?]vk.DeviceSize{0}
  vk.CmdBindVertexBuffers(
    command_buffer,
    0,
    1,
    raw_data(vertex_buffers[:]),
    raw_data(vertex_offsets[:]),
  )
  vk.CmdBindIndexBuffer(command_buffer, index_buffer, 0, .UINT32)
  vk.CmdDrawIndexedIndirectCount(
    command_buffer,
    draw_buffer,
    0,
    count_buffer,
    0,
    d.MAX_NODES_IN_SCENE,
    u32(size_of(vk.DrawIndexedIndirectCommand)),
  )
}

end_pass :: proc(self: ^Renderer, command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}
