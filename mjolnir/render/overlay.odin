package render

import "../anchor"
import "../font"
import "core:log"
import "core:math"
import "core:slice"
import "rhi"

// Positions and sizes are window coordinates (window_size), as input.State reports the cursor;
// render scales them by the DPI scale. Colors are sRGB, as authored. Every command draws in
// z_order (ascending, stable) inside its `clip`, a zero clip being the whole window. A texture is
// sampled nearest (pixel art), or bilinear where `smooth` (scaled icons and photos).

// OverlayQuad draws a solid or textured rectangle.
OverlayQuad :: struct {
  position: [2]f32,
  size:     [2]f32,
  color:    [4]u8,
  texture:  TextureHandle,
  // the texture coordinates of the top-left, top-right, bottom-right and bottom-left corners,
  // e.g. a SpriteFrame's uv; zero shows the whole texture
  uv:       [4][2]f32,
  smooth:   bool,
  z_order:  i32,
  clip:     anchor.Rect,
}

// OverlayText draws one line of text in stage_overlay's font, `size` pixels tall. The point at
// `pivot` (0..1 of its width and line height) sits on `position`: {} is the top-left, {0.5, 0.5}
// centres it there.
OverlayText :: struct {
  text:     string,
  position: [2]f32,
  size:     f32,
  color:    [4]u8,
  pivot:    [2]f32,
  z_order:  i32,
  clip:     anchor.Rect,
}

// OverlayMesh draws an indexed 2D triangle mesh offset by position. With texture FONT_ATLAS it
// samples stage_overlay's font atlas, its uvs in atlas texels (font.Glyph's).
OverlayMesh :: struct {
  position: [2]f32,
  vertices: []Vertex2D,
  indices:  []u32,
  texture:  TextureHandle,
  smooth:   bool,
  z_order:  i32,
  clip:     anchor.Rect,
}

// OverlayCommand is one 2D draw staged with stage_overlay.
OverlayCommand :: union {
  OverlayQuad,
  OverlayText,
  OverlayMesh,
}

// FONT_ATLAS stands for stage_overlay's font atlas in OverlayMesh.texture.
FONT_ATLAS :: TextureHandle(max(u32))

// The overlay batches 2D output drawn into the swapchain image after post-processing, one
// vertex stream: draw2d commands staged by the app (sorted by z_order, clipped per command).
// A batch is one scissor, one texture and one sampler.

// A font's atlas as uploaded for the overlay: the font.atlas version it holds, its size.
@(private)
OverlayFont :: struct {
  font:    ^font.Font,
  version: u64,
  size:    [2]u32,
  texture: TextureHandle,
  // overlay_font_clock when last synced: the least recent is replaced when all are taken
  used:    u64,
}

// OVERLAY_FONTS is how many fonts' atlases the overlay keeps uploaded at once.
@(private)
OVERLAY_FONTS :: 8

// Empties the overlay: what frame draws is staged again for the next.
@(private)
overlay_clear :: proc(self: ^Renderer) {
  clear(&self.overlay_vertices)
  clear(&self.overlay_indices)
  clear(&self.overlay_batches)
  self.overlay_full = false
}

// A batch takes the texture and sampler of its first draw.
@(private)
begin_batch :: proc(self: ^Renderer, scissor: [4]i32) {
  end_batch(self)
  append(&self.overlay_batches, OverlayBatch{first_index = u32(len(self.overlay_indices)), scissor = scissor})
}

// A texture or sampler change starts a batch in the same scissor; NO_TEXTURE draws white.
@(private)
use_texture :: proc(self: ^Renderer, texture: TextureHandle, smooth: bool) {
  if len(self.overlay_batches) == 0 do return
  texture := self.white if texture == NO_TEXTURE else texture
  sampler := u32(rhi.SamplerType.LINEAR_CLAMP if smooth else rhi.SamplerType.NEAREST_CLAMP)
  last := &self.overlay_batches[len(self.overlay_batches) - 1]
  if last.first_index == u32(len(self.overlay_indices)) {
    last.texture, last.sampler = texture, sampler
  } else if last.texture != texture || last.sampler != sampler {
    begin_batch(self, last.scissor)
    self.overlay_batches[len(self.overlay_batches) - 1].texture = texture
    self.overlay_batches[len(self.overlay_batches) - 1].sampler = sampler
  }
}

@(private)
end_batch :: proc(self: ^Renderer) {
  if len(self.overlay_batches) == 0 do return
  last := &self.overlay_batches[len(self.overlay_batches) - 1]
  last.index_count = u32(len(self.overlay_indices)) - last.first_index
}

// Whether `vertices` and `indices` more still fit; past the capacity the draw is dropped, warned about
// once per staging.
@(private = "file")
has_room :: proc(self: ^Renderer, vertices, indices: int) -> bool {
  if len(self.overlay_vertices) + vertices <= OVERLAY_MAX_VERTICES && len(self.overlay_indices) + indices <= OVERLAY_MAX_INDICES do return true
  if !self.overlay_full do log.warnf("The overlay is full (%d vertices, %d indices); the draws past it are dropped", OVERLAY_MAX_VERTICES, OVERLAY_MAX_INDICES)
  self.overlay_full = true
  return false
}

@(private)
push_quad :: proc(self: ^Renderer, p0, p1: [2]f32, uv: [4][2]f32, color: [4]u8, texture: TextureHandle, smooth := false) {
  if !has_room(self, 4, 6) do return
  use_texture(self, texture, smooth)
  base := u32(len(self.overlay_vertices))
  append(
    &self.overlay_vertices,
    Vertex2D{p0, uv[0], color},
    Vertex2D{{p1.x, p0.y}, uv[1], color},
    Vertex2D{p1, uv[2], color},
    Vertex2D{{p0.x, p1.y}, uv[3], color},
  )
  append(&self.overlay_indices, base, base + 1, base + 2, base, base + 2, base + 3)
}

// The uv corners of a rect from uv0 (top-left) to uv1 (bottom-right).
@(private = "file")
uv_corners :: proc(uv0, uv1: [2]f32) -> [4][2]f32 {
  return {uv0, {uv1.x, uv0.y}, uv1, {uv0.x, uv1.y}}
}

// The draw order and clip of a command.
@(private = "file")
command_place :: proc(command: OverlayCommand) -> (z_order: i32, clip: anchor.Rect) {
  switch c in command {
  case OverlayQuad:
    return c.z_order, c.clip
  case OverlayText:
    return c.z_order, c.clip
  case OverlayMesh:
    return c.z_order, c.clip
  }
  return
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
  atlas: ^OverlayFont
  if text_font != nil {
    for command, i in commands {
      c := command.(OverlayText) or_continue
      // whole pixels: a size rasterizes its glyphs once, however the window scales
      size := max(math.round(c.size * scale), 1)
      origin := c.position * scale - c.pivot * {font.measure(text_font, c.text, size), font.line_height(text_font, size)}
      run := make([dynamic]font.Glyph, context.temp_allocator)
      font.glyphs(text_font, c.text, {math.round(origin.x), math.round(origin.y)}, size, &run)
      glyphs[i] = run[:]
    }
    atlas = sync_font_atlas(self, text_font)
  }
  keys := make([]CommandSortKey, len(commands), context.temp_allocator)
  for command, i in commands {
    z, _ := command_place(command)
    keys[i] = {z, i}
  }
  slice.stable_sort_by(keys, proc(a, b: CommandSortKey) -> bool {
    return a.z_order < b.z_order
  })
  scissor := [4]i32{-1, -1, 0, 0}
  for key in keys {
    command := commands[key.cmd_index]
    _, clip := command_place(command)
    // a new batch wherever the clip changes
    if s := clip_scissor({clip.pos * scale, clip.size * scale}, extent); s != scissor {
      scissor = s
      begin_batch(self, s)
    }
    switch c in command {
    case OverlayQuad:
      p0 := c.position * scale
      push_quad(self, p0, p0 + c.size * scale, c.uv if c.uv != {} else uv_corners(0, 1), c.color, c.texture, c.smooth)
    case OverlayText:
      if atlas == nil || atlas.texture == 0 do continue
      texels := [2]f32{f32(atlas.size.x), f32(atlas.size.y)}
      for g in glyphs[key.cmd_index] {
        push_quad(self, g.p0, g.p1, uv_corners(g.uv0 / texels, g.uv1 / texels), c.color, atlas.texture)
      }
    case OverlayMesh:
      push_mesh(self, c, scale, atlas)
    }
  }
}

// Uploads the font's atlas unless the one uploaded is its current version, each font into its
// own texture; nil when the upload failed.
@(private)
sync_font_atlas :: proc(self: ^Renderer, text_font: ^font.Font) -> ^OverlayFont {
  pixels, size, version := font.atlas(text_font)
  self.overlay_font_clock += 1
  slot := &self.overlay_fonts[0]
  for &f in self.overlay_fonts {
    if f.font == text_font {
      slot = &f
      break
    }
    if f.used < slot.used do slot = &f
  }
  if slot.font != text_font {
    // another font's, least recently used: what is staged with it no longer draws
    if slot.texture != 0 do texture_destroy(self, slot.texture)
    slot^ = {font = text_font}
  }
  slot.used = self.overlay_font_clock
  if version == slot.version && slot.texture != 0 do return slot
  old, old_size := slot.texture, slot.size
  ok: bool
  slot.texture, ok = allocate_texture(self, {extent = size, format = .A8, usage = {.SAMPLED}}, pixels, target = true)
  if !ok {
    log.errorf("Font atlas upload failed")
    slot^ = {}
    return nil
  }
  slot.version, slot.size = version, size
  if old != 0 {
    move_staged_glyphs(self, old, slot.texture, old_size, size)
    texture_destroy(self, old)
  }
  return slot
}

// What is staged from the old atlas samples the new one, which the next frame draws while the
// old one is already gone: an atlas grows keeping its glyphs' texels, so their uvs only rescale.
@(private = "file")
move_staged_glyphs :: proc(self: ^Renderer, old, new: TextureHandle, old_size, size: [2]u32) {
  scale := [2]f32{f32(old_size.x), f32(old_size.y)} / [2]f32{f32(size.x), f32(size.y)}
  for &b, i in self.overlay_batches {
    if b.texture != old do continue
    b.texture = new
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
  x0 := clamp(i32(math.round(clip.pos.x)), 0, i32(extent.x))
  y0 := clamp(i32(math.round(clip.pos.y)), 0, i32(extent.y))
  x1 := clamp(i32(math.round(clip.pos.x + clip.size.x)), x0, i32(extent.x))
  y1 := clamp(i32(math.round(clip.pos.y + clip.size.y)), y0, i32(extent.y))
  return {x0, y0, x1 - x0, y1 - y0}
}

@(private)
push_mesh :: proc(self: ^Renderer, mesh: OverlayMesh, scale: f32, atlas: ^OverlayFont) {
  if !has_room(self, len(mesh.vertices), len(mesh.indices)) do return
  texture := mesh.texture
  texels := [2]f32{1, 1}
  if texture == FONT_ATLAS {
    if atlas == nil || atlas.texture == 0 do return
    texture = atlas.texture
    texels = {f32(atlas.size.x), f32(atlas.size.y)}
  }
  use_texture(self, texture, mesh.smooth)
  base := u32(len(self.overlay_vertices))
  for v in mesh.vertices do append(&self.overlay_vertices, Vertex2D{(mesh.position + v.pos) * scale, v.uv / texels, v.color})
  for idx in mesh.indices do append(&self.overlay_indices, base + idx)
}

// stage_overlay submits 2D draws, each tick. Calls of one tick add up (a HUD and a debug
// panel, say), each drawn over the ones before; the first call after render.update or a frame
// replaces what was shown. Frames keep drawing it until then; stage_overlay(r, nil) hides it.
// Text, and meshes on FONT_ATLAS, draw in text_font; each font keeps its own atlas.
stage_overlay :: proc(self: ^Renderer, commands: []OverlayCommand, text_font: ^font.Font = nil) {
  lock(self)
  overlay_restage(self)
  batch_commands(self, commands, text_font, dev.extent(&self.gpu))
  end_batch(self)
}

// font_texture returns the texture holding f's glyph atlas, uploaded again first if f's atlas
// changed since (font.atlas): glyph uvs (font.Glyph, in texels) divided by font.atlas_size
// sample it, e.g. text on a mesh in the world. 0 when the upload failed.
font_texture :: proc(self: ^Renderer, f: ^font.Font) -> TextureHandle {
  lock(self)
  atlas := sync_font_atlas(self, f)
  return atlas.texture if atlas != nil else 0
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
