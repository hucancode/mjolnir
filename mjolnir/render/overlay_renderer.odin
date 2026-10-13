package render

import "../font"
import "gpu"
import "core:math/linalg"
import "core:slice"
import mu "vendor:microui"
import vk "vendor:vulkan"

// Command positions are framebuffer pixels. Each draws inside its `clip`
// rect (x, y, width, height), the whole framebuffer when zero.

// DrawQuadCommand draws a solid or textured rectangle.
DrawQuadCommand :: struct {
  position:   [2]f32,
  size:       [2]f32,
  color:      [4]u8,
  texture_id: u32,
  z_order:    i32,
  clip:       [4]f32,
}

// A run of glyphs of the DrawList's font atlas (font.glyphs), in one color.
DrawTextCommand :: struct {
  glyphs:  []font.Glyph,
  color:   [4]u8,
  z_order: i32,
  clip:    [4]f32,
}

// Vertex2D is one vertex of a DrawMeshCommand.
Vertex2D :: struct {
  pos:        [2]f32,
  uv:         [2]f32,
  color:      [4]u8,
  texture_id: u32,
}

// DrawMeshCommand draws an indexed 2D triangle mesh offset by position.
DrawMeshCommand :: struct {
  position:   [2]f32,
  vertices:   []Vertex2D,
  indices:    []u32,
  texture_id: u32,
  z_order:    i32,
  clip:       [4]f32,
}

// RenderCommand is one 2D draw staged through DrawList.
RenderCommand :: union {
  DrawQuadCommand,
  DrawTextCommand,
  DrawMeshCommand,
}

// One frame of 2D output. `atlas` holds the producer's R8 font atlas
// (`atlas_size` texels, font.atlas) only on frames where it changed;
// otherwise it is empty.
DrawList :: struct {
  commands:   []RenderCommand,
  atlas:      []u8,
  atlas_size: [2]u32,
}

@(private)
UI_MAX_VERTICES :: 65536
@(private)
UI_MAX_INDICES :: 98304

@(private = "file")
VERTEX2D_ATTRIBUTE_DESCRIPTIONS := [?]vk.VertexInputAttributeDescription {
  {binding = 0, location = 0, format = .R32G32_SFLOAT,  offset = u32(offset_of(Vertex2D, pos))},
  {binding = 0, location = 1, format = .R32G32_SFLOAT,  offset = u32(offset_of(Vertex2D, uv))},
  {binding = 0, location = 2, format = .R8G8B8A8_UNORM, offset = u32(offset_of(Vertex2D, color))},
  {binding = 0, location = 3, format = .R32_UINT,       offset = u32(offset_of(Vertex2D, texture_id))},
}

// OverlayRenderer draws 2D output into the swapchain image after
// post-processing, with one pipeline and one vertex stream: draw2d commands
// staged by the app (sorted by z_order, clipped per command) and the microui
// debug context (clipped per microui clip rect, scaled by the window DPI).
OverlayRenderer :: struct {
  vertex_buffers:  [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
  index_buffers:   [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
  vertex_count:    u32,
  index_count:     u32,
  batches:         [dynamic]DrawBatch,
  // Staged draw2d commands, owned by the caller until the frame is recorded.
  commands:        []RenderCommand,
  white_texture:   TextureHandle, // drawn for NO_TEXTURE
  font_atlas:      TextureHandle, // sampled by text commands
  // CPU copy of the font atlas, uploaded by flush when dirty
  atlas_pixels:    []u8,
  atlas_extent:    [2]u32,
  atlas_dirty:     bool,
  debug_ctx:       mu.Context,
  debug_open:      bool, // mu.begin ran this frame; frame closes it
  // Mouse buttons pressed over the debug UI, owned by it through release.
  debug_buttons:   bit_set[0 ..< 32],
  debug_atlas:     TextureHandle, // microui's builtin atlas
  dpi_scale:       f32,
}

// Textures are per vertex (bindless), so they never split a batch.
@(private)
DrawBatch :: struct {
  first_index: u32,
  index_count: u32,
  scissor:     vk.Rect2D,
}

@(private)
overlay_init :: proc(r: ^Renderer, dpi_scale: f32) -> vk.Result {
  self := &r.ui
  self.batches = make([dynamic]DrawBatch, 0, 64)
  self.dpi_scale = dpi_scale
  mu.init(&self.debug_ctx)
  self.debug_ctx.text_width = mu.default_atlas_text_width
  self.debug_ctx.text_height = mu.default_atlas_text_height
  bindings := [?]vk.VertexInputBindingDescription{{binding = 0, stride = size_of(Vertex2D), inputRate = .VERTEX}}
  color_formats := [?]vk.Format{r.swapchain.format.format}
  blend := [?]vk.PipelineColorBlendAttachmentState{gpu.BLEND_ALPHA}
  r.pipelines[.OVERLAY] = gpu.create_graphics_pipeline(
    &r.gctx,
    {
      vert = #load("shader/ui/vert.spv"),
      frag = #load("shader/ui/frag.spv"),
      vertex_bindings = bindings[:],
      vertex_attributes = VERTEX2D_ATTRIBUTE_DESCRIPTIONS[:],
      topology = .TRIANGLE_LIST,
      blend = blend[:],
      color_formats = color_formats[:],
      layout = r.scene.layout,
    },
  ) or_return
  return .SUCCESS
}

@(private)
overlay_setup :: proc(r: ^Renderer) -> vk.Result {
  self := &r.ui
  white_pixel := [4]u8{255, 255, 255, 255}
  self.white_texture = allocate_texture(r, {1, 1}, .R8G8B8A8_UNORM, {.SAMPLED}, data = white_pixel[:]) or_return
  self.debug_atlas = allocate_alpha_texture(r, mu.default_atlas_alpha[:], mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT) or_return
  for i in 0 ..< gpu.FRAMES_IN_FLIGHT {
    self.vertex_buffers[i] = gpu.buffer_create(&r.gctx, UI_MAX_VERTICES * size_of(Vertex2D), {.VERTEX_BUFFER}) or_return
    self.index_buffers[i] = gpu.buffer_create(&r.gctx, UI_MAX_INDICES * size_of(u32), {.INDEX_BUFFER}) or_return
  }
  return .SUCCESS
}

@(private)
overlay_teardown :: proc(r: ^Renderer) {
  self := &r.ui
  for i in 0 ..< gpu.FRAMES_IN_FLIGHT {
    gpu.buffer_destroy(r.gctx.device, &self.vertex_buffers[i])
    gpu.buffer_destroy(r.gctx.device, &self.index_buffers[i])
  }
  self.white_texture = 0
  self.font_atlas = 0
  self.debug_atlas = 0
}

// R8 coverage samples as white with alpha = coverage, so the shader multiplies every sample with the vertex color.
@(private)
allocate_alpha_texture :: proc(r: ^Renderer, pixels: []u8, width, height: u32) -> (TextureHandle, vk.Result) {
  return allocate_texture(
    r,
    {width, height},
    .R8_UNORM,
    {.SAMPLED},
    data = pixels,
    swizzle = {r = .ONE, g = .ONE, b = .ONE, a = .R},
  )
}

@(private)
overlay_record :: proc(
  r: ^Renderer,
  command_buffer: vk.CommandBuffer,
  color_view: vk.ImageView,
  extent: vk.Extent2D,
  frame_index: u32,
  draw_commands, draw_debug: bool,
) {
  if !draw_commands && !draw_debug do return
  self := &r.ui
  self.vertex_count = 0
  self.index_count = 0
  clear(&self.batches)
  full := vk.Rect2D{extent = extent}
  if draw_commands do batch_commands(self, extent, frame_index)
  if draw_debug {
    begin_batch(self, full)
    batch_debug_ui(self, extent, frame_index)
  }
  end_batch(self)
  if self.index_count == 0 do return

  gpu.begin_rendering(
    command_buffer,
    extent,
    nil,
    gpu.create_color_attachment(color_view, .LOAD, .STORE),
  )
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, r.pipelines[.OVERLAY])
  // pixel y grows down, as clip-space y does
  projection := linalg.matrix_ortho3d_f32(0, f32(extent.width), 0, f32(extent.height), -1, 1)
  push_constants(r, command_buffer, &projection)
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

// quads beyond the buffer capacity are dropped
@(private)
push_quad :: proc(
  self: ^OverlayRenderer,
  frame_index: u32,
  p0, p1, uv0, uv1: [2]f32,
  color: [4]u8,
  texture_id: u32,
) {
  if self.vertex_count + 4 > UI_MAX_VERTICES || self.index_count + 6 > UI_MAX_INDICES do return
  vertices := gpu.mapped(&self.vertex_buffers[frame_index], Vertex2D)
  base := self.vertex_count
  vertices[base + 0] = {p0, uv0, color, texture_id}
  vertices[base + 1] = {{p1.x, p0.y}, {uv1.x, uv0.y}, color, texture_id}
  vertices[base + 2] = {p1, uv1, color, texture_id}
  vertices[base + 3] = {{p0.x, p1.y}, {uv0.x, uv1.y}, color, texture_id}
  quad := [6]u32{base, base + 1, base + 2, base, base + 2, base + 3}
  copy(gpu.mapped(&self.index_buffers[frame_index], u32)[self.index_count:], quad[:])
  self.vertex_count += 4
  self.index_count += 6
}

@(private)
batch_commands :: proc(self: ^OverlayRenderer, extent: vk.Extent2D, frame_index: u32) {
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
  atlas_size := [2]f32{f32(self.atlas_extent.x), f32(self.atlas_extent.y)}
  scissor := vk.Rect2D{{-1, -1}, {}}
  for key in keys {
    clip: [4]f32
    switch c in self.commands[key.cmd_index] {
    case DrawQuadCommand: clip = c.clip
    case DrawMeshCommand: clip = c.clip
    case DrawTextCommand: clip = c.clip
    }
    // a new batch wherever the clip changes
    if s := clip_scissor(clip, extent); s != scissor {
      scissor = s
      begin_batch(self, s)
    }
    switch c in self.commands[key.cmd_index] {
    case DrawQuadCommand:
      push_quad(self, frame_index, c.position, c.position + c.size, {0, 0}, {1, 1}, c.color, resolve_texture(self, c.texture_id))
    case DrawTextCommand:
      for g in c.glyphs {
        push_quad(self, frame_index, g.p0, g.p1, g.uv0 / atlas_size, g.uv1 / atlas_size, c.color, u32(self.font_atlas))
      }
    case DrawMeshCommand:
      push_mesh(self, frame_index, c, resolve_texture(self, c.texture_id))
    }
  }
}

@(private)
clip_scissor :: proc(clip: [4]f32, extent: vk.Extent2D) -> vk.Rect2D {
  if clip == {} do return {extent = extent}
  x0 := clamp(i32(clip.x), 0, i32(extent.width))
  y0 := clamp(i32(clip.y), 0, i32(extent.height))
  x1 := clamp(i32(clip.x + clip.z), x0, i32(extent.width))
  y1 := clamp(i32(clip.y + clip.w), y0, i32(extent.height))
  return {offset = {x0, y0}, extent = {u32(x1 - x0), u32(y1 - y0)}}
}

@(private)
resolve_texture :: proc(self: ^OverlayRenderer, texture_id: u32) -> u32 {
  return u32(self.white_texture) if texture_id == NO_TEXTURE else texture_id
}

@(private)
push_mesh :: proc(self: ^OverlayRenderer, frame_index: u32, mesh: DrawMeshCommand, texture_id: u32) {
  if self.vertex_count + u32(len(mesh.vertices)) > UI_MAX_VERTICES ||
     self.index_count + u32(len(mesh.indices)) > UI_MAX_INDICES {
    return
  }
  vertices := gpu.mapped(&self.vertex_buffers[frame_index], Vertex2D)
  indices := gpu.mapped(&self.index_buffers[frame_index], u32)
  base := self.vertex_count
  for v in mesh.vertices {
    vertices[self.vertex_count] = {mesh.position + v.pos, v.uv, v.color, texture_id}
    self.vertex_count += 1
  }
  for idx in mesh.indices {
    indices[self.index_count] = base + idx
    self.index_count += 1
  }
}

// microui works in window coordinates; scaled by dpi_scale
@(private)
batch_debug_ui :: proc(self: ^OverlayRenderer, extent: vk.Extent2D, frame_index: u32) {
  atlas_size := [2]f32{mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT}
  scale := self.dpi_scale
  quad :: proc(self: ^OverlayRenderer, frame_index: u32, dst, src: mu.Rect, color: mu.Color, atlas_size: [2]f32, scale: f32) {
    p0 := [2]f32{f32(dst.x), f32(dst.y)} * scale
    p1 := [2]f32{f32(dst.x + dst.w), f32(dst.y + dst.h)} * scale
    uv0 := [2]f32{f32(src.x), f32(src.y)} / atlas_size
    uv1 := [2]f32{f32(src.x + src.w), f32(src.y + src.h)} / atlas_size
    push_quad(self, frame_index, p0, p1, uv0, uv1, {color.r, color.g, color.b, color.a}, u32(self.debug_atlas))
  }
  iter: ^mu.Command
  for variant in mu.next_command_iterator(&self.debug_ctx, &iter) {
    switch c in variant {
    case ^mu.Command_Rect:
      quad(self, frame_index, c.rect, mu.default_atlas[mu.DEFAULT_ATLAS_WHITE], c.color, atlas_size, scale)
    case ^mu.Command_Text:
      dst := mu.Rect{c.pos.x, c.pos.y, 0, 0}
      for ch in c.str {
        if ch & 0xc0 == 0x80 do continue
        src := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + min(int(ch), 127)]
        dst.w, dst.h = src.w, src.h
        quad(self, frame_index, dst, src, c.color, atlas_size, scale)
        dst.x += dst.w
      }
    case ^mu.Command_Icon:
      src := mu.default_atlas[c.id]
      x := c.rect.x + (c.rect.w - src.w) / 2
      y := c.rect.y + (c.rect.h - src.h) / 2
      quad(self, frame_index, {x, y, src.w, src.h}, src, c.color, atlas_size, scale)
    case ^mu.Command_Clip:
      begin_batch(self, clip_scissor([4]f32{f32(c.rect.x), f32(c.rect.y), f32(c.rect.w), f32(c.rect.h)} * scale, extent))
    case ^mu.Command_Jump:
      unreachable()
    }
  }
}


