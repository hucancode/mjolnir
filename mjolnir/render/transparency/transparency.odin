package transparency

import "../../geometry"
import "../../gpu"
import "../../resources"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

Renderer :: struct {
  transparent_pipeline: vk.Pipeline,
  wireframe_pipeline:   vk.Pipeline,
  sprite_pipeline:      vk.Pipeline,
  sprite_quad_mesh:     resources.Handle,
  commands:             [resources.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
}

PushConstant :: struct {
  camera_index: u32,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  width, height: u32,
  rm: ^resources.Manager,
) -> vk.Result {
  vk.AllocateCommandBuffers(
    gctx.device,
    &vk.CommandBufferAllocateInfo {
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = gctx.command_pool,
      level = .SECONDARY,
      commandBufferCount = u32(len(self.commands)),
    },
    raw_data(self.commands[:]),
  ) or_return
  log.info("Initializing transparent renderer")
  if rm.geometry_pipeline_layout == 0 {
    return .ERROR_INITIALIZATION_FAILED
  }
  half_w: f32 = 0.5
  half_h: f32 = 0.5
  vertices := make([]geometry.Vertex, 4)
  vertices[0] = {
    position = {-half_w, -half_h, 0},
    normal   = {0, 0, 1},
    uv       = {0, 1},
    color    = {1, 1, 1, 1},
  }
  vertices[1] = {
    position = {half_w, -half_h, 0},
    normal   = {0, 0, 1},
    uv       = {1, 1},
    color    = {1, 1, 1, 1},
  }
  vertices[2] = {
    position = {half_w, half_h, 0},
    normal   = {0, 0, 1},
    uv       = {1, 0},
    color    = {1, 1, 1, 1},
  }
  vertices[3] = {
    position = {-half_w, half_h, 0},
    normal   = {0, 0, 1},
    uv       = {0, 0},
    color    = {1, 1, 1, 1},
  }
  indices := make([]u32, 6)
  indices[0] = 0
  indices[1] = 1
  indices[2] = 2
  indices[3] = 2
  indices[4] = 3
  indices[5] = 0
  quad_geom := geometry.Geometry {
    vertices = vertices,
    indices  = indices,
    aabb     = geometry.aabb_from_vertices(vertices),
  }
  mesh_handle, mesh_ptr, mesh_result := resources.create_mesh(
    gctx,
    rm,
    quad_geom,
  )
  if mesh_result != .SUCCESS {
    log.errorf("Failed to create sprite quad mesh: %v", mesh_result)
    return .ERROR_INITIALIZATION_FAILED
  }
  self.sprite_quad_mesh = mesh_handle
  log.infof(
    "Created sprite quad mesh with handle index=%d, index_count=%d, AABB=[%.2f,%.2f,%.2f]-[%.2f,%.2f,%.2f]",
    mesh_handle.index,
    mesh_ptr.index_count,
    mesh_ptr.aabb_min.x,
    mesh_ptr.aabb_min.y,
    mesh_ptr.aabb_min.z,
    mesh_ptr.aabb_max.x,
    mesh_ptr.aabb_max.y,
    mesh_ptr.aabb_max.z,
  )
  create_transparent_pipelines(
    gctx,
    self,
    rm.geometry_pipeline_layout,
  ) or_return
  create_wireframe_pipelines(gctx, self, rm.geometry_pipeline_layout) or_return
  create_sprite_pipeline(gctx, self, rm.geometry_pipeline_layout) or_return
  log.info("Transparent renderer initialized successfully")
  return .SUCCESS
}

create_transparent_pipelines :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  pipeline_layout: vk.PipelineLayout,
) -> vk.Result {
  depth_format: vk.Format = .D32_SFLOAT
  color_format: vk.Format = .B8G8R8A8_SRGB
  vert_shader_code := #load("../../shader/transparent/vert.spv")
  vert_module := gpu.create_shader_module(
    gctx.device,
    vert_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_shader_code := #load("../../shader/transparent/frag.spv")
  frag_module := gpu.create_shader_module(
    gctx.device,
    frag_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  spec_data, spec_entries, spec_info := shared.make_shader_spec_constants()
  spec_info.pData = cast(rawptr)&spec_data
  defer delete(spec_entries)
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
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
  }
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = .FILL,
    cullMode    = {.BACK}, // No culling for transparent objects
    frontFace   = .COUNTER_CLOCKWISE,
    lineWidth   = 1.0,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = false, // Don't write to depth buffer for transparent objects
    depthCompareOp   = .LESS_OR_EQUAL,
  }
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    blendEnable         = true,
    srcColorBlendFactor = .SRC_ALPHA,
    dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
    colorBlendOp        = .ADD,
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
    alphaBlendOp        = .ADD,
    colorWriteMask      = {.R, .G, .B, .A},
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = 1,
    pColorAttachmentFormats = &color_format,
    depthAttachmentFormat   = depth_format,
  }
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_module,
      pName = "main",
      pSpecializationInfo = &spec_info,
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_module,
      pName = "main",
      pSpecializationInfo = &spec_info,
    },
  }
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pDepthStencilState  = &depth_stencil,
    pColorBlendState    = &color_blending,
    pDynamicState       = &dynamic_state,
    layout              = pipeline_layout,
    pNext               = &rendering_info,
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
  depth_format: vk.Format = .D32_SFLOAT
  color_format: vk.Format = .B8G8R8A8_SRGB
  vert_shader_code := #load("../../shader/wireframe/vert.spv")
  vert_module := gpu.create_shader_module(
    gctx.device,
    vert_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_shader_code := #load("../../shader/wireframe/frag.spv")
  frag_module := gpu.create_shader_module(
    gctx.device,
    frag_shader_code,
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
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
  }
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = .LINE,
    cullMode    = {.BACK},
    frontFace   = .COUNTER_CLOCKWISE,
    lineWidth   = 1.0,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = false,
    depthCompareOp   = .LESS_OR_EQUAL,
  }
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    colorWriteMask      = {.R, .G, .B, .A},
    blendEnable         = true,
    srcColorBlendFactor = .SRC_ALPHA,
    dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
    colorBlendOp        = .ADD,
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ZERO,
    alphaBlendOp        = .ADD,
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = 1,
    pColorAttachmentFormats = &color_format,
    depthAttachmentFormat   = depth_format,
  }
  shader_stages := [2]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_module,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_module,
      pName = "main",
    },
  }
  create_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pDepthStencilState  = &depth_stencil,
    pColorBlendState    = &color_blending,
    pDynamicState       = &dynamic_state,
    layout              = pipeline_layout,
    pNext               = &rendering_info,
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
  depth_format: vk.Format = .D32_SFLOAT
  color_format: vk.Format = .B8G8R8A8_SRGB
  vert_shader_code := #load("../../shader/sprite/vert.spv")
  vert_module := gpu.create_shader_module(
    gctx.device,
    vert_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_shader_code := #load("../../shader/sprite/frag.spv")
  frag_module := gpu.create_shader_module(
    gctx.device,
    frag_shader_code,
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
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
  }
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = .FILL,
    cullMode    = {},
    frontFace   = .COUNTER_CLOCKWISE,
    lineWidth   = 1.0,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = false,
    depthCompareOp   = .LESS_OR_EQUAL,
  }
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    blendEnable         = true,
    srcColorBlendFactor = .SRC_ALPHA,
    dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
    colorBlendOp        = .ADD,
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
    alphaBlendOp        = .ADD,
    colorWriteMask      = {.R, .G, .B, .A},
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = 1,
    pColorAttachmentFormats = &color_format,
    depthAttachmentFormat   = depth_format,
  }
  shader_stages := [2]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_module,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_module,
      pName = "main",
    },
  }
  create_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pDepthStencilState  = &depth_stencil,
    pColorBlendState    = &color_blending,
    pDynamicState       = &dynamic_state,
    layout              = pipeline_layout,
    pNext               = &rendering_info,
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

shutdown :: proc(
  self: ^Renderer,
  device: vk.Device,
  command_pool: vk.CommandPool,
) {
  vk.FreeCommandBuffers(device, command_pool, u32(len(self.commands)), raw_data(self.commands[:]))
  vk.DestroyPipeline(device, self.transparent_pipeline, nil)
  self.transparent_pipeline = 0
  vk.DestroyPipeline(device, self.wireframe_pipeline, nil)
  self.wireframe_pipeline = 0
  vk.DestroyPipeline(device, self.sprite_pipeline, nil)
  self.sprite_pipeline = 0
}

begin_pass :: proc(
  self: ^Renderer,
  camera_handle: resources.Handle,
  command_buffer: vk.CommandBuffer,
  rm: ^resources.Manager,
  frame_index: u32,
) {
  camera := resources.get(rm.cameras, camera_handle)
  if camera == nil do return
  color_texture := resources.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .FINAL_IMAGE, frame_index),
  )
  if color_texture == nil {
    log.error("Transparent lighting missing color attachment")
    return
  }
  depth_texture := resources.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .DEPTH, frame_index),
  )
  if depth_texture == nil {
    log.error("Transparent lighting missing depth attachment")
    return
  }
  color_attachment := vk.RenderingAttachmentInfo {
    sType       = .RENDERING_ATTACHMENT_INFO,
    imageView   = color_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }
  depth_attachment := vk.RenderingAttachmentInfo {
    sType       = .RENDERING_ATTACHMENT_INFO,
    imageView   = depth_texture.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }
  extent := camera.extent
  render_info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {extent = extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRendering(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0,
    y        = f32(extent.height),
    width    = f32(extent.width),
    height   = -f32(extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

render :: proc(
  self: ^Renderer,
  pipeline: vk.Pipeline,
  camera_handle: resources.Handle,
  command_buffer: vk.CommandBuffer,
  rm: ^resources.Manager,
  frame_index: u32,
  draw_buffer: vk.Buffer,
  count_buffer: vk.Buffer,
  command_stride: u32,
) {
  if draw_buffer == 0 || count_buffer == 0 {
    log.warn("Transparency render: draw_buffer or count_buffer is null")
    return
  }
  descriptor_sets := [?]vk.DescriptorSet {
    rm.camera_buffer_descriptor_set,
    rm.textures_descriptor_set,
    rm.bone_buffer_descriptor_set,
    rm.material_buffer_descriptor_set,
    rm.world_matrix_descriptor_set,
    rm.node_data_descriptor_set,
    rm.mesh_data_descriptor_set,
    rm.vertex_skinning_descriptor_set,
    rm.lights_buffer_descriptor_set,
    rm.sprite_buffer_descriptor_set,
  }
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    rm.geometry_pipeline_layout,
    0,
    len(descriptor_sets),
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline)
  push_constants := PushConstant {
    camera_index = camera_handle.index,
  }
  vk.CmdPushConstants(
    command_buffer,
    rm.geometry_pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(PushConstant),
    &push_constants,
  )
  vertex_buffers := [1]vk.Buffer{rm.vertex_buffer.buffer}
  vertex_offsets := [1]vk.DeviceSize{0}
  vk.CmdBindVertexBuffers(
    command_buffer,
    0,
    1,
    raw_data(vertex_buffers[:]),
    raw_data(vertex_offsets[:]),
  )
  vk.CmdBindIndexBuffer(command_buffer, rm.index_buffer.buffer, 0, .UINT32)
  vk.CmdDrawIndexedIndirectCount(
    command_buffer,
    draw_buffer,
    0,
    count_buffer,
    0,
    resources.MAX_NODES_IN_SCENE,
    command_stride,
  )
}

begin_record :: proc(
  self: ^Renderer,
  frame_index: u32,
  camera_handle: resources.Handle,
  rm: ^resources.Manager,
  color_format: vk.Format,
) -> (
  command_buffer: vk.CommandBuffer,
  ret: vk.Result,
) {
  camera := resources.get(rm.cameras, camera_handle)
  if camera == nil {
    ret = .ERROR_UNKNOWN
    return
  }
  command_buffer = camera.transparency_commands[frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  color_formats := [1]vk.Format{color_format}
  rendering_info := vk.CommandBufferInheritanceRenderingInfo {
    sType                   = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    colorAttachmentCount    = 1,
    pColorAttachmentFormats = &color_formats[0],
    depthAttachmentFormat   = .D32_SFLOAT,
  }
  inheritance := vk.CommandBufferInheritanceInfo {
    sType = .COMMAND_BUFFER_INHERITANCE_INFO,
    pNext = &rendering_info,
  }
  vk.BeginCommandBuffer(
    command_buffer,
    &vk.CommandBufferBeginInfo {
      sType = .COMMAND_BUFFER_BEGIN_INFO,
      flags = {.ONE_TIME_SUBMIT},
      pInheritanceInfo = &inheritance,
    },
  ) or_return
  return command_buffer, .SUCCESS
}

end_record :: proc(command_buffer: vk.CommandBuffer) -> vk.Result {
  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}

end_pass :: proc(self: ^Renderer, command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}
