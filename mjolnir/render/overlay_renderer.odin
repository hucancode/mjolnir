package render

import "../font"
import "core:slice"
import mu "vendor:microui"

// Positions are framebuffer pixels; `clip` is (x, y, w, h), zero = whole framebuffer.

// DrawQuadCommand draws a solid or textured rectangle.
DrawQuadCommand :: struct {
  position:   [2]f32,
  size:       [2]f32,
  color:      [4]u8,
  texture_id: u32,
}

// A run of glyphs of the DrawList's font atlas (font.glyphs), in one color.
DrawTextCommand :: struct {
  glyphs: []font.Glyph,
  color:  [4]u8,
}

// DrawMeshCommand draws an indexed 2D triangle mesh offset by position.
DrawMeshCommand :: struct {
  position:   [2]f32,
  vertices:   []Vertex2D,
  indices:    []u32,
  texture_id: u32,
}

// RenderCommand is one 2D draw staged through DrawList: a shape, drawn in z_order
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

// One frame of 2D output. `atlas` holds the producer's R8 font atlas
// (`atlas_size` texels, font.atlas) only on frames where it changed;
// otherwise it is empty.
DrawList :: struct {
  commands:   []RenderCommand,
  atlas:      []u8,
  atlas_size: [2]u32,
}

// The overlay batches 2D output drawn into the swapchain image after post-processing, one
// vertex stream: draw2d commands staged by the app (sorted by z_order, clipped per command)
// and the microui debug context (clipped per microui clip rect, scaled by the window DPI). A
// batch is one scissor and one texture.
@(private)
overlay_init :: proc(r: ^Renderer) -> bool {
  r.ui_batches = make([dynamic]UIBatch, 0, 64)
  r.ui_vertices = make([]Vertex2D, UI_MAX_VERTICES)
  r.ui_indices = make([]u32, UI_MAX_INDICES)
  mu.init(&r.ui_debug_ctx)
  r.ui_debug_ctx.text_width = mu.default_atlas_text_width
  r.ui_debug_ctx.text_height = mu.default_atlas_text_height
  r.ui_debug_atlas = allocate_alpha_texture(r, mu.default_atlas_alpha[:], mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT) or_return
  return true
}

@(private)
allocate_alpha_texture :: proc(r: ^Renderer, pixels: []u8, width, height: u32) -> (TextureHandle, bool) {
  return allocate_texture(r, {extent = {width, height}, format = .A8, usage = {.SAMPLED}}, pixels)
}

// Empties the overlay: what frame draws is staged again for the next.
@(private)
overlay_clear :: proc(r: ^Renderer) {
  r.ui_vertex_count = 0
  r.ui_index_count = 0
  clear(&r.ui_batches)
}

// Adds the debug UI over the staged draw2d commands, which draw only with a main camera.
@(private)
overlay_flush :: proc(r: ^Renderer, draw_debug: bool) {
  if _, ok := main_camera(r); !ok do overlay_clear(r)
  if draw_debug {
    extent := dev.extent(&r.gpu)
    begin_batch(r, {0, 0, i32(extent.x), i32(extent.y)})
    batch_debug_ui(r, extent)
  }
  end_batch(r)
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

// Text draws nothing until a font atlas is staged.
@(private)
batch_commands :: proc(self: ^Renderer, commands: []RenderCommand, extent: [2]u32) {
  CommandSortKey :: struct {
    z_order:   i32,
    cmd_index: int,
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
    if s := clip_scissor(command.clip, extent); s != scissor {
      scissor = s
      begin_batch(self, s)
    }
    switch c in command.shape {
    case DrawQuadCommand:
      push_quad(self, c.position, c.position + c.size, {0, 0}, {1, 1}, c.color, resolve_texture(self, c.texture_id))
    case DrawTextCommand:
      if self.ui_font_atlas == 0 do continue
      atlas_size := self.ui_font_atlas_size
      for g in c.glyphs {
        push_quad(self, g.p0, g.p1, g.uv0 / atlas_size, g.uv1 / atlas_size, c.color, self.ui_font_atlas)
      }
    case DrawMeshCommand:
      push_mesh(self, c, resolve_texture(self, c.texture_id))
    }
  }
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
resolve_texture :: proc(self: ^Renderer, texture_id: u32) -> TextureHandle {
  return self.white if texture_id == NO_TEXTURE else TextureHandle(texture_id)
}

@(private)
push_mesh :: proc(self: ^Renderer, mesh: DrawMeshCommand, texture: TextureHandle) {
  if int(self.ui_vertex_count) + len(mesh.vertices) > len(self.ui_vertices) ||
     int(self.ui_index_count) + len(mesh.indices) > len(self.ui_indices) {
    return
  }
  use_texture(self, texture)
  vertices, indices := self.ui_vertices, self.ui_indices
  base := self.ui_vertex_count
  for v in mesh.vertices {
    vertices[self.ui_vertex_count] = {mesh.position + v.pos, v.uv, v.color}
    self.ui_vertex_count += 1
  }
  for idx in mesh.indices {
    indices[self.ui_index_count] = base + idx
    self.ui_index_count += 1
  }
}

// microui works in window coordinates; scaled by dpi_scale
@(private)
batch_debug_ui :: proc(self: ^Renderer, extent: [2]u32) {
  atlas_size := [2]f32{mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT}
  scale := self.dpi_scale
  quad :: proc(self: ^Renderer, dst, src: mu.Rect, color: mu.Color, atlas_size: [2]f32, scale: f32) {
    p0 := [2]f32{f32(dst.x), f32(dst.y)} * scale
    p1 := [2]f32{f32(dst.x + dst.w), f32(dst.y + dst.h)} * scale
    uv0 := [2]f32{f32(src.x), f32(src.y)} / atlas_size
    uv1 := [2]f32{f32(src.x + src.w), f32(src.y + src.h)} / atlas_size
    push_quad(self, p0, p1, uv0, uv1, {color.r, color.g, color.b, color.a}, self.ui_debug_atlas)
  }
  iter: ^mu.Command
  for variant in mu.next_command_iterator(&self.ui_debug_ctx, &iter) {
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
      begin_batch(self, clip_scissor([4]f32{f32(c.rect.x), f32(c.rect.y), f32(c.rect.w), f32(c.rect.h)} * scale, extent))
    case ^mu.Command_Jump:
      unreachable()
    }
  }
}


