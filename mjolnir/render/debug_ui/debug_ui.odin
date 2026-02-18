package debug_ui

import cont "../../containers"
import gpu "../../gpu"
import d "../data"
import "../shared"
import "core:log"
import "core:math/linalg"
import mu "vendor:microui"
import vk "vendor:vulkan"

SHADER_MICROUI_VERT :: #load("../../shader/microui/vert.spv")
SHADER_MICROUI_FRAG :: #load("../../shader/microui/frag.spv")

UI_MAX_QUAD :: 1000
UI_MAX_VERTICES :: UI_MAX_QUAD * 4
UI_MAX_INDICES :: UI_MAX_QUAD * 6

Renderer :: struct {
  ctx:             mu.Context,
  pipeline_layout: vk.PipelineLayout,
  pipeline:        vk.Pipeline,
  atlas_handle:    gpu.Texture2DHandle,
  projection:      matrix[4, 4]f32,
  vertex_buffer:   gpu.MutableBuffer(Vertex2D),
  index_buffer:    gpu.MutableBuffer(u32),
  vertex_count:    u32,
  index_count:     u32,
  vertices:        [UI_MAX_VERTICES]Vertex2D,
  indices:         [UI_MAX_INDICES]u32,
  frame:           vk.Extent2D,
  dpi_scale:       f32,
  current_scissor: vk.Rect2D,
}

Vertex2D :: struct {
  pos:        [2]f32,
  uv:         [2]f32,
  color:      [4]u8,
  texture_id: u32,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  color_format: vk.Format,
  extent: vk.Extent2D,
  dpi_scale: f32 = 1.0,
  textures_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  mu.init(&self.ctx)
  self.ctx.text_width = mu.default_atlas_text_width
  self.ctx.text_height = mu.default_atlas_text_height
  self.frame = extent
  self.dpi_scale = dpi_scale
  self.current_scissor = vk.Rect2D {
    extent = extent,
  }
  log.infof("init debug UI pipeline...")
  vert_shader_module := gpu.create_shader_module(
    gctx.device,
    SHADER_MICROUI_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_shader_module, nil)
  frag_shader_module := gpu.create_shader_module(
    gctx.device,
    SHADER_MICROUI_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_shader_module, nil)
  shader_stages := gpu.create_vert_frag_stages(
    vert_shader_module,
    frag_shader_module,
  )
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
    {   // texture_id
      binding  = 0,
      location = 3,
      format   = .R32_UINT,
      offset   = u32(offset_of(Vertex2D, texture_id)),
    },
  }
  vertex_input := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &vertex_binding,
    vertexAttributeDescriptionCount = len(vertex_attributes),
    pVertexAttributeDescriptions    = raw_data(vertex_attributes[:]),
  }
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX},
      size = size_of(matrix[4, 4]f32),
    },
    textures_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
    self.pipeline_layout = 0
  }
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &gpu.COLOR_ONLY_RENDERING_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.DOUBLE_SIDED_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
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
    self.pipeline = 0
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
    self.pipeline_layout = 0
  }
  log.infof("done init debug UI pipeline")
  return .SUCCESS
}

setup :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) -> (
  ret: vk.Result,
) {
  log.infof("setup debug UI atlas texture...")
  self.atlas_handle, ret = gpu.allocate_texture_2d_with_data(
    texture_manager,
    gctx,
    raw_data(mu.default_atlas_alpha[:]),
    vk.DeviceSize(len(mu.default_atlas_alpha)),
    vk.Extent2D{mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT},
    .R8_UNORM,
    {.SAMPLED},
  )
  if ret != .SUCCESS do return
  defer if ret != .SUCCESS {
    gpu.free_texture_2d(texture_manager, gctx, self.atlas_handle)
    self.atlas_handle = {}
  }
  log.infof("debug UI atlas at bindless index %d", self.atlas_handle.index)
  self.projection =
    linalg.matrix_ortho3d(
      0,
      f32(self.frame.width),
      f32(self.frame.height),
      0,
      -1,
      1,
    ) *
    linalg.matrix4_scale(self.dpi_scale)
  self.vertex_buffer = gpu.create_mutable_buffer(
    gctx,
    Vertex2D,
    UI_MAX_VERTICES,
    {.VERTEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.vertex_buffer)
  }
  self.index_buffer = gpu.create_mutable_buffer(
    gctx,
    u32,
    UI_MAX_INDICES,
    {.INDEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.index_buffer)
  }
  log.infof("done setup debug UI")
  return .SUCCESS
}

teardown :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) {
  gpu.mutable_buffer_destroy(gctx.device, &self.vertex_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.index_buffer)
  gpu.free_texture_2d(texture_manager, gctx, self.atlas_handle)
  self.atlas_handle = {}
}

ui_flush :: proc(
  self: ^Renderer,
  cmd_buf: vk.CommandBuffer,
  textures_descriptor_set: vk.DescriptorSet,
) -> vk.Result {
  if self.vertex_count == 0 && self.index_count == 0 {
    return .SUCCESS
  }
  defer {
    self.vertex_count = 0
    self.index_count = 0
  }
  gpu.write(&self.vertex_buffer, self.vertices[:self.vertex_count]) or_return
  gpu.write(&self.index_buffer, self.indices[:self.index_count]) or_return
  gpu.bind_graphics_pipeline(
    cmd_buf,
    self.pipeline,
    self.pipeline_layout,
    textures_descriptor_set,
  )
  vk.CmdPushConstants(
    cmd_buf,
    self.pipeline_layout,
    {.VERTEX},
    0,
    size_of(matrix[4, 4]f32),
    &self.projection,
  )
  viewport := vk.Viewport {
    x        = 0,
    y        = f32(self.frame.height),
    width    = f32(self.frame.width),
    height   = -f32(self.frame.height),
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
  self: ^Renderer,
  cmd_buf: vk.CommandBuffer,
  textures_descriptor_set: vk.DescriptorSet,
  dst, src: mu.Rect,
  color: mu.Color,
  texture_id: u32,
) {
  if (self.vertex_count + 4 > UI_MAX_VERTICES ||
       self.index_count + 6 > UI_MAX_INDICES) {
    ui_flush(self, cmd_buf, textures_descriptor_set)
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
    pos        = [2]f32{dx, dy},
    uv         = [2]f32{x, y},
    color      = [4]u8{color.r, color.g, color.b, color.a},
    texture_id = texture_id,
  }
  self.vertices[self.vertex_count + 1] = {
    pos        = [2]f32{dx + dw, dy},
    uv         = [2]f32{x + w, y},
    color      = [4]u8{color.r, color.g, color.b, color.a},
    texture_id = texture_id,
  }
  self.vertices[self.vertex_count + 2] = {
    pos        = [2]f32{dx + dw, dy + dh},
    uv         = [2]f32{x + w, y + h},
    color      = [4]u8{color.r, color.g, color.b, color.a},
    texture_id = texture_id,
  }
  self.vertices[self.vertex_count + 3] = {
    pos        = [2]f32{dx, dy + dh},
    uv         = [2]f32{x, y + h},
    color      = [4]u8{color.r, color.g, color.b, color.a},
    texture_id = texture_id,
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
  self: ^Renderer,
  cmd_buf: vk.CommandBuffer,
  textures_descriptor_set: vk.DescriptorSet,
  rect: mu.Rect,
  color: mu.Color,
) {
  ui_push_quad(
    self,
    cmd_buf,
    textures_descriptor_set,
    rect,
    mu.default_atlas[mu.DEFAULT_ATLAS_WHITE],
    color,
    self.atlas_handle.index,
  )
}

ui_draw_text :: proc(
  self: ^Renderer,
  cmd_buf: vk.CommandBuffer,
  textures_descriptor_set: vk.DescriptorSet,
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
      ui_push_quad(
        self,
        cmd_buf,
        textures_descriptor_set,
        dst,
        src,
        color,
        self.atlas_handle.index,
      )
      dst.x += dst.w
    }
  }
}

ui_draw_icon :: proc(
  self: ^Renderer,
  cmd_buf: vk.CommandBuffer,
  textures_descriptor_set: vk.DescriptorSet,
  id: mu.Icon,
  rect: mu.Rect,
  color: mu.Color,
) {
  src := mu.default_atlas[id]
  x := rect.x + (rect.w - src.w) / 2
  y := rect.y + (rect.h - src.h) / 2
  ui_push_quad(
    self,
    cmd_buf,
    textures_descriptor_set,
    {x, y, src.w, src.h},
    src,
    color,
    self.atlas_handle.index,
  )
}

ui_set_clip_rect :: proc(
  self: ^Renderer,
  cmd_buf: vk.CommandBuffer,
  rect: mu.Rect,
) {
  x := min(u32(max(rect.x, 0)), self.frame.width)
  y := min(u32(max(rect.y, 0)), self.frame.height)
  w := min(u32(rect.w), self.frame.width - x)
  h := min(u32(rect.h), self.frame.height - y)
  self.current_scissor = vk.Rect2D {
    offset = {i32(x), i32(y)},
    extent = {w, h},
  }
  vk.CmdSetScissor(cmd_buf, 0, 1, &self.current_scissor)
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  self.pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
}

recreate_images :: proc(
  self: ^Renderer,
  color_format: vk.Format,
  extent: vk.Extent2D,
  dpi_scale: f32,
) {
  self.frame = extent
  self.dpi_scale = dpi_scale
  self.current_scissor = vk.Rect2D {
    extent = extent,
  }
  self.projection =
    linalg.matrix_ortho3d(0, f32(extent.width), f32(extent.height), 0, -1, 1) *
    linalg.matrix4_scale(dpi_scale)
}

begin_pass :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  color_view: vk.ImageView,
  extent: vk.Extent2D,
) {
  gpu.begin_rendering(
    command_buffer,
    extent,
    nil,
    gpu.create_color_attachment_view(color_view, .LOAD, .STORE),
  )
  gpu.set_viewport_scissor(command_buffer, extent)
}

render :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  textures_descriptor_set: vk.DescriptorSet,
) {
  command_backing: ^mu.Command
  for variant in mu.next_command_iterator(&self.ctx, &command_backing) {
    switch cmd in variant {
    case ^mu.Command_Text:
      ui_draw_text(
        self,
        command_buffer,
        textures_descriptor_set,
        cmd.str,
        cmd.pos,
        cmd.color,
      )
    case ^mu.Command_Rect:
      ui_draw_rect(
        self,
        command_buffer,
        textures_descriptor_set,
        cmd.rect,
        cmd.color,
      )
    case ^mu.Command_Icon:
      ui_draw_icon(
        self,
        command_buffer,
        textures_descriptor_set,
        cmd.id,
        cmd.rect,
        cmd.color,
      )
    case ^mu.Command_Clip:
      ui_set_clip_rect(self, command_buffer, cmd.rect)
    case ^mu.Command_Jump:
      unreachable()
    }
  }
  ui_flush(self, command_buffer, textures_descriptor_set)
}

end_pass :: proc(self: ^Renderer, command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}
