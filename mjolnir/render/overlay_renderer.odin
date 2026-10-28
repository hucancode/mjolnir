package render

import "../anchor"
import "../font"
import "core:log"
import "core:slice"

// Positions and sizes are window coordinates (window_size), as input.State reports the cursor;
// render scales them by the DPI scale. A zero `clip` is the whole window.

// DrawQuadCommand draws a solid or textured rectangle.
DrawQuadCommand :: struct {
  position:   [2]f32,
  size:       [2]f32,
  color:      [4]u8,
  texture:    TextureHandle,
}

// DrawTextCommand draws one line of text in stage_overlay's font, its top-left at position,
// size pixels tall.
DrawTextCommand :: struct {
  text:     string,
  position: [2]f32,
  size:     f32,
  color:    [4]u8,
}

// DrawMeshCommand draws an indexed 2D triangle mesh offset by position.
DrawMeshCommand :: struct {
  position:   [2]f32,
  vertices:   []Vertex2D,
  indices:    []u32,
  texture:    TextureHandle,
}

// RenderCommand is one 2D draw staged with stage_overlay: a shape, drawn in z_order
// (ascending, stable) inside clip.
RenderCommand :: struct {
  shape:   union {
    DrawQuadCommand,
    DrawTextCommand,
    DrawMeshCommand,
  },
  z_order: i32,
  clip:    anchor.Rect,
}

// The overlay batches 2D output drawn into the swapchain image after post-processing, one
// vertex stream: draw2d commands staged by the app (sorted by z_order, clipped per command).
// A batch is one scissor and one texture.

// Empties the overlay: what frame draws is staged again for the next.
@(private)
overlay_clear :: proc(self: ^Renderer) {
  clear(&self.ui_vertices)
  clear(&self.ui_indices)
  clear(&self.ui_batches)
}

// A batch takes the texture of its first quad.
@(private)
begin_batch :: proc(self: ^Renderer, scissor: [4]i32) {
  end_batch(self)
  append(&self.ui_batches, UIBatch{first_index = u32(len(self.ui_indices)), scissor = scissor})
}

// A texture change starts a batch in the same scissor; NO_TEXTURE draws white.
@(private)
use_texture :: proc(self: ^Renderer, texture: TextureHandle) {
  if len(self.ui_batches) == 0 do return
  texture := self.white if texture == NO_TEXTURE else texture
  last := &self.ui_batches[len(self.ui_batches) - 1]
  if last.first_index == u32(len(self.ui_indices)) {
    last.texture = texture
  } else if last.texture != texture {
    begin_batch(self, last.scissor)
    self.ui_batches[len(self.ui_batches) - 1].texture = texture
  }
}

@(private)
end_batch :: proc(self: ^Renderer) {
  if len(self.ui_batches) == 0 do return
  last := &self.ui_batches[len(self.ui_batches) - 1]
  last.index_count = u32(len(self.ui_indices)) - last.first_index
}

// quads beyond the buffer capacity are dropped
@(private)
push_quad :: proc(
  self: ^Renderer,
  p0, p1, uv0, uv1: [2]f32,
  color: [4]u8,
  texture: TextureHandle,
) {
  if len(self.ui_vertices) + 4 > UI_MAX_VERTICES || len(self.ui_indices) + 6 > UI_MAX_INDICES do return
  use_texture(self, texture)
  base := u32(len(self.ui_vertices))
  append(
    &self.ui_vertices,
    Vertex2D{p0, uv0, color},
    Vertex2D{{p1.x, p0.y}, {uv1.x, uv0.y}, color},
    Vertex2D{p1, uv1, color},
    Vertex2D{{p0.x, p1.y}, {uv0.x, uv1.y}, color},
  )
  append(&self.ui_indices, base, base + 1, base + 2, base, base + 2, base + 3)
}

// Text draws nothing without a font.
@(private)
batch_commands :: proc(self: ^Renderer, commands: []RenderCommand, text_font: ^font.Font, extent: [2]u32) {
  CommandSortKey :: struct {
    z_order:   i32,
    cmd_index: int,
  }
  scale := self.dpi_scale
  // laid out first: new glyphs grow the atlas, which uploads before any uv is divided by its size
  glyphs := make([][]font.Glyph, len(commands), context.temp_allocator)
  atlas_size: [2]f32
  if text_font != nil {
    for command, i in commands {
      c := command.shape.(DrawTextCommand) or_continue
      run := make([dynamic]font.Glyph, context.temp_allocator)
      font.glyphs(text_font, c.text, c.position * scale, c.size * scale, &run)
      glyphs[i] = run[:]
    }
    atlas_size = sync_font_atlas(self, text_font)
  }
  keys := make([]CommandSortKey, len(commands), context.temp_allocator)
  for command, i in commands do keys[i] = {command.z_order, i}
  slice.stable_sort_by(keys, proc(a, b: CommandSortKey) -> bool {
    return a.z_order < b.z_order
  })
  scissor := [4]i32{-1, -1, 0, 0}
  for key in keys {
    command := &commands[key.cmd_index]
    // a new batch wherever the clip changes
    if s := clip_scissor({command.clip.pos * scale, command.clip.size * scale}, extent); s != scissor {
      scissor = s
      begin_batch(self, s)
    }
    switch c in command.shape {
    case DrawQuadCommand:
      p0 := c.position * scale
      push_quad(self, p0, p0 + c.size * scale, {0, 0}, {1, 1}, c.color, c.texture)
    case DrawTextCommand:
      if self.ui_font_atlas == 0 do continue
      for g in glyphs[key.cmd_index] {
        push_quad(self, g.p0, g.p1, g.uv0 / atlas_size, g.uv1 / atlas_size, c.color, self.ui_font_atlas)
      }
    case DrawMeshCommand:
      push_mesh(self, c, scale)
    }
  }
}

// Uploads the font's atlas unless the one uploaded is its current version; returns its size.
@(private)
sync_font_atlas :: proc(self: ^Renderer, text_font: ^font.Font) -> [2]f32 {
  pixels, size, version := font.atlas(text_font)
  if version != self.ui_font_version || self.ui_font_atlas == 0 {
    self.ui_font_version = version
    texture_destroy(self, self.ui_font_atlas)
    ok: bool
    self.ui_font_atlas, ok = allocate_texture(self, {extent = size, format = .A8, usage = {.SAMPLED}}, pixels)
    if !ok do log.errorf("Font atlas upload failed")
  }
  return {f32(size.x), f32(size.y)}
}

@(private)
clip_scissor :: proc(clip: anchor.Rect, extent: [2]u32) -> [4]i32 {
  if clip == {} do return {0, 0, i32(extent.x), i32(extent.y)}
  x0 := clamp(i32(clip.pos.x), 0, i32(extent.x))
  y0 := clamp(i32(clip.pos.y), 0, i32(extent.y))
  x1 := clamp(i32(clip.pos.x + clip.size.x), x0, i32(extent.x))
  y1 := clamp(i32(clip.pos.y + clip.size.y), y0, i32(extent.y))
  return {x0, y0, x1 - x0, y1 - y0}
}

@(private)
push_mesh :: proc(self: ^Renderer, mesh: DrawMeshCommand, scale: f32) {
  if len(self.ui_vertices) + len(mesh.vertices) > UI_MAX_VERTICES || len(self.ui_indices) + len(mesh.indices) > UI_MAX_INDICES do return
  use_texture(self, mesh.texture)
  base := u32(len(self.ui_vertices))
  for v in mesh.vertices do append(&self.ui_vertices, Vertex2D{(mesh.position + v.pos) * scale, v.uv, v.color})
  for idx in mesh.indices do append(&self.ui_indices, base + idx)
}
