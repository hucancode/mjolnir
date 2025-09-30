package text

import "base:runtime"
import "core:log"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "../../gpu"
import "../../resources"
import fs "vendor:fontstash"
import vk "vendor:vulkan"

SHADER_TEXT_VERT :: #load("../../shader/text/vert.spv")
SHADER_TEXT_FRAG :: #load("../../shader/text/frag.spv")

TEXT_MAX_QUADS :: 4096
TEXT_MAX_VERTICES :: TEXT_MAX_QUADS * 4
TEXT_MAX_INDICES :: TEXT_MAX_QUADS * 6
ATLAS_WIDTH :: 1024
ATLAS_HEIGHT :: 1024

Renderer :: struct {
  font_ctx:                  fs.FontContext,
  default_font:              int,
  projection_layout:         vk.DescriptorSetLayout,
  projection_descriptor_set: vk.DescriptorSet,
  texture_layout:            vk.DescriptorSetLayout,
  texture_descriptor_set:    vk.DescriptorSet,
  pipeline_layout:           vk.PipelineLayout,
  pipeline:                  vk.Pipeline,
  atlas_texture:             ^gpu.ImageBuffer,
  proj_buffer:               gpu.DataBuffer(matrix[4, 4]f32),
  vertex_buffer:             gpu.DataBuffer(Vertex),
  index_buffer:              gpu.DataBuffer(u32),
  vertex_count:              u32,
  index_count:               u32,
  vertices:                  [TEXT_MAX_VERTICES]Vertex,
  indices:                   [TEXT_MAX_INDICES]u32,
  frame_width:               u32,
  frame_height:              u32,
  atlas_needs_update:        bool,
  atlas_initialized:         bool,
}

Vertex :: struct {
  pos:   [2]f32,
  uv:    [2]f32,
  color: [4]u8,
}

init :: proc(
  self: ^Renderer,
  gpu_context: ^gpu.GPUContext,
  color_format: vk.Format,
  width, height: u32,
  resources_manager: ^resources.Manager,
) -> vk.Result {
  self.frame_width = width
  self.frame_height = height
  fs.Init(&self.font_ctx, ATLAS_WIDTH, ATLAS_HEIGHT, .TOPLEFT)
  self.font_ctx.callbackResize = atlas_resize_callback
  self.font_ctx.userData = self
  font_path := "/usr/share/fonts/TTF/FiraCode-Regular.ttf"
  font_data, ok := os.read_entire_file(font_path)
  if !ok {
    log.errorf("Failed to load font: %s", font_path)
    return .ERROR_INITIALIZATION_FAILED
  }
  self.default_font = fs.AddFontMem(&self.font_ctx, "default", font_data, true)
  if self.default_font == fs.INVALID {
    log.errorf("Failed to add font to fontstash")
    return .ERROR_INITIALIZATION_FAILED
  }
  log.infof("init text rendering pipeline...")
  vert_shader_module := gpu.create_shader_module(
    gpu_context.device,
    SHADER_TEXT_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_shader_module, nil)
  frag_shader_module := gpu.create_shader_module(
    gpu_context.device,
    SHADER_TEXT_FRAG,
  ) or_return
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
    stride    = size_of(Vertex),
    inputRate = .VERTEX,
  }
  vertex_attributes := [?]vk.VertexInputAttributeDescription {
    {
      binding  = 0,
      location = 0,
      format   = .R32G32_SFLOAT,
      offset   = u32(offset_of(Vertex, pos)),
    },
    {
      binding  = 0,
      location = 1,
      format   = .R32G32_SFLOAT,
      offset   = u32(offset_of(Vertex, uv)),
    },
    {
      binding  = 0,
      location = 2,
      format   = .R8G8B8A8_UNORM,
      offset   = u32(offset_of(Vertex, color)),
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
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ZERO,
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
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
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
  log.infof("pre-rasterizing common glyphs...")
  // Pre-rasterize common ASCII characters at multiple sizes
  fs.SetFont(&self.font_ctx, self.default_font)
  fs.SetColor(&self.font_ctx, {255, 255, 255, 255})
  test_string := " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
  // Rasterize at common font sizes
  common_sizes := [?]f32{12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72, 96}
  for size in common_sizes {
    fs.SetSize(&self.font_ctx, size)
    iter := fs.TextIterInit(&self.font_ctx, 0, 0, test_string)
    quad: fs.Quad
    for fs.TextIterNext(&self.font_ctx, &iter, &quad) {
      // Just iterate to rasterize glyphs
    }
  }
  log.infof("pre-rasterization complete")
  log.infof("init text atlas texture...")
  // Check if atlas has any non-zero pixels
  non_zero_count := 0
  for pixel in self.font_ctx.textureData {
    if pixel > 0 do non_zero_count += 1
  }
  log.infof("Atlas has %d non-zero pixels out of %d total", non_zero_count, len(self.font_ctx.textureData))
  _, self.atlas_texture = resources.create_texture_from_pixels(
    gpu_context,
    resources_manager,
    self.font_ctx.textureData,
    self.font_ctx.width,
    self.font_ctx.height,
    .R8_UNORM,
  ) or_return
  self.atlas_initialized = true
  log.infof("init text vertex buffer...")
  self.vertex_buffer = gpu.create_host_visible_buffer(
    gpu_context,
    Vertex,
    TEXT_MAX_VERTICES,
    {.VERTEX_BUFFER},
  ) or_return
  log.infof("init text index buffer...")
  self.index_buffer = gpu.create_host_visible_buffer(
    gpu_context,
    u32,
    TEXT_MAX_INDICES,
    {.INDEX_BUFFER},
  ) or_return
  ortho := linalg.matrix_ortho3d(0, f32(width), f32(height), 0, -1, 1)
  log.infof("init text projection buffer...")
  self.proj_buffer = gpu.create_host_visible_buffer(
    gpu_context,
    matrix[4, 4]f32,
    1,
    {.UNIFORM_BUFFER},
    raw_data(&ortho),
  ) or_return
  buffer_info := vk.DescriptorBufferInfo {
    buffer = self.proj_buffer.buffer,
    range  = size_of(matrix[4, 4]f32),
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
        sampler = resources_manager.linear_clamp_sampler,
        imageView = self.atlas_texture.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    },
  }
  vk.UpdateDescriptorSets(
    gpu_context.device,
    len(writes),
    raw_data(writes[:]),
    0,
    nil,
  )
  log.infof("done init text renderer")
  return .SUCCESS
}

atlas_resize_callback :: proc(data: rawptr, w, h: int) {
  self := cast(^Renderer)data
  self.atlas_needs_update = true
}

flush :: proc(self: ^Renderer, cmd_buf: vk.CommandBuffer) -> vk.Result {
  if self.vertex_count == 0 && self.index_count == 0 {
    log.infof("text flush: no vertices to render")
    return .SUCCESS
  }
  log.infof("text flush: rendering %d vertices, %d indices", self.vertex_count, self.index_count)
  defer {
    self.vertex_count = 0
    self.index_count = 0
  }
  gpu.write(&self.vertex_buffer, self.vertices[:self.vertex_count]) or_return
  gpu.write(&self.index_buffer, self.indices[:self.index_count]) or_return
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
  scissor := vk.Rect2D {
    extent = {self.frame_width, self.frame_height},
  }
  vk.CmdSetScissor(cmd_buf, 0, 1, &scissor)
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

push_quad :: proc(
  self: ^Renderer,
  quad: fs.Quad,
  color: [4]u8,
) {
  if self.vertex_count + 4 > TEXT_MAX_VERTICES ||
     self.index_count + 6 > TEXT_MAX_INDICES {
    log.warnf("Text vertex buffer full, dropping text")
    return
  }
  self.vertices[self.vertex_count + 0] = {
    pos   = [2]f32{quad.x0, quad.y0},
    uv    = [2]f32{quad.s0, quad.t0},
    color = color,
  }
  self.vertices[self.vertex_count + 1] = {
    pos   = [2]f32{quad.x1, quad.y0},
    uv    = [2]f32{quad.s1, quad.t0},
    color = color,
  }
  self.vertices[self.vertex_count + 2] = {
    pos   = [2]f32{quad.x1, quad.y1},
    uv    = [2]f32{quad.s1, quad.t1},
    color = color,
  }
  self.vertices[self.vertex_count + 3] = {
    pos   = [2]f32{quad.x0, quad.y1},
    uv    = [2]f32{quad.s0, quad.t1},
    color = color,
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

draw_text :: proc(
  self: ^Renderer,
  text: string,
  x, y: f32,
  size: f32 = 16,
  color: [4]u8 = {255, 255, 255, 255},
) {
  fs.SetFont(&self.font_ctx, self.default_font)
  fs.SetSize(&self.font_ctx, size)
  fs.SetColor(&self.font_ctx, color)
  fs.SetAH(&self.font_ctx, .LEFT)
  fs.SetAV(&self.font_ctx, .BASELINE)
  iter := fs.TextIterInit(&self.font_ctx, x, y, text)
  quad: fs.Quad
  quad_count := 0
  for fs.TextIterNext(&self.font_ctx, &iter, &quad) {
    push_quad(self, quad, color)
    quad_count += 1
  }
  log.infof("draw_text: '%s' generated %d quads, vertex_count=%d", text, quad_count, self.vertex_count)
}

update_atlas_if_needed :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  gpu_context: ^gpu.GPUContext,
) -> vk.Result {
  // For now, skip dynamic atlas updates during rendering
  // The initial atlas created during init has all the basic glyphs
  // TODO: Implement proper atlas updates using a separate command buffer with proper synchronization
  return .SUCCESS
}

begin_pass :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  color_view: vk.ImageView,
  extent: vk.Extent2D,
) {
  color_attachment := vk.RenderingAttachmentInfo {
    sType       = .RENDERING_ATTACHMENT_INFO,
    imageView   = color_view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }
  render_info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {extent = extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
  }
  vk.CmdBeginRendering(command_buffer, &render_info)
}

render :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  gpu_context: ^gpu.GPUContext,
) -> vk.Result {
  update_atlas_if_needed(self, command_buffer, gpu_context) or_return
  flush(self, command_buffer) or_return
  return .SUCCESS
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

shutdown :: proc(self: ^Renderer, device: vk.Device) {
  fs.Destroy(&self.font_ctx)
  gpu.data_buffer_destroy(device, &self.vertex_buffer)
  gpu.data_buffer_destroy(device, &self.index_buffer)
  gpu.data_buffer_destroy(device, &self.proj_buffer)
  vk.DestroyPipeline(device, self.pipeline, nil)
  self.pipeline = 0
  vk.DestroyPipelineLayout(device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
  vk.DestroyDescriptorSetLayout(device, self.projection_layout, nil)
  self.projection_layout = 0
  vk.DestroyDescriptorSetLayout(device, self.texture_layout, nil)
  self.texture_layout = 0
}

recreate_images :: proc(
  self: ^Renderer,
  width, height: u32,
) -> vk.Result {
  self.frame_width = width
  self.frame_height = height
  ortho := linalg.matrix_ortho3d(0, f32(width), f32(height), 0, -1, 1)
  gpu.write(&self.proj_buffer, &ortho) or_return
  return .SUCCESS
}
