package render

import "../font"
import "core:log"
import "core:slice"

// Positions and sizes are window coordinates, as input.State and ui report them; render
// scales them by the DPI scale. `clip` is (x, y, w, h), zero = the whole window.

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
  clip:    [4]f32,
}


// The overlay batches 2D output drawn into the swapchain image after post-processing, one
// vertex stream: draw2d commands staged by the app (sorted by z_order, clipped per command).
// A batch is one scissor and one texture.
@(private)
overlay_init :: proc(self: ^Renderer) -> bool {
  self.ui_batches = make([dynamic]UIBatch, 0, 64)
  self.ui_vertices = make([]Vertex2D, UI_MAX_VERTICES)
  self.ui_indices = make([]u32, UI_MAX_INDICES)
  return true
}

@(private)
allocate_alpha_texture :: proc(self: ^Renderer, pixels: []u8, width, height: u32) -> (TextureHandle, bool) {
  return allocate_texture(self, {extent = {width, height}, format = .A8, usage = {.SAMPLED}}, pixels)
}

// Empties the overlay: what frame draws is staged again for the next.
@(private)
overlay_clear :: proc(self: ^Renderer) {
  self.ui_vertex_count = 0
  self.ui_index_count = 0
  clear(&self.ui_batches)
}

// The staged draw2d commands draw only with a main camera.
@(private)
overlay_flush :: proc(self: ^Renderer) {
  if _, ok := main_camera(self); !ok do overlay_clear(self)
  end_batch(self)
}

// A batch takes the texture of its first quad.
@(private)
begin_batch :: proc(self: ^Renderer, scissor: [4]i32) {
  end_batch(self)
  append(&self.ui_batches, UIBatch{first_index = self.ui_index_count, scissor = scissor})
}

// A texture change starts a batch in the same scissor.
@(private)
use_texture :: proc(self: ^Renderer, texture: TextureHandle) {
  if len(self.ui_batches) == 0 do return
  last := &self.ui_batches[len(self.ui_batches) - 1]
  if last.first_index == self.ui_index_count {
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
  last.index_count = self.ui_index_count - last.first_index
}

// quads beyond the buffer capacity are dropped
@(private)
push_quad :: proc(
  self: ^Renderer,
  p0, p1, uv0, uv1: [2]f32,
  color: [4]u8,
  texture: TextureHandle,
) {
  if int(self.ui_vertex_count) + 4 > len(self.ui_vertices) || int(self.ui_index_count) + 6 > len(self.ui_indices) do return
  use_texture(self, texture)
  vertices := self.ui_vertices
  base := self.ui_vertex_count
  vertices[base + 0] = {p0, uv0, color}
  vertices[base + 1] = {{p1.x, p0.y}, {uv1.x, uv0.y}, color}
  vertices[base + 2] = {p1, uv1, color}
  vertices[base + 3] = {{p0.x, p1.y}, {uv0.x, uv1.y}, color}
  quad := [6]u32{base, base + 1, base + 2, base, base + 2, base + 3}
  copy(self.ui_indices[self.ui_index_count:], quad[:])
  self.ui_vertex_count += 4
  self.ui_index_count += 6
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
  if text_font != nil {
    for command, i in commands {
      c := command.shape.(DrawTextCommand) or_continue
      run := make([dynamic]font.Glyph, context.temp_allocator)
      font.glyphs(text_font, c.text, c.position * scale, c.size * scale, &run)
      glyphs[i] = run[:]
    }
    sync_font_atlas(self, text_font)
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
    if s := clip_scissor(command.clip * scale, extent); s != scissor {
      scissor = s
      begin_batch(self, s)
    }
    switch c in command.shape {
    case DrawQuadCommand:
      p0 := c.position * scale
      push_quad(self, p0, p0 + c.size * scale, {0, 0}, {1, 1}, c.color, resolve_texture(self, c.texture))
    case DrawTextCommand:
      if self.ui_font_atlas == 0 do continue
      atlas_size := self.ui_font_atlas_size
      for g in glyphs[key.cmd_index] {
        push_quad(self, g.p0, g.p1, g.uv0 / atlas_size, g.uv1 / atlas_size, c.color, self.ui_font_atlas)
      }
    case DrawMeshCommand:
      push_mesh(self, c, scale, resolve_texture(self, c.texture))
    }
  }
}

// Uploads the font's atlas when glyphs were added to it since the last upload.
@(private)
sync_font_atlas :: proc(self: ^Renderer, text_font: ^font.Font) {
  pixels, size, changed := font.atlas(text_font)
  if !changed && self.ui_font_atlas != 0 do return
  texture_destroy(self, self.ui_font_atlas)
  ok: bool
  self.ui_font_atlas, ok = allocate_alpha_texture(self, pixels, size.x, size.y)
  self.ui_font_atlas_size = {f32(size.x), f32(size.y)}
  if !ok do log.errorf("Font atlas upload failed")
}

@(private)
clip_scissor :: proc(clip: [4]f32, extent: [2]u32) -> [4]i32 {
  if clip == {} do return {0, 0, i32(extent.x), i32(extent.y)}
  x0 := clamp(i32(clip.x), 0, i32(extent.x))
  y0 := clamp(i32(clip.y), 0, i32(extent.y))
  x1 := clamp(i32(clip.x + clip.z), x0, i32(extent.x))
  y1 := clamp(i32(clip.y + clip.w), y0, i32(extent.y))
  return {x0, y0, x1 - x0, y1 - y0}
}

@(private)
resolve_texture :: proc(self: ^Renderer, texture: TextureHandle) -> TextureHandle {
  return self.white if texture == NO_TEXTURE else texture
}

@(private)
push_mesh :: proc(self: ^Renderer, mesh: DrawMeshCommand, scale: f32, texture: TextureHandle) {
  if int(self.ui_vertex_count) + len(mesh.vertices) > len(self.ui_vertices) ||
     int(self.ui_index_count) + len(mesh.indices) > len(self.ui_indices) {
    return
  }
  use_texture(self, texture)
  vertices, indices := self.ui_vertices, self.ui_indices
  base := self.ui_vertex_count
  for v in mesh.vertices {
    vertices[self.ui_vertex_count] = {(mesh.position + v.pos) * scale, v.uv, v.color}
    self.ui_vertex_count += 1
  }
  for idx in mesh.indices {
    indices[self.ui_index_count] = base + idx
    self.ui_index_count += 1
  }
}
