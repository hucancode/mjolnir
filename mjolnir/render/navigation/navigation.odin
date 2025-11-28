package navigation_renderer

import cont "../../containers"
import "../../gpu"
import "../../resources"
import "core:log"
import "core:math"
import vk "vendor:vulkan"

FRAMES_IN_FLIGHT :: #config(FRAMES_IN_FLIGHT, 2)
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
  commands:           [FRAMES_IN_FLIGHT]vk.CommandBuffer,
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
  color_mode:    ColorMode,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) -> (
  ret: vk.Result,
) {
  self.enabled = true
  self.color_mode = .Random_Colors
  self.debug_mode = false
  self.alpha = 0.6
  self.height_offset = 0.05
  self.base_color = {0.0, 0.8, 0.2}
  self.path_enabled = false
  gpu.allocate_command_buffer(gctx, self.commands[:], .SECONDARY) or_return
  defer if ret != .SUCCESS {
    gpu.free_command_buffer(gctx, ..self.commands[:])
  }
  create_pipeline(self, gctx, rm) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.line_pipeline, nil)
    vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  }
  self.vertex_buffer = gpu.create_mutable_buffer(
    gctx,
    Vertex,
    16384,
    {.VERTEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.vertex_buffer)
  }
  self.index_buffer = gpu.create_mutable_buffer(
    gctx,
    u32,
    32768,
    {.INDEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.index_buffer)
  }
  self.path_vertex_buffer = gpu.create_mutable_buffer(
    gctx,
    Vertex,
    1024,
    {.VERTEX_BUFFER},
  ) or_return
  return .SUCCESS
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.line_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  gpu.mutable_buffer_destroy(gctx.device, &self.vertex_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.index_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.path_vertex_buffer)
}

begin_pass :: proc(
  self: ^Renderer,
  camera_handle: resources.CameraHandle,
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
  depth_texture := cont.get(
    rm.images_2d,
    camera.attachments[.DEPTH][frame_index],
  )
  extent := camera.extent
  gpu.begin_rendering(
    command_buffer,
    extent.width,
    extent.height,
    gpu.create_depth_attachment(depth_texture, .LOAD, .STORE),
    gpu.create_color_attachment(color_texture, .LOAD, .STORE),
  )
  gpu.set_viewport_scissor(
    command_buffer,
    extent.width,
    extent.height,
    flip_y = false,
  )
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
  gpu.bind_graphics_pipeline(
    command_buffer,
    renderer.pipeline,
    renderer.pipeline_layout,
    rm.camera_buffer.descriptor_sets[frame_index],
  )
  if renderer.vertex_count > 0 && renderer.index_count > 0 {
    gpu.bind_vertex_index_buffers(
      command_buffer,
      renderer.vertex_buffer.buffer,
      renderer.index_buffer.buffer,
    )
    push_constants := PushConstants {
      world         = world_matrix,
      camera_index  = camera_index,
      height_offset = renderer.height_offset,
      alpha         = renderer.alpha,
      color_mode    = renderer.color_mode,
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
    gpu.bind_graphics_pipeline(
      command_buffer,
      renderer.line_pipeline,
      renderer.pipeline_layout,
      rm.camera_buffer.descriptor_sets[frame_index],
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
      color_mode    = ColorMode.Uniform,
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
  renderer.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(PushConstants),
    },
    rm.camera_buffer.set_layout,
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
  shader_stages := gpu.create_vert_frag_stages(navmesh_vert, navmesh_frag)
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.DOUBLE_SIDED_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = renderer.pipeline_layout,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info,
    nil,
    &renderer.pipeline,
  ) or_return
  pipeline_info_lines := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input,
    pInputAssemblyState = &gpu.LINE_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.BOLD_DOUBLE_SIDED_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = renderer.pipeline_layout,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
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
