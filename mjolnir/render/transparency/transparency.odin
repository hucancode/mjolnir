package transparency

import cont "../../containers"
import "../../geometry"
import "../../gpu"
import "../camera"
import rctx "../context"
import d "../data"
import "core:log"
import vk "vendor:vulkan"

SHADER_TRANSPARENT_VERT :: #load("../../shader/transparent/vert.spv")
SHADER_TRANSPARENT_FRAG :: #load("../../shader/transparent/frag.spv")
SHADER_SPRITE_VERT := #load("../../shader/sprite/vert.spv")
SHADER_SPRITE_FRAG := #load("../../shader/sprite/frag.spv")
SHADER_WIREFRAME_VERT := #load("../../shader/wireframe/vert.spv")
SHADER_WIREFRAME_FRAG := #load("../../shader/wireframe/frag.spv")
SHADER_RANDOM_COLOR_VERT := #load("../../shader/random_color/vert.spv")
SHADER_RANDOM_COLOR_FRAG := #load("../../shader/random_color/frag.spv")
SHADER_LINE_STRIP_VERT := #load("../../shader/line_strip/vert.spv")
SHADER_LINE_STRIP_FRAG := #load("../../shader/line_strip/frag.spv")

Renderer :: struct {
  general_pipeline_layout: vk.PipelineLayout,
  sprite_pipeline_layout:  vk.PipelineLayout,
  line_strip_pipeline:   vk.Pipeline,
  random_color_pipeline: vk.Pipeline,
  transparent_pipeline:  vk.Pipeline,
  wireframe_pipeline:    vk.Pipeline,
  sprite_pipeline:       vk.Pipeline,
}

PushConstant :: struct {
  camera_index: u32,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  width, height: u32,
  camera_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
  bone_set_layout: vk.DescriptorSetLayout,
  material_set_layout: vk.DescriptorSetLayout,
  node_data_set_layout: vk.DescriptorSetLayout,
  mesh_data_set_layout: vk.DescriptorSetLayout,
  sprite_set_layout: vk.DescriptorSetLayout,
  vertex_skinning_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  log.info("Initializing transparent renderer")
  self.general_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(u32),
    },
    camera_set_layout,
    textures_set_layout,
    bone_set_layout,
    material_set_layout,
    node_data_set_layout,
    mesh_data_set_layout,
    vertex_skinning_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.general_pipeline_layout, nil)
    self.general_pipeline_layout = 0
  }
  self.sprite_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(u32),
    },
    camera_set_layout,
    textures_set_layout,
    node_data_set_layout,
    sprite_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.sprite_pipeline_layout, nil)
    self.sprite_pipeline_layout = 0
  }
  if self.general_pipeline_layout == 0 || self.sprite_pipeline_layout == 0 {
    return .ERROR_INITIALIZATION_FAILED
  }
  create_transparent_pipelines(gctx, self, self.general_pipeline_layout) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.transparent_pipeline, nil)
  }
  create_wireframe_pipelines(gctx, self, self.general_pipeline_layout) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.wireframe_pipeline, nil)
  }
  create_random_color_pipeline(gctx, self, self.general_pipeline_layout) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.random_color_pipeline, nil)
  }
  create_line_strip_pipeline(gctx, self, self.general_pipeline_layout) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.line_strip_pipeline, nil)
  }
  create_sprite_pipeline(gctx, self, self.sprite_pipeline_layout) or_return
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
    &rctx.SHADER_SPEC_CONSTANTS,
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

create_random_color_pipeline :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  pipeline_layout: vk.PipelineLayout,
) -> vk.Result {
  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_RANDOM_COLOR_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_RANDOM_COLOR_FRAG,
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
    &create_info,
    nil,
    &self.random_color_pipeline,
  ) or_return
  return .SUCCESS
}

create_line_strip_pipeline :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  pipeline_layout: vk.PipelineLayout,
) -> vk.Result {
  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_LINE_STRIP_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_LINE_STRIP_FRAG,
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
    pInputAssemblyState = &gpu.LINE_INPUT_ASSEMBLY,
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
    &self.line_strip_pipeline,
  ) or_return
  return .SUCCESS
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.transparent_pipeline, nil)
  self.transparent_pipeline = 0
  vk.DestroyPipeline(gctx.device, self.wireframe_pipeline, nil)
  self.wireframe_pipeline = 0
  vk.DestroyPipeline(gctx.device, self.random_color_pipeline, nil)
  self.random_color_pipeline = 0
  vk.DestroyPipeline(gctx.device, self.line_strip_pipeline, nil)
  self.line_strip_pipeline = 0
  vk.DestroyPipeline(gctx.device, self.sprite_pipeline, nil)
  self.sprite_pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.general_pipeline_layout, nil)
  self.general_pipeline_layout = 0
  vk.DestroyPipelineLayout(gctx.device, self.sprite_pipeline_layout, nil)
  self.sprite_pipeline_layout = 0
}

begin_pass :: proc(
  self: ^Renderer,
  camera: ^camera.CameraResources,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
) {
  color_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.FINAL_IMAGE][frame_index],
  )
  if color_texture == nil {
    log.error("Transparent lighting missing color attachment")
    return
  }
  depth_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.DEPTH][frame_index],
  )
  if depth_texture == nil {
    log.error("Transparent lighting missing depth attachment")
    return
  }
  gpu.begin_rendering(
    command_buffer,
    depth_texture.spec.extent,
    gpu.create_depth_attachment(depth_texture, .LOAD, .STORE),
    gpu.create_color_attachment(color_texture, .LOAD, .STORE),
  )
  gpu.set_viewport_scissor(
    command_buffer,
    depth_texture.spec.extent,
  )
}

render :: proc(
  self: ^Renderer,
  ctx: ^rctx.RenderContext,
  cmd: vk.CommandBuffer,
  pipeline: vk.Pipeline,
  camera_index: u32,
  draw_commands: vk.Buffer,
  draw_count: vk.Buffer,
) {
  if draw_commands == 0 || draw_count == 0 {
    log.warn("Transparency render: draw_commands or draw_count is null")
    return
  }
  // Determine which pipeline layout to use
  pipeline_layout :=
    pipeline == self.sprite_pipeline ? self.sprite_pipeline_layout : self.general_pipeline_layout

  if pipeline == self.sprite_pipeline {
    // Sprite pipeline: 4 descriptor sets (0, 1, 2, 3)
    gpu.bind_graphics_pipeline(
      cmd,
      pipeline,
      pipeline_layout,
      ctx.cameras_descriptor_set, // Set 0
      ctx.textures_descriptor_set, // Set 1
      ctx.node_data_descriptor_set, // Set 2
      ctx.sprite_buffer_descriptor_set, // Set 3
    )
  } else {
    // General pipeline: 7 descriptor sets (0-6)
    gpu.bind_graphics_pipeline(
      cmd,
      pipeline,
      pipeline_layout,
      ctx.cameras_descriptor_set, // Set 0
      ctx.textures_descriptor_set, // Set 1
      ctx.bone_descriptor_set, // Set 2
      ctx.material_descriptor_set, // Set 3
      ctx.node_data_descriptor_set, // Set 4
      ctx.mesh_data_descriptor_set, // Set 5
      ctx.vertex_skinning_descriptor_set, // Set 6
    )
  }

  push_constants := PushConstant {
    camera_index = camera_index,
  }
  vk.CmdPushConstants(
    cmd,
    pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(PushConstant),
    &push_constants,
  )
  vertex_buffers := [?]vk.Buffer{ctx.vertex_buffer}
  vertex_offsets := [?]vk.DeviceSize{0}
  vk.CmdBindVertexBuffers(
    cmd,
    0,
    1,
    raw_data(vertex_buffers[:]),
    raw_data(vertex_offsets[:]),
  )
  vk.CmdBindIndexBuffer(cmd, ctx.index_buffer, 0, .UINT32)
  vk.CmdDrawIndexedIndirectCount(
    cmd,
    draw_commands,
    0,
    draw_count,
    0,
    d.MAX_NODES_IN_SCENE,
    u32(size_of(vk.DrawIndexedIndirectCommand)),
  )
}

end_pass :: proc(self: ^Renderer, command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}
