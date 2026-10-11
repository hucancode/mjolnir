// 2D overlay renderer. Draws two producers into the swapchain image after
// post-processing, with one pipeline and one vertex stream:
// - draw2d commands staged by the app (game UI), sorted by z_order;
// - the microui debug context, clipped per microui clip rect and scaled by
//   the window DPI.
package render

import "bindless"
import "gpu"
import "core:log"
import "core:math/linalg"
import "core:slice"
import mu "vendor:microui"
import vk "vendor:vulkan"

@(private)
UI_MAX_VERTICES :: 65536
@(private)
UI_MAX_INDICES :: 98304


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

OverlayRenderer :: struct {
  pipeline_layout: vk.PipelineLayout,
  pipeline:        vk.Pipeline,
  vertex_buffers:  [gpu.FRAMES_IN_FLIGHT]gpu.MutableBuffer(Vertex2D),
  index_buffers:   [gpu.FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  // Mapped buffers of the frame being recorded.
  vertices:        []Vertex2D,
  indices:         []u32,
  vertex_count:    u32,
  index_count:     u32,
  batches:         [dynamic]DrawBatch,
  // Staged draw2d commands, owned by the caller until the frame is recorded.
  commands:        []RenderCommand,
  white_texture:   bindless.Texture2DHandle, // drawn for NO_TEXTURE
  font_atlas:      bindless.Texture2DHandle, // sampled by text commands
  debug_ctx:       mu.Context,
  debug_open:      bool, // mu.begin ran this frame; frame closes it
  // Mouse buttons pressed over the debug UI, owned by it through release.
  debug_buttons:   bit_set[0 ..< 32],
  debug_atlas:     bindless.Texture2DHandle, // microui's builtin atlas
  dpi_scale:       f32,
}

// A run of indices drawn under one scissor rect. Textures are per vertex
// (bindless), so they never split a batch.
@(private)
DrawBatch :: struct {
  first_index: u32,
  index_count: u32,
  scissor:     vk.Rect2D,
}

overlay_init :: proc(
  self: ^OverlayRenderer,
  gctx: ^gpu.GPUContext,
  textures_set_layout: vk.DescriptorSetLayout,
  format: vk.Format,
  dpi_scale: f32,
) -> vk.Result {
  log.info("Initializing UI renderer pipeline...")
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

overlay_setup :: proc(
  self: ^OverlayRenderer,
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
  self.debug_atlas = allocate_alpha_texture(
    texture_manager,
    gctx,
    mu.default_atlas_alpha[:],
    mu.DEFAULT_ATLAS_WIDTH,
    mu.DEFAULT_ATLAS_HEIGHT,
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
overlay_teardown :: proc(self: ^OverlayRenderer, gctx: ^gpu.GPUContext) {
  for i in 0 ..< gpu.FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &self.vertex_buffers[i])
    gpu.mutable_buffer_destroy(gctx.device, &self.index_buffers[i])
  }
  self.white_texture = {}
  self.font_atlas = {}
  self.debug_atlas = {}
}

// Replace the font atlas texture with R8 pixels of size width x height.
overlay_upload_font_atlas :: proc(
  self: ^OverlayRenderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^bindless.TextureManager,
  pixels: []u8,
  width, height: u32,
) -> vk.Result {
  if self.font_atlas != {} {
    bindless.free_texture_2d(texture_manager, gctx, self.font_atlas)
    self.font_atlas = {}
  }
  self.font_atlas = allocate_alpha_texture(
    texture_manager,
    gctx,
    pixels,
    width,
    height,
  ) or_return
  return .SUCCESS
}

// Upload R8 coverage as white RGBA8 with alpha = coverage, so the shader
// multiplies every texture sample with the vertex color.
@(private)
allocate_alpha_texture :: proc(
  texture_manager: ^bindless.TextureManager,
  gctx: ^gpu.GPUContext,
  pixels: []u8,
  width, height: u32,
) -> (
  bindless.Texture2DHandle,
  vk.Result,
) {
  rgba := make([][4]u8, len(pixels))
  defer delete(rgba)
  for a, i in pixels do rgba[i] = {255, 255, 255, a}
  return bindless.allocate_texture_2d_with_data(
    texture_manager,
    gctx,
    raw_data(rgba),
    vk.DeviceSize(len(rgba) * size_of([4]u8)),
    vk.Extent2D{width, height},
    .R8G8B8A8_UNORM,
    {.SAMPLED},
  )
}

@(private)
create_pipeline :: proc(
  self: ^OverlayRenderer,
  gctx: ^gpu.GPUContext,
  format: vk.Format,
) -> vk.Result {
  vert_code := #load("shader/ui/vert.spv")
  frag_code := #load("shader/ui/frag.spv")
  vert_module := gpu.create_shader_module(gctx.device, vert_code) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(gctx.device, frag_code) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  bindings := [?]vk.VertexInputBindingDescription{VERTEX2D_BINDING_DESCRIPTION}
  color_formats := [?]vk.Format{format}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_ADDITIVE}
  self.pipeline = gpu.create_graphics_pipeline(
    gctx,
    {
      vert = vert_module,
      frag = frag_module,
      specialization = &bindless.SHADER_SPEC_CONSTANTS,
      vertex_bindings = bindings[:],
      vertex_attributes = VERTEX2D_ATTRIBUTE_DESCRIPTIONS[:],
      topology = .TRIANGLE_LIST,
      raster = gpu.DOUBLE_SIDED_RASTERIZER,
      blend = blend[:],
      color_formats = color_formats[:],
      layout = self.pipeline_layout,
    },
  ) or_return
  log.info("UI pipeline created successfully")
  return .SUCCESS
}

overlay_shutdown :: proc(self: ^OverlayRenderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  delete(self.batches)
}

// Record the overlay into `color_view` inside its own rendering scope. Draws
// the staged draw2d commands when `draw_commands` is set and the debug UI
// when `draw_debug` is set.
overlay_record :: proc(
  self: ^OverlayRenderer,
  texture_manager: ^bindless.TextureManager,
  command_buffer: vk.CommandBuffer,
  color_view: vk.ImageView,
  extent: vk.Extent2D,
  frame_index: u32,
  draw_commands, draw_debug: bool,
) {
  if !draw_commands && !draw_debug do return
  self.vertices = gpu.get_all(&self.vertex_buffers[frame_index])
  self.indices = gpu.get_all(&self.index_buffers[frame_index])
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

  gpu.begin_rendering(
    command_buffer,
    extent,
    nil,
    gpu.create_color_attachment(color_view, .LOAD, .STORE),
  )
  gpu.bind_pipeline(
    command_buffer,
    .GRAPHICS,
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
begin_batch :: proc(self: ^OverlayRenderer, scissor: vk.Rect2D) {
  end_batch(self)
  append(&self.batches, DrawBatch{first_index = self.index_count, scissor = scissor})
}

@(private)
end_batch :: proc(self: ^OverlayRenderer) {
  if len(self.batches) == 0 do return
  last := &self.batches[len(self.batches) - 1]
  last.index_count = self.index_count - last.first_index
}

// Append one axis-aligned quad. Quads beyond the buffer capacity are dropped.
@(private)
push_quad :: proc(
  self: ^OverlayRenderer,
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
batch_commands :: proc(self: ^OverlayRenderer) {
  CommandSortKey :: struct {
    z_order:   i32,
    cmd_index: int,
  }
  keys := make([]CommandSortKey, len(self.commands), context.temp_allocator)
  for command, i in self.commands {
    z: i32
    switch c in command {
    case DrawQuadCommand: z = c.z_order
    case DrawMeshCommand: z = c.z_order
    case DrawTextCommand: z = c.z_order
    }
    keys[i] = {z, i}
  }
  slice.stable_sort_by(keys, proc(a, b: CommandSortKey) -> bool {
    return a.z_order < b.z_order
  })
  for key in keys {
    switch c in self.commands[key.cmd_index] {
    case DrawQuadCommand:
      push_quad(self, c.position, c.position + c.size, {0, 0}, {1, 1}, c.color, resolve_texture(self, c.texture_id))
    case DrawTextCommand:
      for g in c.glyphs {
        push_quad(self, c.position + g.p0, c.position + g.p1, g.uv0, g.uv1, g.color, self.font_atlas.index)
      }
    case DrawMeshCommand:
      push_mesh(self, c, resolve_texture(self, c.texture_id))
    }
  }
}

@(private)
resolve_texture :: proc(self: ^OverlayRenderer, texture_id: u32) -> u32 {
  return self.white_texture.index if texture_id == NO_TEXTURE else texture_id
}

@(private)
push_mesh :: proc(self: ^OverlayRenderer, mesh: DrawMeshCommand, texture_id: u32) {
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
batch_debug_ui :: proc(self: ^OverlayRenderer, extent: vk.Extent2D) {
  atlas_size := [2]f32{mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT}
  scale := self.dpi_scale
  quad :: proc(self: ^OverlayRenderer, dst, src: mu.Rect, color: mu.Color, atlas_size: [2]f32, scale: f32) {
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
