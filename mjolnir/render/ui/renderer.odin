// 2D overlay renderer. Draws two producers into the swapchain image after
// post-processing, with one pipeline and one vertex stream:
// - draw2d commands staged by the app (game UI), sorted by z_order;
// - the microui debug context, clipped per microui clip rect and scaled by
//   the window DPI.
package ui_render

import "../bindless"
import cmd "../../draw2d"
import "../gpu"
import "core:log"
import "core:math/linalg"
import "core:slice"
import mu "vendor:microui"
import vk "vendor:vulkan"

UI_MAX_VERTICES :: 65536
UI_MAX_INDICES :: 98304

Vertex2D :: cmd.Vertex2D

VERTEX2D_BINDING_DESCRIPTION := vk.VertexInputBindingDescription {
  binding   = 0,
  stride    = size_of(Vertex2D),
  inputRate = .VERTEX,
}

VERTEX2D_ATTRIBUTE_DESCRIPTIONS := [?]vk.VertexInputAttributeDescription {
  {binding = 0, location = 0, format = .R32G32_SFLOAT,  offset = u32(offset_of(Vertex2D, pos))},
  {binding = 0, location = 1, format = .R32G32_SFLOAT,  offset = u32(offset_of(Vertex2D, uv))},
  {binding = 0, location = 2, format = .R8G8B8A8_UNORM, offset = u32(offset_of(Vertex2D, color))},
  {binding = 0, location = 3, format = .R32_UINT,       offset = u32(offset_of(Vertex2D, texture_id))},
}

Renderer :: struct {
  pipeline_layout: vk.PipelineLayout,
  pipeline:        vk.Pipeline,
  vertex_buffers:  [gpu.FRAMES_IN_FLIGHT]gpu.MutableBuffer(Vertex2D),
  index_buffers:   [gpu.FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  vertices:        [UI_MAX_VERTICES]Vertex2D,
  indices:         [UI_MAX_INDICES]u32,
  vertex_count:    u32,
  index_count:     u32,
  batches:         [dynamic]DrawBatch,
  commands:        [dynamic]cmd.RenderCommand,
  white_texture:   bindless.Texture2DHandle, // drawn for cmd.NO_TEXTURE
  font_atlas:      bindless.Texture2DHandle, // sampled by text commands
  debug_ctx:       mu.Context,
  // Mouse buttons pressed over the debug UI, owned by it until released.
  debug_buttons:   bit_set[0 ..< 32],
  debug_atlas:     bindless.Texture2DHandle, // microui's builtin atlas
  dpi_scale:       f32,
}

// A run of indices drawn under one scissor rect. Textures are per vertex
// (bindless), so they never split a batch.
DrawBatch :: struct {
  first_index: u32,
  index_count: u32,
  scissor:     vk.Rect2D,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  textures_set_layout: vk.DescriptorSetLayout,
  format: vk.Format,
  dpi_scale: f32,
) -> vk.Result {
  log.info("Initializing UI renderer pipeline...")
  self.commands = make([dynamic]cmd.RenderCommand, 0, 256)
  self.batches = make([dynamic]DrawBatch, 0, 64)
  self.dpi_scale = dpi_scale
  mu.init(&self.debug_ctx)
  self.debug_ctx.text_width = mu.default_atlas_text_width
  self.debug_ctx.text_height = mu.default_atlas_text_height
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX},
      size = size_of(matrix[4, 4]f32),
    },
    textures_set_layout,
  ) or_return
  create_pipeline(self, gctx, format) or_return
  log.info("UI renderer pipeline initialized successfully")
  return .SUCCESS
}

stage_commands :: proc(self: ^Renderer, commands: []cmd.RenderCommand) {
  clear(&self.commands)
  for command in commands {
    append(&self.commands, command)
  }
}

setup :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^bindless.TextureManager,
) -> vk.Result {
  log.info("Setting up UI renderer buffers...")
  white_pixel := [4]u8{255, 255, 255, 255}
  self.white_texture = bindless.allocate_texture_2d_with_data(
    texture_manager,
    gctx,
    raw_data(white_pixel[:]),
    vk.DeviceSize(len(white_pixel)),
    vk.Extent2D{1, 1},
    .R8G8B8A8_UNORM,
    {.SAMPLED},
  ) or_return
  self.debug_atlas = bindless.allocate_texture_2d_with_data(
    texture_manager,
    gctx,
    raw_data(mu.default_atlas_alpha[:]),
    vk.DeviceSize(len(mu.default_atlas_alpha)),
    vk.Extent2D{mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT},
    .R8_UNORM,
    {.SAMPLED},
  ) or_return
  for i in 0 ..< gpu.FRAMES_IN_FLIGHT {
    self.vertex_buffers[i] = gpu.create_mutable_buffer(
      gctx,
      Vertex2D,
      UI_MAX_VERTICES,
      {.VERTEX_BUFFER},
    ) or_return
    self.index_buffers[i] = gpu.create_mutable_buffer(
      gctx,
      u32,
      UI_MAX_INDICES,
      {.INDEX_BUFFER},
    ) or_return
  }
  log.info("UI renderer buffers set up successfully")
  return .SUCCESS
}

// Textures are destroyed with the texture manager's teardown.
teardown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  for i in 0 ..< gpu.FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &self.vertex_buffers[i])
    gpu.mutable_buffer_destroy(gctx.device, &self.index_buffers[i])
  }
  self.white_texture = {}
  self.font_atlas = {}
  self.debug_atlas = {}
}

// Replace the font atlas texture with R8 pixels of size width x height.
upload_font_atlas :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^bindless.TextureManager,
  pixels: []u8,
  width, height: u32,
) -> vk.Result {
  if self.font_atlas != {} {
    bindless.free_texture_2d(texture_manager, gctx, self.font_atlas)
    self.font_atlas = {}
  }
  self.font_atlas = bindless.allocate_texture_2d_with_data(
    texture_manager,
    gctx,
    raw_data(pixels),
    vk.DeviceSize(len(pixels)),
    vk.Extent2D{width, height},
    .R8_UNORM,
    {.SAMPLED},
  ) or_return
  return .SUCCESS
}

// Window content scale applied to the debug UI.
set_dpi_scale :: proc(self: ^Renderer, dpi_scale: f32) {
  self.dpi_scale = dpi_scale
}

// True when the debug UI is hovered; mouse input belongs to it.
debug_wants_mouse :: proc(self: ^Renderer) -> bool {
  return self.debug_ctx.hover_root != nil
}

// True when a debug UI widget has keyboard focus.
debug_wants_keyboard :: proc(self: ^Renderer) -> bool {
  return self.debug_ctx.focus_id != 0
}

// Route a mouse button edge. A press over the debug UI belongs to it until
// the matching release, wherever the cursor travels. True when consumed.
debug_claim_button :: proc(self: ^Renderer, button: int, pressed: bool) -> bool {
  if pressed {
    if !debug_wants_mouse(self) do return false
    self.debug_buttons += {button}
    return true
  }
  if button not_in self.debug_buttons do return false
  self.debug_buttons -= {button}
  return true
}

@(private)
create_pipeline :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  format: vk.Format,
) -> vk.Result {
  vert_code := #load("../../shader/ui/vert.spv")
  frag_code := #load("../../shader/ui/frag.spv")
  vert_module := gpu.create_shader_module(gctx.device, vert_code) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(gctx.device, frag_code) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  shader_stages := gpu.create_vert_frag_stages(
    vert_module,
    frag_module,
    &bindless.SHADER_SPEC_CONSTANTS,
  )
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &VERTEX2D_BINDING_DESCRIPTION,
    vertexAttributeDescriptionCount = len(VERTEX2D_ATTRIBUTE_DESCRIPTIONS),
    pVertexAttributeDescriptions    = raw_data(VERTEX2D_ATTRIBUTE_DESCRIPTIONS[:]),
  }

  color_formats := [?]vk.Format{format}
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(&color_formats),
  }

  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &rendering_info,
    stageCount          = len(shader_stages),
    pStages             = raw_data(&shader_stages),
    pVertexInputState   = &vertex_input_info,
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
  log.info("UI pipeline created successfully")
  return .SUCCESS
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  delete(self.commands)
  delete(self.batches)
}

// Record the overlay into `color_view` inside its own rendering scope. Draws
// the staged draw2d commands when `draw_commands` is set and the debug UI
// when `draw_debug` is set.
record :: proc(
  self: ^Renderer,
  texture_manager: ^bindless.TextureManager,
  command_buffer: vk.CommandBuffer,
  color_view: vk.ImageView,
  extent: vk.Extent2D,
  frame_index: u32,
  draw_commands, draw_debug: bool,
) {
  if !draw_commands && !draw_debug do return
  self.vertex_count = 0
  self.index_count = 0
  clear(&self.batches)
  full := vk.Rect2D{extent = extent}
  if draw_commands {
    begin_batch(self, full)
    batch_commands(self)
  }
  if draw_debug {
    begin_batch(self, full)
    batch_debug_ui(self, extent)
  }
  end_batch(self)
  if self.index_count == 0 do return

  gpu.write(&self.vertex_buffers[frame_index], self.vertices[:self.vertex_count])
  gpu.write(&self.index_buffers[frame_index], self.indices[:self.index_count])
  gpu.begin_rendering(
    command_buffer,
    extent,
    nil,
    gpu.create_color_attachment_view(color_view, .LOAD, .STORE),
  )
  gpu.bind_graphics_pipeline(
    command_buffer,
    self.pipeline,
    self.pipeline_layout,
    texture_manager.descriptor_set,
  )
  projection := linalg.matrix_ortho3d_f32(0, f32(extent.width), f32(extent.height), 0, -1, 1)
  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    {.VERTEX},
    0,
    size_of(matrix[4, 4]f32),
    &projection,
  )
  viewport := vk.Viewport {
    y        = f32(extent.height),
    width    = f32(extent.width),
    height   = -f32(extent.height),
    maxDepth = 1,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  gpu.bind_vertex_index_buffers(
    command_buffer,
    self.vertex_buffers[frame_index].buffer,
    self.index_buffers[frame_index].buffer,
  )
  for &batch in self.batches {
    if batch.index_count == 0 do continue
    vk.CmdSetScissor(command_buffer, 0, 1, &batch.scissor)
    vk.CmdDrawIndexed(command_buffer, batch.index_count, 1, batch.first_index, 0, 0)
  }
  vk.CmdEndRendering(command_buffer)
}

@(private)
begin_batch :: proc(self: ^Renderer, scissor: vk.Rect2D) {
  end_batch(self)
  append(&self.batches, DrawBatch{first_index = self.index_count, scissor = scissor})
}

@(private)
end_batch :: proc(self: ^Renderer) {
  if len(self.batches) == 0 do return
  last := &self.batches[len(self.batches) - 1]
  last.index_count = self.index_count - last.first_index
}

// Append one axis-aligned quad. Quads beyond the buffer capacity are dropped.
@(private)
push_quad :: proc(
  self: ^Renderer,
  p0, p1, uv0, uv1: [2]f32,
  color: [4]u8,
  texture_id: u32,
) {
  if self.vertex_count + 4 > UI_MAX_VERTICES || self.index_count + 6 > UI_MAX_INDICES do return
  base := self.vertex_count
  self.vertices[base + 0] = {p0, uv0, color, texture_id}
  self.vertices[base + 1] = {{p1.x, p0.y}, {uv1.x, uv0.y}, color, texture_id}
  self.vertices[base + 2] = {p1, uv1, color, texture_id}
  self.vertices[base + 3] = {{p0.x, p1.y}, {uv0.x, uv1.y}, color, texture_id}
  quad := [6]u32{base, base + 1, base + 2, base, base + 2, base + 3}
  copy(self.indices[self.index_count:], quad[:])
  self.vertex_count += 4
  self.index_count += 6
}

@(private)
batch_commands :: proc(self: ^Renderer) {
  CommandSortKey :: struct {
    z_order:   i32,
    cmd_index: int,
  }
  keys := make([]CommandSortKey, len(self.commands), context.temp_allocator)
  for command, i in self.commands {
    z: i32
    switch c in command {
    case cmd.DrawQuadCommand: z = c.z_order
    case cmd.DrawMeshCommand: z = c.z_order
    case cmd.DrawTextCommand: z = c.z_order
    }
    keys[i] = {z, i}
  }
  slice.stable_sort_by(keys, proc(a, b: CommandSortKey) -> bool {
    return a.z_order < b.z_order
  })
  for key in keys {
    switch c in self.commands[key.cmd_index] {
    case cmd.DrawQuadCommand:
      push_quad(self, c.position, c.position + c.size, {0, 0}, {1, 1}, c.color, resolve_texture(self, c.texture_id))
    case cmd.DrawTextCommand:
      for g in c.glyphs {
        push_quad(self, c.position + g.p0, c.position + g.p1, g.uv0, g.uv1, g.color, self.font_atlas.index)
      }
    case cmd.DrawMeshCommand:
      push_mesh(self, c, resolve_texture(self, c.texture_id))
    }
  }
}

@(private)
resolve_texture :: proc(self: ^Renderer, texture_id: u32) -> u32 {
  return self.white_texture.index if texture_id == cmd.NO_TEXTURE else texture_id
}

@(private)
push_mesh :: proc(self: ^Renderer, mesh: cmd.DrawMeshCommand, texture_id: u32) {
  if self.vertex_count + u32(len(mesh.vertices)) > UI_MAX_VERTICES ||
     self.index_count + u32(len(mesh.indices)) > UI_MAX_INDICES {
    return
  }
  base := self.vertex_count
  for v in mesh.vertices {
    self.vertices[self.vertex_count] = {mesh.position + v.pos, v.uv, v.color, texture_id}
    self.vertex_count += 1
  }
  for idx in mesh.indices {
    self.indices[self.index_count] = base + idx
    self.index_count += 1
  }
}

// Convert the microui command list to quads in pixels. microui works in
// window coordinates; positions and clip rects are scaled by dpi_scale.
@(private)
batch_debug_ui :: proc(self: ^Renderer, extent: vk.Extent2D) {
  atlas_size := [2]f32{mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT}
  scale := self.dpi_scale
  quad :: proc(self: ^Renderer, dst, src: mu.Rect, color: mu.Color, atlas_size: [2]f32, scale: f32) {
    p0 := [2]f32{f32(dst.x), f32(dst.y)} * scale
    p1 := [2]f32{f32(dst.x + dst.w), f32(dst.y + dst.h)} * scale
    uv0 := [2]f32{f32(src.x), f32(src.y)} / atlas_size
    uv1 := [2]f32{f32(src.x + src.w), f32(src.y + src.h)} / atlas_size
    push_quad(self, p0, p1, uv0, uv1, {color.r, color.g, color.b, color.a}, self.debug_atlas.index)
  }
  iter: ^mu.Command
  for variant in mu.next_command_iterator(&self.debug_ctx, &iter) {
    switch c in variant {
    case ^mu.Command_Rect:
      quad(self, c.rect, mu.default_atlas[mu.DEFAULT_ATLAS_WHITE], c.color, atlas_size, scale)
    case ^mu.Command_Text:
      dst := mu.Rect{c.pos.x, c.pos.y, 0, 0}
      for ch in c.str {
        if ch & 0xc0 == 0x80 do continue
        src := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + min(int(ch), 127)]
        dst.w, dst.h = src.w, src.h
        quad(self, dst, src, c.color, atlas_size, scale)
        dst.x += dst.w
      }
    case ^mu.Command_Icon:
      src := mu.default_atlas[c.id]
      x := c.rect.x + (c.rect.w - src.w) / 2
      y := c.rect.y + (c.rect.h - src.h) / 2
      quad(self, {x, y, src.w, src.h}, src, c.color, atlas_size, scale)
    case ^mu.Command_Clip:
      begin_batch(self, clip_to_scissor(c.rect, scale, extent))
    case ^mu.Command_Jump:
      unreachable()
    }
  }
}

@(private)
clip_to_scissor :: proc(rect: mu.Rect, scale: f32, extent: vk.Extent2D) -> vk.Rect2D {
  x0 := clamp(i32(f32(rect.x) * scale), 0, i32(extent.width))
  y0 := clamp(i32(f32(rect.y) * scale), 0, i32(extent.height))
  x1 := clamp(i32(f32(rect.x + rect.w) * scale), x0, i32(extent.width))
  y1 := clamp(i32(f32(rect.y + rect.h) * scale), y0, i32(extent.height))
  return {offset = {x0, y0}, extent = {u32(x1 - x0), u32(y1 - y0)}}
}
