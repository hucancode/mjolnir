package render

import "../anchor"
import "../font"
import "core:log"
import "core:slice"

// Positions and sizes are window coordinates (window_size), as input.State reports the cursor;
// render scales them by the DPI scale. A zero `clip` is the whole window.

// OverlayQuad draws a solid or textured rectangle.
OverlayQuad :: struct {
  position:   [2]f32,
  size:       [2]f32,
  color:      [4]u8,
  texture:    TextureHandle,
}

// OverlayText draws one line of text in stage_overlay's font, its top-left at position,
// size pixels tall.
OverlayText :: struct {
  text:     string,
  position: [2]f32,
  size:     f32,
  color:    [4]u8,
}

// OverlayMesh draws an indexed 2D triangle mesh offset by position.
OverlayMesh :: struct {
  position:   [2]f32,
  vertices:   []Vertex2D,
  indices:    []u32,
  texture:    TextureHandle,
}

// OverlayCommand is one 2D draw staged with stage_overlay: a shape, drawn in z_order
// (ascending, stable) inside clip.
OverlayCommand :: struct {
  shape:   union {
    OverlayQuad,
    OverlayText,
    OverlayMesh,
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
  clear(&self.overlay_vertices)
  clear(&self.overlay_indices)
  clear(&self.overlay_batches)
}

// A batch takes the texture of its first quad.
@(private)
begin_batch :: proc(self: ^Renderer, scissor: [4]i32) {
  end_batch(self)
  append(&self.overlay_batches, OverlayBatch{first_index = u32(len(self.overlay_indices)), scissor = scissor})
}

// A texture change starts a batch in the same scissor; NO_TEXTURE draws white.
@(private)
use_texture :: proc(self: ^Renderer, texture: TextureHandle) {
  if len(self.overlay_batches) == 0 do return
  texture := self.white if texture == NO_TEXTURE else texture
  last := &self.overlay_batches[len(self.overlay_batches) - 1]
  if last.first_index == u32(len(self.overlay_indices)) {
    last.texture = texture
  } else if last.texture != texture {
    begin_batch(self, last.scissor)
    self.overlay_batches[len(self.overlay_batches) - 1].texture = texture
  }
}

@(private)
end_batch :: proc(self: ^Renderer) {
  if len(self.overlay_batches) == 0 do return
  last := &self.overlay_batches[len(self.overlay_batches) - 1]
  last.index_count = u32(len(self.overlay_indices)) - last.first_index
}

// quads beyond the buffer capacity are dropped
@(private)
push_quad :: proc(
  self: ^Renderer,
  p0, p1, uv0, uv1: [2]f32,
  color: [4]u8,
  texture: TextureHandle,
) {
  if len(self.overlay_vertices) + 4 > OVERLAY_MAX_VERTICES || len(self.overlay_indices) + 6 > OVERLAY_MAX_INDICES do return
  use_texture(self, texture)
  base := u32(len(self.overlay_vertices))
  append(
    &self.overlay_vertices,
    Vertex2D{p0, uv0, color},
    Vertex2D{{p1.x, p0.y}, {uv1.x, uv0.y}, color},
    Vertex2D{p1, uv1, color},
    Vertex2D{{p0.x, p1.y}, {uv0.x, uv1.y}, color},
  )
  append(&self.overlay_indices, base, base + 1, base + 2, base, base + 2, base + 3)
}

// Text draws nothing without a font.
@(private)
batch_commands :: proc(self: ^Renderer, commands: []OverlayCommand, text_font: ^font.Font, extent: [2]u32) {
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
      c := command.shape.(OverlayText) or_continue
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
    case OverlayQuad:
      p0 := c.position * scale
      push_quad(self, p0, p0 + c.size * scale, {0, 0}, {1, 1}, c.color, c.texture)
    case OverlayText:
      if self.overlay_font_atlas == 0 do continue
      for g in glyphs[key.cmd_index] {
        push_quad(self, g.p0, g.p1, g.uv0 / atlas_size, g.uv1 / atlas_size, c.color, self.overlay_font_atlas)
      }
    case OverlayMesh:
      push_mesh(self, c, scale)
    }
  }
}

// Uploads the font's atlas unless the one uploaded is its current version; returns its size.
@(private)
sync_font_atlas :: proc(self: ^Renderer, text_font: ^font.Font) -> [2]f32 {
  pixels, size, version := font.atlas(text_font)
  if version != self.overlay_font_version || self.overlay_font_atlas == 0 {
    old, old_size := self.overlay_font_atlas, self.overlay_font_size
    self.overlay_font_version, self.overlay_font_size = version, size
    ok: bool
    self.overlay_font_atlas, ok = allocate_texture(self, {extent = size, format = .A8, usage = {.SAMPLED}}, pixels, target = true)
    if !ok do log.errorf("Font atlas upload failed")
    if old != 0 {
      move_staged_glyphs(self, old, old_size, size)
      texture_destroy(self, old)
    }
  }
  return {f32(size.x), f32(size.y)}
}

// What is staged from the old atlas samples the new one, which the next frame draws while the
// old one is already gone: an atlas grows keeping its glyphs' texels, so their uvs only rescale.
@(private = "file")
move_staged_glyphs :: proc(self: ^Renderer, old: TextureHandle, old_size, size: [2]u32) {
  scale := [2]f32{f32(old_size.x), f32(old_size.y)} / [2]f32{f32(size.x), f32(size.y)}
  for &b, i in self.overlay_batches {
    if b.texture != old do continue
    b.texture = self.overlay_font_atlas
    end := self.overlay_batches[i + 1].first_index if i + 1 < len(self.overlay_batches) else u32(len(self.overlay_indices))
    indices := self.overlay_indices[b.first_index:end]
    if len(indices) == 0 do continue
    // a batch's vertices are contiguous, pushed with its indices
    first, last := slice.min(indices), slice.max(indices)
    for &v in self.overlay_vertices[first:last + 1] do v.uv *= scale
  }
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
push_mesh :: proc(self: ^Renderer, mesh: OverlayMesh, scale: f32) {
  if len(self.overlay_vertices) + len(mesh.vertices) > OVERLAY_MAX_VERTICES || len(self.overlay_indices) + len(mesh.indices) > OVERLAY_MAX_INDICES do return
  use_texture(self, mesh.texture)
  base := u32(len(self.overlay_vertices))
  for v in mesh.vertices do append(&self.overlay_vertices, Vertex2D{(mesh.position + v.pos) * scale, v.uv, v.color})
  for idx in mesh.indices do append(&self.overlay_indices, base + idx)
}

// stage_overlay submits 2D draws, each tick. Calls of one tick add up (a HUD and a debug
// panel, say); the first call after render.update or a frame replaces what was shown.
// Frames keep drawing it until then; stage_overlay(r, nil) hides it. Text commands draw in
// text_font.
stage_overlay :: proc(self: ^Renderer, commands: []OverlayCommand, text_font: ^font.Font = nil) {
  lock(self)
  overlay_restage(self)
  batch_commands(self, commands, text_font, dev.extent(&self.gpu))
  end_batch(self)
}

// stage_overlay_mesh submits 2D geometry already in framebuffer pixels (window units times the
// DPI scale), drawn after everything staged before it this tick with `texture` (NO_TEXTURE draws
// white) inside `clip`, also in pixels (zero is the whole framebuffer). Indices count from the
// first of `vertices`. Staging replaces the shown overlay as stage_overlay does; geometry beyond
// the overlay's capacity (OVERLAY_MAX_VERTICES, OVERLAY_MAX_INDICES) is dropped.
stage_overlay_mesh :: proc(self: ^Renderer, vertices: []Vertex2D, indices: []u32, texture: TextureHandle, clip: anchor.Rect = {}) {
  lock(self)
  overlay_restage(self)
  begin_batch(self, clip_scissor(clip, dev.extent(&self.gpu)))
  push_mesh(self, {vertices = vertices, indices = indices, texture = texture}, 1)
  end_batch(self)
}

// font_texture returns the texture holding f's glyph atlas, uploaded again first if f's atlas
// changed since (font.atlas); the overlay samples glyphs from it. 0 when the upload failed.
font_texture :: proc(self: ^Renderer, f: ^font.Font) -> TextureHandle {
  lock(self)
  sync_font_atlas(self, f)
  return self.overlay_font_atlas
}

// window_size returns the window in the units overlay commands and the cursor use: its
// framebuffer divided by the DPI scale the last frame measured (init measures it before the first).
window_size :: proc(self: ^Renderer) -> [2]f32 {
  extent := dev.extent(&self.gpu)
  return {f32(extent.x), f32(extent.y)} / self.dpi_scale
}

// The first staging after an update or a frame replaces the shown overlay.
@(private = "file")
overlay_restage :: proc(self: ^Renderer) {
  if self.overlay_stale do overlay_clear(self)
  self.overlay_stale = false
}
