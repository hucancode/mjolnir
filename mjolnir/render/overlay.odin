package render

import "../font"
import "../ui"
import "core:log"
import "core:math"
import "core:slice"
import "rhi"

// The overlay draws ui.Canvas batches into the swapchain image after post-processing, one vertex
// stream: the staged batches sorted by z, each clipped and textured as it says. A GPU batch is
// one scissor, one texture and one sampler.

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

// Appends the canvases' batches by z (ascending, stable), in window units scaled to framebuffer
// pixels; FONT_TEXTURE batches sample text_font's atlas, which draws nothing without it.
@(private)
batch_canvases :: proc(self: ^Renderer, canvases: []^ui.Canvas, text_font: ^font.Font, extent: [2]u32) {
  Key :: struct {
    z:             i32,
    canvas, batch: int,
  }
  keys := make([dynamic]Key, context.temp_allocator)
  text := false
  for c, ci in canvases {
    if c == nil do continue
    _, _, batches := ui.mesh(c)
    for b, bi in batches {
      append(&keys, Key{b.z, ci, bi})
      text ||= b.texture == ui.FONT_TEXTURE
    }
  }
  slice.stable_sort_by(keys[:], proc(a, b: Key) -> bool {return a.z < b.z})
  // synced before any uv is divided by the atlas size: new glyphs grew it
  atlas := sync_font_atlas(self, text_font) if text && text_font != nil else nil
  scale := self.dpi_scale
  scissor := [4]i32{-1, -1, 0, 0}
  for key in keys {
    vertices, indices, batches := ui.mesh(canvases[key.canvas])
    b := batches[key.batch]
    if s := clip_scissor({b.clip.pos * scale, b.clip.size * scale}, extent); s != scissor {
      scissor = s
      begin_batch(self, s)
    }
    texture := TextureHandle(b.texture)
    texels := [2]f32{1, 1}
    if b.texture == ui.FONT_TEXTURE {
      if atlas == nil || atlas.texture == 0 do continue
      texture = atlas.texture
      texels = {f32(atlas.size.x), f32(atlas.size.y)}
    }
    if !has_room(self, int(b.vertex_count), int(b.index_count)) do continue
    use_texture(self, texture, b.smooth)
    base := u32(len(self.overlay_vertices))
    for v in vertices[b.first_vertex:][:b.vertex_count] do append(&self.overlay_vertices, Vertex2D{v.pos * scale, v.uv / texels, v.color})
    for i in indices[b.first_index:][:b.index_count] do append(&self.overlay_indices, base + i)
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
clip_scissor :: proc(clip: ui.Rect, extent: [2]u32) -> [4]i32 {
  if clip == {} do return {0, 0, i32(extent.x), i32(extent.y)}
  x0 := clamp(i32(math.round(clip.pos.x)), 0, i32(extent.x))
  y0 := clamp(i32(math.round(clip.pos.y)), 0, i32(extent.y))
  x1 := clamp(i32(math.round(clip.pos.x + clip.size.x)), x0, i32(extent.x))
  y1 := clamp(i32(math.round(clip.pos.y + clip.size.y)), y0, i32(extent.y))
  return {x0, y0, x1 - x0, y1 - y0}
}

// stage_overlay submits 2D draws, each tick: every canvas's batches by z (ui.Canvas), in window
// units (window_size) which render scales by the DPI scale, colors in sRGB as authored. Calls of
// one tick add up (a HUD and a debug panel, say), each drawn over the ones before; the first call
// after render.update or a frame replaces what was shown. Frames keep drawing it until then;
// stage_overlay(r, nil) hides it. Text (ui.FONT_TEXTURE) draws in text_font; each font keeps
// its own atlas.
stage_overlay :: proc(self: ^Renderer, canvases: []^ui.Canvas, text_font: ^font.Font = nil) {
  lock(self)
  overlay_restage(self)
  batch_canvases(self, canvases, text_font, dev.extent(&self.gpu))
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

// window_size returns the window in the units canvases (stage_overlay) and the cursor use: its
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
