package transparency

import cont "../../containers"
import "../../geometry"
import "../../gpu"
import "../../resources"
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
  sprite_quad_mesh:     resources.Handle,
}

PushConstant :: struct {
  camera_index: u32,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  width, height: u32,
  rm: ^resources.Manager,
) -> (
  ret: vk.Result,
) {
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
  mesh_handle, mesh_ptr := resources.create_mesh(gctx, rm, quad_geom) or_return
  defer if ret != .SUCCESS {
    resources.mesh_destroy_handle(gctx.device, rm, mesh_handle)
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
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.transparent_pipeline, nil)
  }
  create_wireframe_pipelines(gctx, self, rm.geometry_pipeline_layout) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.wireframe_pipeline, nil)
  }
  create_sprite_pipeline(gctx, self, rm.geometry_pipeline_layout) or_return
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
  depth_format: vk.Format = .D32_SFLOAT
  color_format: vk.Format = .B8G8R8A8_SRGB
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
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_module,
      pName = "main",
      pSpecializationInfo = &shared.SHADER_SPEC_CONSTANTS,
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_module,
      pName = "main",
      pSpecializationInfo = &shared.SHADER_SPEC_CONSTANTS,
    },
  }
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
  depth_format: vk.Format = .D32_SFLOAT
  color_format: vk.Format = .B8G8R8A8_SRGB
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
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
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
  depth_format: vk.Format = .D32_SFLOAT
  color_format: vk.Format = .B8G8R8A8_SRGB
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
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
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
  camera_handle: resources.Handle,
  command_buffer: vk.CommandBuffer,
  rm: ^resources.Manager,
  frame_index: u32,
) {
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil do return
  color_texture := cont.get(
    rm.images_2d,
    camera.attachments[.FINAL_IMAGE][frame_index],
  )
  if color_texture == nil {
    log.error("Transparent lighting missing color attachment")
    return
  }
  depth_texture := cont.get(
    rm.images_2d,
    camera.attachments[.DEPTH][frame_index],
  )
  if depth_texture == nil {
    log.error("Transparent lighting missing depth attachment")
    return
  }
  extent := camera.extent
  gpu.begin_rendering(
    command_buffer,
    extent.width,
    extent.height,
    gpu.create_depth_attachment(depth_texture, .LOAD, .STORE),
    gpu.create_color_attachment(color_texture, .LOAD, .STORE),
  )
  gpu.set_viewport_scissor(command_buffer, extent.width, extent.height)
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
  gpu.bind_graphics_pipeline(
    command_buffer,
    pipeline,
    rm.geometry_pipeline_layout,
    rm.camera_buffer.descriptor_sets[frame_index], // Per-frame to avoid overlap
    rm.textures_descriptor_set,
    rm.bone_buffer.descriptor_set,
    rm.material_buffer.descriptor_set,
    rm.world_matrix_buffer.descriptor_set,
    rm.node_data_buffer.descriptor_set,
    rm.mesh_data_buffer.descriptor_set,
    rm.vertex_skinning_descriptor_set,
    rm.lights_buffer.descriptor_set,
    rm.sprite_buffer.descriptor_set,
  )
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
  vertex_buffers := [?]vk.Buffer{rm.vertex_buffer.buffer}
  vertex_offsets := [?]vk.DeviceSize{0}
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

// No longer needed - recording directly to primary command buffer

end_pass :: proc(self: ^Renderer, command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}
