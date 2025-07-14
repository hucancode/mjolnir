package mjolnir

import intr "base:intrinsics"
import "core:log"
import linalg "core:math/linalg"
import mu "vendor:microui"
import vk "vendor:vulkan"

SHADER_MICROUI_VERT :: #load("shader/microui/vert.spv")
SHADER_MICROUI_FRAG :: #load("shader/microui/frag.spv")

UI_MAX_QUAD :: 1000
UI_MAX_VERTICES :: UI_MAX_QUAD * 4
UI_MAX_INDICES :: UI_MAX_QUAD * 6

RendererUI :: struct {
  ctx:                       mu.Context,
  projection_layout:         vk.DescriptorSetLayout,
  projection_descriptor_set: vk.DescriptorSet,
  texture_layout:            vk.DescriptorSetLayout,
  texture_descriptor_set:    vk.DescriptorSet,
  pipeline_layout:           vk.PipelineLayout,
  pipeline:                  vk.Pipeline,
  atlas:                     ^ImageBuffer,
  proj_buffer:               DataBuffer(matrix[4,4]f32),
  vertex_buffer:             DataBuffer(Vertex2D),
  index_buffer:              DataBuffer(u32),
  vertex_count:              u32,
  index_count:               u32,
  vertices:                  [UI_MAX_VERTICES]Vertex2D,
  indices:                   [UI_MAX_INDICES]u32,
  frame_width:               u32,
  frame_height:              u32,
  dpi_scale:                 f32,
  current_scissor:           vk.Rect2D,
}

Vertex2D :: struct {
  pos:   [2]f32,
  uv:    [2]f32,
  color: [4]u8,
}

ui_init :: proc(
  gpu_context: ^GPUContext,
  self: ^RendererUI,
  color_format: vk.Format,
  width: u32,
  height: u32,
  dpi_scale: f32 = 1.0,
) -> vk.Result {
  mu.init(&self.ctx)
  self.ctx.text_width = mu.default_atlas_text_width
  self.ctx.text_height = mu.default_atlas_text_height
  self.frame_width = width
  self.frame_height = height
  self.dpi_scale = dpi_scale
  self.current_scissor = vk.Rect2D{extent = {width, height}}
  log.infof("init UI pipeline...")
  vert_shader_module := create_shader_module(gpu_context, SHADER_MICROUI_VERT) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_shader_module, nil)
  frag_shader_module := create_shader_module(gpu_context, SHADER_MICROUI_FRAG) or_return
  defer vk.DestroyShaderModule(gpu_context.device, frag_shader_module, nil)
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_shader_module,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_shader_module,
      pName = "main",
    },
  }
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }
  vertex_binding := vk.VertexInputBindingDescription {
    binding   = 0,
    stride    = size_of(Vertex2D),
    inputRate = .VERTEX,
  }
  vertex_attributes := [?]vk.VertexInputAttributeDescription {
    {   // position
      binding  = 0,
      location = 0,
      format   = .R32G32_SFLOAT,
      offset   = u32(offset_of(Vertex2D, pos)),
    },
    {   // uv
      binding  = 0,
      location = 1,
      format   = .R32G32_SFLOAT,
      offset   = u32(offset_of(Vertex2D, uv)),
    },
    {   // color
      binding  = 0,
      location = 2,
      format   = .R8G8B8A8_UNORM,
      offset   = u32(offset_of(Vertex2D, color)),
    },
  }
  vertex_input := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &vertex_binding,
    vertexAttributeDescriptionCount = len(vertex_attributes),
    pVertexAttributeDescriptions    = raw_data(vertex_attributes[:]),
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
    lineWidth   = 1.0,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    blendEnable         = true,
    srcColorBlendFactor = .SRC_ALPHA,
    dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
    colorBlendOp        = .ADD,
    srcAlphaBlendFactor = .SRC_ALPHA,
    dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
    alphaBlendOp        = .ADD,
    colorWriteMask      = {.R, .G, .B, .A},
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }
  projection_layout_info := vk.DescriptorSetLayoutCreateInfo {
    sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount = 1,
    pBindings    = &vk.DescriptorSetLayoutBinding {
      binding = 0,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX},
    },
  }
  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &projection_layout_info,
    nil,
    &self.projection_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &self.projection_layout,
    },
    &self.projection_descriptor_set,
  ) or_return
  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = 1,
      pBindings = &vk.DescriptorSetLayoutBinding {
        binding = 0,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = 1,
        stageFlags = {.FRAGMENT},
      },
    },
    nil,
    &self.texture_layout,
  ) or_return
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &self.texture_layout,
    },
    &self.texture_descriptor_set,
  ) or_return
  set_layouts := [?]vk.DescriptorSetLayout {
    self.projection_layout,
    self.texture_layout,
  }
  vk.CreatePipelineLayout(
    gpu_context.device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(set_layouts),
      pSetLayouts = raw_data(set_layouts[:]),
    },
    nil,
    &self.pipeline_layout,
  ) or_return
  color_formats := [?]vk.Format{color_format}
  rendering_info_khr := vk.PipelineRenderingCreateInfoKHR {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
  }
  depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
    sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
  }
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &rendering_info_khr,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pColorBlendState    = &color_blending,
    pDynamicState       = &dynamic_state_info,
    pDepthStencilState  = &depth_stencil_state,
    layout              = self.pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gpu_context.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.pipeline,
  ) or_return
  log.infof("init UI texture...")
  _, self.atlas = create_texture_from_pixels(
    gpu_context,
    mu.default_atlas_alpha[:],
    mu.DEFAULT_ATLAS_WIDTH,
    mu.DEFAULT_ATLAS_HEIGHT,
    1,
    .R8_UNORM,
  ) or_return
  log.infof("init UI vertex buffer...")
  self.vertex_buffer = create_host_visible_buffer(
    gpu_context,
    Vertex2D,
    UI_MAX_VERTICES,
    {.VERTEX_BUFFER},
  ) or_return
  log.infof("init UI indices buffer...")
  self.index_buffer = create_host_visible_buffer(
    gpu_context,
    u32,
    UI_MAX_INDICES,
    {.INDEX_BUFFER},
  ) or_return
  ortho := linalg.matrix_ortho3d(0, f32(width), f32(height), 0, -1, 1) * linalg.matrix4_scale(dpi_scale)
  log.infof("init UI proj buffer...")
  self.proj_buffer = create_host_visible_buffer(
    gpu_context,
    matrix[4,4]f32,
    1,
    {.UNIFORM_BUFFER},
    raw_data(&ortho),
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = self.proj_buffer.buffer,
    range  = size_of(matrix[4,4]f32),
  }
  writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.projection_descriptor_set,
      dstBinding = 0,
      descriptorCount = 1,
      descriptorType = .UNIFORM_BUFFER,
      pBufferInfo = &buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.texture_descriptor_set,
      dstBinding = 0,
      descriptorCount = 1,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      pImageInfo = &{
        sampler = g_nearest_clamp_sampler,
        imageView = self.atlas.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    },
  }
  vk.UpdateDescriptorSets(gpu_context.device, len(writes), raw_data(writes[:]), 0, nil)
  log.infof("done init UI")
  return .SUCCESS
}

ui_flush :: proc(self: ^RendererUI, cmd_buf: vk.CommandBuffer) -> vk.Result {
  if self.vertex_count == 0 && self.index_count == 0 {
    return .SUCCESS
  }
  defer {
    self.vertex_count = 0
    self.index_count = 0
  }
  data_buffer_write(&self.vertex_buffer, self.vertices[:self.vertex_count]) or_return
  data_buffer_write(&self.index_buffer, self.indices[:self.index_count]) or_return
  vk.CmdBindPipeline(cmd_buf, .GRAPHICS, self.pipeline)
  descriptor_sets := [?]vk.DescriptorSet {
    self.projection_descriptor_set,
    self.texture_descriptor_set,
  }
  vk.CmdBindDescriptorSets(
    cmd_buf,
    .GRAPHICS,
    self.pipeline_layout,
    0,
    2,
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )
  viewport := vk.Viewport {
    x        = 0,
    y        = f32(self.frame_height),
    width    = f32(self.frame_width),
    height   = -f32(self.frame_height),
    minDepth = 0,
    maxDepth = 1,
  }
  vk.CmdSetViewport(cmd_buf, 0, 1, &viewport)
  vk.CmdSetScissor(cmd_buf, 0, 1, &self.current_scissor)
  offsets := [?]vk.DeviceSize{0}
  vk.CmdBindVertexBuffers(
    cmd_buf,
    0,
    1,
    &self.vertex_buffer.buffer,
    raw_data(offsets[:]),
  )
  vk.CmdBindIndexBuffer(cmd_buf, self.index_buffer.buffer, 0, .UINT32)
  vk.CmdDrawIndexed(cmd_buf, self.index_count, 1, 0, 0, 0)
  return .SUCCESS
}

ui_push_quad :: proc(
  self: ^RendererUI,
  cmd_buf: vk.CommandBuffer,
  dst, src: mu.Rect,
  color: mu.Color,
) {
  if (self.vertex_count + 4 > UI_MAX_VERTICES ||
       self.index_count + 6 > UI_MAX_INDICES) {
    ui_flush(self, cmd_buf)
  }
  x, y, w, h :=
    f32(src.x) /
    mu.DEFAULT_ATLAS_WIDTH,
    f32(src.y) /
    mu.DEFAULT_ATLAS_HEIGHT,
    f32(src.w) /
    mu.DEFAULT_ATLAS_WIDTH,
    f32(src.h) /
    mu.DEFAULT_ATLAS_HEIGHT
  dx, dy, dw, dh := f32(dst.x), f32(dst.y), f32(dst.w), f32(dst.h)
  self.vertices[self.vertex_count + 0] = {
    pos   = [2]f32{dx, dy},
    uv    = [2]f32{x, y},
    color = [4]u8{color.r, color.g, color.b, color.a},
  }
  self.vertices[self.vertex_count + 1] = {
    pos   = [2]f32{dx + dw, dy},
    uv    = [2]f32{x + w, y},
    color = [4]u8{color.r, color.g, color.b, color.a},
  }
  self.vertices[self.vertex_count + 2] = {
    pos   = [2]f32{dx + dw, dy + dh},
    uv    = [2]f32{x + w, y + h},
    color = [4]u8{color.r, color.g, color.b, color.a},
  }
  self.vertices[self.vertex_count + 3] = {
    pos   = [2]f32{dx, dy + dh},
    uv    = [2]f32{x, y + h},
    color = [4]u8{color.r, color.g, color.b, color.a},
  }
  vertex_base := u32(self.vertex_count)
  self.indices[self.index_count + 0] = vertex_base + 0
  self.indices[self.index_count + 1] = vertex_base + 1
  self.indices[self.index_count + 2] = vertex_base + 2
  self.indices[self.index_count + 3] = vertex_base + 2
  self.indices[self.index_count + 4] = vertex_base + 3
  self.indices[self.index_count + 5] = vertex_base + 0
  self.index_count += 6
  self.vertex_count += 4
}

ui_draw_rect :: proc(
  self: ^RendererUI,
  cmd_buf: vk.CommandBuffer,
  rect: mu.Rect,
  color: mu.Color,
) {
  ui_push_quad(
    self,
    cmd_buf,
    rect,
    mu.default_atlas[mu.DEFAULT_ATLAS_WHITE],
    color,
  )
}

ui_draw_text :: proc(
  self: ^RendererUI,
  cmd_buf: vk.CommandBuffer,
  text: string,
  pos: mu.Vec2,
  color: mu.Color,
) {
  dst := mu.Rect{pos.x, pos.y, 0, 0}
  for ch in text {
    if ch & 0xc0 != 0x80 {
      r := min(int(ch), 127)
      src := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + r]
      dst.w = src.w
      dst.h = src.h
      ui_push_quad(self, cmd_buf, dst, src, color)
      dst.x += dst.w
    }
  }
}

ui_draw_icon :: proc(
  self: ^RendererUI,
  cmd_buf: vk.CommandBuffer,
  id: mu.Icon,
  rect: mu.Rect,
  color: mu.Color,
) {
  src := mu.default_atlas[id]
  x := rect.x + (rect.w - src.w) / 2
  y := rect.y + (rect.h - src.h) / 2
  ui_push_quad(self, cmd_buf, {x, y, src.w, src.h}, src, color)
}

ui_set_clip_rect :: proc(
  self: ^RendererUI,
  cmd_buf: vk.CommandBuffer,
  rect: mu.Rect,
) {
  x := min(u32(max(rect.x, 0)), self.frame_width)
  y := min(u32(max(rect.y, 0)), self.frame_height)
  w := min(u32(rect.w), self.frame_width - x)
  h := min(u32(rect.h), self.frame_height - y)
  self.current_scissor = vk.Rect2D {
    offset = {i32(x), i32(y)},
    extent = {w, h},
  }
  vk.CmdSetScissor(cmd_buf, 0, 1, &self.current_scissor)
}

ui_deinit :: proc(gpu_context: ^GPUContext, self: ^RendererUI) {
  if self == nil {
    return
  }
  data_buffer_deinit(gpu_context, &self.vertex_buffer)
  data_buffer_deinit(gpu_context, &self.index_buffer)
  data_buffer_deinit(gpu_context, &self.proj_buffer)
  vk.DestroyPipeline(gpu_context.device, self.pipeline, nil)
  self.pipeline = 0
  vk.DestroyPipelineLayout(gpu_context.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
  vk.DestroyDescriptorSetLayout(gpu_context.device, self.projection_layout, nil)
  self.projection_layout = 0
  vk.DestroyDescriptorSetLayout(gpu_context.device, self.texture_layout, nil)
  self.texture_layout = 0
}

ui_recreate_images :: proc(
  self: ^RendererUI,
  color_format: vk.Format,
  width: u32,
  height: u32,
  dpi_scale: f32,
) -> vk.Result {
  // Only update frame dimensions and DPI scale
  self.frame_width = width
  self.frame_height = height
  self.dpi_scale = dpi_scale
  // Reset scissor to full screen on resize
  self.current_scissor = vk.Rect2D{extent = {width, height}}

  // Update the projection matrix with new dimensions and DPI scale
  ortho := linalg.matrix_ortho3d(0, f32(width), f32(height), 0, -1, 1) * linalg.matrix4_scale(dpi_scale)
  data_buffer_write(&self.proj_buffer, &ortho) or_return

  return .SUCCESS
}

// Modular UI renderer API
ui_begin :: proc(
  self: ^RendererUI,
  command_buffer: vk.CommandBuffer,
  color_view: vk.ImageView,
  extent: vk.Extent2D,
) {
  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = color_view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .LOAD, // preserve previous contents
    storeOp = .STORE,
  }
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0.0,
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

ui_render :: proc(
  self: ^RendererUI,
  command_buffer: vk.CommandBuffer,
) {
  command_backing: ^mu.Command
  for variant in mu.next_command_iterator(&self.ctx, &command_backing) {
    // log.infof("executing UI command", variant)
    switch cmd in variant {
    case ^mu.Command_Text:
      ui_draw_text(self, command_buffer, cmd.str, cmd.pos, cmd.color)
    case ^mu.Command_Rect:
      ui_draw_rect(self, command_buffer, cmd.rect, cmd.color)
    case ^mu.Command_Icon:
      ui_draw_icon(self, command_buffer, cmd.id, cmd.rect, cmd.color)
    case ^mu.Command_Clip:
      ui_set_clip_rect(self, command_buffer, cmd.rect)
    case ^mu.Command_Jump:
      unreachable()
    }
  }
  ui_flush(self, command_buffer)
}

ui_end :: proc(self: ^RendererUI, command_buffer: vk.CommandBuffer) {
  vk.CmdEndRenderingKHR(command_buffer)
}
