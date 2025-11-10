package navigation_renderer

import cont "../../containers"
import "../../gpu"
import "../../resources"
import "core:log"
import "core:math"
import vk "vendor:vulkan"

SHADER_NAVMESH_VERT :: #load("../../shader/navmesh/vert.spv")
SHADER_NAVMESH_FRAG :: #load("../../shader/navmesh/frag.spv")

Renderer :: struct {
  pipeline_layout:    vk.PipelineLayout,
  pipeline:           vk.Pipeline,
  line_pipeline:      vk.Pipeline,
  vertex_buffer:      gpu.MutableBuffer(Vertex),
  index_buffer:       gpu.MutableBuffer(u32),
  vertex_count:       u32,
  index_count:        u32,
  enabled:            bool,
  color_mode:         ColorMode,
  commands:           [resources.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  path_vertex_buffer: gpu.MutableBuffer(Vertex),
  path_vertex_count:  u32,
  path_enabled:       bool,
  debug_mode:         bool,
  alpha:              f32,
  height_offset:      f32,
  base_color:         [3]f32,
}

Vertex :: struct {
  position: [3]f32,
  color:    [4]f32,
}

ColorMode :: enum u32 {
  Area_Colors   = 0,
  Uniform       = 1,
  Height_Based  = 2,
  Random_Colors = 3,
  Region_Colors = 4,
}

PushConstants :: struct {
  world:         matrix[4, 4]f32,
  camera_index:  u32,
  height_offset: f32,
  alpha:         f32,
  color_mode:    u32,
}

init :: proc(
  renderer: ^Renderer,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) -> vk.Result {
  renderer.enabled = true
  renderer.color_mode = .Random_Colors
  renderer.debug_mode = false
  renderer.alpha = 0.6
  renderer.height_offset = 0.05
  renderer.base_color = {0.0, 0.8, 0.2}
  renderer.path_enabled = false
  vk.AllocateCommandBuffers(
    gctx.device,
    &vk.CommandBufferAllocateInfo {
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = gctx.command_pool,
      level = .SECONDARY,
      commandBufferCount = u32(len(renderer.commands)),
    },
    raw_data(renderer.commands[:]),
  ) or_return
  create_pipeline(renderer, gctx, rm) or_return
  renderer.vertex_buffer = gpu.create_mutable_buffer(
    gctx,
    Vertex,
    16384,
    {.VERTEX_BUFFER},
  ) or_return
  renderer.index_buffer = gpu.create_mutable_buffer(
    gctx,
    u32,
    32768,
    {.INDEX_BUFFER},
  ) or_return
  renderer.path_vertex_buffer = gpu.create_mutable_buffer(
    gctx,
    Vertex,
    1024,
    {.VERTEX_BUFFER},
  ) or_return
  return .SUCCESS
}

shutdown :: proc(
  self: ^Renderer,
  device: vk.Device,
  command_pool: vk.CommandPool,
) {
  vk.DestroyPipeline(device, self.pipeline, nil)
  vk.DestroyPipeline(device, self.line_pipeline, nil)
  vk.DestroyPipelineLayout(device, self.pipeline_layout, nil)
  gpu.mutable_buffer_destroy(device, &self.vertex_buffer)
  gpu.mutable_buffer_destroy(device, &self.index_buffer)
  gpu.mutable_buffer_destroy(device, &self.path_vertex_buffer)
  vk.FreeCommandBuffers(
    device,
    command_pool,
    u32(len(self.commands)),
    raw_data(self.commands[:]),
  )
}

begin_record :: proc(
  self: ^Renderer,
  frame_index: u32,
  color_format: vk.Format,
) -> (
  command_buffer: vk.CommandBuffer,
  result: vk.Result,
) {
  command_buffer = self.commands[frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  vk.BeginCommandBuffer(
    command_buffer,
    &{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
  ) or_return
  result = .SUCCESS
  return
}

end_record :: proc(command_buffer: vk.CommandBuffer) -> vk.Result {
  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
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
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .FINAL_IMAGE, frame_index),
  )
  depth_texture := cont.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .DEPTH, frame_index),
  )
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
    width    = f32(extent.width),
    height   = f32(extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

render :: proc(
  renderer: ^Renderer,
  command_buffer: vk.CommandBuffer,
  world_matrix: matrix[4, 4]f32,
  camera_index: u32,
  rm: ^resources.Manager,
  frame_index: u32 = 0,
) {
  if !renderer.enabled do return
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, renderer.pipeline)
  descriptor_sets := [?]vk.DescriptorSet {
    rm.camera_buffer_descriptor_sets[frame_index],
  }
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    renderer.pipeline_layout,
    0,
    len(descriptor_sets),
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )
  if renderer.vertex_count > 0 && renderer.index_count > 0 {
    vertex_buffers := []vk.Buffer{renderer.vertex_buffer.buffer}
    offsets := []vk.DeviceSize{0}
    vk.CmdBindVertexBuffers(
      command_buffer,
      0,
      1,
      raw_data(vertex_buffers),
      raw_data(offsets),
    )
    vk.CmdBindIndexBuffer(
      command_buffer,
      renderer.index_buffer.buffer,
      0,
      .UINT32,
    )
    push_constants := PushConstants {
      world         = world_matrix,
      camera_index  = camera_index,
      height_offset = renderer.height_offset,
      alpha         = renderer.alpha,
      color_mode    = u32(renderer.color_mode),
    }
    vk.CmdPushConstants(
      command_buffer,
      renderer.pipeline_layout,
      {.VERTEX, .FRAGMENT},
      0,
      size_of(PushConstants),
      &push_constants,
    )
    vk.CmdDrawIndexed(command_buffer, renderer.index_count, 1, 0, 0, 0)
  }
  if renderer.path_enabled && renderer.path_vertex_count > 0 {
    vk.CmdBindPipeline(command_buffer, .GRAPHICS, renderer.line_pipeline)
    vk.CmdBindDescriptorSets(
      command_buffer,
      .GRAPHICS,
      renderer.pipeline_layout,
      0,
      len(descriptor_sets),
      raw_data(descriptor_sets[:]),
      0,
      nil,
    )
    path_buffers := []vk.Buffer{renderer.path_vertex_buffer.buffer}
    offsets := []vk.DeviceSize{0}
    vk.CmdBindVertexBuffers(
      command_buffer,
      0,
      1,
      raw_data(path_buffers),
      raw_data(offsets),
    )
    path_push_constants := PushConstants {
      world         = world_matrix,
      camera_index  = camera_index,
      height_offset = renderer.height_offset + 0.01,
      alpha         = 1.0,
      color_mode    = u32(ColorMode.Uniform),
    }
    vk.CmdPushConstants(
      command_buffer,
      renderer.pipeline_layout,
      {.VERTEX, .FRAGMENT},
      0,
      size_of(PushConstants),
      &path_push_constants,
    )
    vk.CmdDraw(command_buffer, renderer.path_vertex_count, 1, 0, 0)
  }
}

load_navmesh_data :: proc(
  renderer: ^Renderer,
  vertices: []Vertex,
  indices: []u32,
) -> bool {
  renderer.vertex_count = u32(len(vertices))
  renderer.index_count = u32(len(indices))
  if renderer.vertex_count == 0 || renderer.index_count == 0 {
    return true
  }
  if renderer.vertex_count > 16384 || renderer.index_count > 32768 {
    log.errorf(
      "Navigation mesh too large: %d vertices, %d indices",
      renderer.vertex_count,
      renderer.index_count,
    )
    return false
  }
  vertex_result := gpu.write(&renderer.vertex_buffer, vertices)
  if vertex_result != .SUCCESS {
    return false
  }
  index_result := gpu.write(&renderer.index_buffer, indices)
  if index_result != .SUCCESS {
    return false
  }
  return true
}

regenerate_colors :: proc(renderer: ^Renderer, poly_count: u32) {
  if renderer.vertex_count == 0 do return
  vertices := make([]Vertex, renderer.vertex_count, context.temp_allocator)
  // Note: Since GPU read is not available, we'll need to store vertex data or regenerate
  // For now, just regenerate colors based on positions
  // Generate colors based on mode
  switch renderer.color_mode {
  case .Area_Colors:
    for &vertex in vertices {
      vertex.color = {0.0, 0.8, 0.2, 0.6} // Default green
    }
  case .Uniform:
    for &vertex in vertices {
      vertex.color = {0.2, 0.6, 0.8, 0.6} // Blue
    }
  case .Height_Based:
    min_y := vertices[0].position.y
    max_y := vertices[0].position.y
    for vertex in vertices {
      min_y = min(min_y, vertex.position.y)
      max_y = max(max_y, vertex.position.y)
    }
    height_range := max_y - min_y
    if height_range > 0 {
      for &vertex in vertices {
        height_factor := (vertex.position.y - min_y) / height_range
        vertex.color = {height_factor, 1.0 - height_factor, 0.5, 0.6}
      }
    }
  case .Random_Colors:
    // Random colors are generated in shader using gl_PrimitiveID
    // Just set a default color (will be ignored by shader)
    for &vertex in vertices {
      vertex.color = {1.0, 1.0, 1.0, 0.6}
    }
  case .Region_Colors:
    // Similar to random but with different seed
    for i in 0 ..< renderer.vertex_count {
      region_seed := u32(i / 3) // Group by triangles
      hue := f32((region_seed * 213) % 360)
      vertices[i].color = {
        0.5 + 0.5 * math.sin(hue * 0.017453),
        0.5 + 0.5 * math.sin((hue + 120) * 0.017453),
        0.5 + 0.5 * math.sin((hue + 240) * 0.017453),
        0.6,
      }
    }
  }
  gpu.write(&renderer.vertex_buffer, vertices)
}

create_pipeline :: proc(
  renderer: ^Renderer,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) -> vk.Result {
  navmesh_vert := gpu.create_shader_module(
    gctx.device,
    SHADER_NAVMESH_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, navmesh_vert, nil)
  navmesh_frag := gpu.create_shader_module(
    gctx.device,
    SHADER_NAVMESH_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, navmesh_frag, nil)
  set_layouts := []vk.DescriptorSetLayout{rm.camera_buffer_set_layout}
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX, .FRAGMENT},
    size       = size_of(PushConstants),
  }
  layout_info := vk.PipelineLayoutCreateInfo {
    sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount         = u32(len(set_layouts)),
    pSetLayouts            = raw_data(set_layouts),
    pushConstantRangeCount = 1,
    pPushConstantRanges    = &push_constant_range,
  }
  vk.CreatePipelineLayout(
    gctx.device,
    &layout_info,
    nil,
    &renderer.pipeline_layout,
  ) or_return
  vertex_binding := vk.VertexInputBindingDescription {
    binding   = 0,
    stride    = size_of(Vertex),
    inputRate = .VERTEX,
  }
  vertex_attributes := []vk.VertexInputAttributeDescription {
    {
      location = 0,
      binding = 0,
      format = .R32G32B32_SFLOAT,
      offset = u32(offset_of(Vertex, position)),
    },
    {
      location = 1,
      binding = 0,
      format = .R32G32B32A32_SFLOAT,
      offset = u32(offset_of(Vertex, color)),
    },
  }
  vertex_input := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &vertex_binding,
    vertexAttributeDescriptionCount = u32(len(vertex_attributes)),
    pVertexAttributeDescriptions    = raw_data(vertex_attributes),
  }
  input_assembly := gpu.create_standard_input_assembly()
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  rasterizer := gpu.create_standard_rasterizer(cull_mode = {})
  multisampling := gpu.create_standard_multisampling()
  // Depth testing enabled, writing disabled for transparency
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
  dynamic_state := gpu.create_dynamic_state(gpu.STANDARD_DYNAMIC_STATES[:])
  depth_format: vk.Format = .D32_SFLOAT
  color_format: vk.Format = .B8G8R8A8_SRGB
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = 1,
    pColorAttachmentFormats = &color_format,
    depthAttachmentFormat   = depth_format,
  }
  shader_stages := []vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = navmesh_vert,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = navmesh_frag,
      pName = "main",
    },
  }
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = u32(len(shader_stages)),
    pStages             = raw_data(shader_stages),
    pVertexInputState   = &vertex_input,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pDepthStencilState  = &depth_stencil,
    pColorBlendState    = &color_blending,
    pDynamicState       = &dynamic_state,
    layout              = renderer.pipeline_layout,
    pNext               = &rendering_info,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info,
    nil,
    &renderer.pipeline,
  ) or_return
  input_assembly_lines := gpu.create_standard_input_assembly(
    topology = .LINE_STRIP,
  )
  rasterizer_lines := gpu.create_standard_rasterizer(
    cull_mode = {},
    line_width = 3.0,
  )
  pipeline_info_lines := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = u32(len(shader_stages)),
    pStages             = raw_data(shader_stages),
    pVertexInputState   = &vertex_input,
    pInputAssemblyState = &input_assembly_lines,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer_lines,
    pMultisampleState   = &multisampling,
    pDepthStencilState  = &depth_stencil,
    pColorBlendState    = &color_blending,
    pDynamicState       = &dynamic_state,
    layout              = renderer.pipeline_layout,
    pNext               = &rendering_info,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info_lines,
    nil,
    &renderer.line_pipeline,
  ) or_return
  log.info("Navigation mesh pipeline created successfully")
  return .SUCCESS
}

update_path :: proc(
  renderer: ^Renderer,
  path_points: [][3]f32,
  path_color: [4]f32,
) {
  if len(path_points) < 2 {
    renderer.path_enabled = false
    renderer.path_vertex_count = 0
    return
  }
  path_vertices := make([]Vertex, len(path_points), context.temp_allocator)
  for point, i in path_points {
    path_vertices[i] = Vertex {
      position = point,
      color    = path_color,
    }
  }
  if len(path_vertices) <= 1024 {
    vertex_result := gpu.write(&renderer.path_vertex_buffer, path_vertices)
    if vertex_result == .SUCCESS {
      renderer.path_vertex_count = u32(len(path_vertices))
      renderer.path_enabled = true
    } else {
      log.error("Failed to upload path vertex data")
      renderer.path_enabled = false
    }
  } else {
    log.errorf(
      "Path too long (%d vertices), maximum is 1024",
      len(path_vertices),
    )
    renderer.path_enabled = false
  }
}

clear_path :: proc(renderer: ^Renderer) {
  renderer.path_enabled = false
  renderer.path_vertex_count = 0
}
