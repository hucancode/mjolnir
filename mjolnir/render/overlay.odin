package render

import "../anchor"
import "../font"

// stage_overlay submits 2D draws, each tick. Calls of one tick add up (a HUD and a debug
// panel, say); the first call after render.update or a frame replaces what was shown.
// Frames keep drawing it until then; stage_overlay(r, nil) hides it. Text commands draw in
// text_font.
stage_overlay :: proc(self: ^Renderer, commands: []RenderCommand, text_font: ^font.Font = nil) {
  lock(self)
  overlay_restage(self)
  batch_commands(self, commands, text_font, dev.extent(&self.gpu))
  end_batch(self)
}

// stage_overlay_mesh submits 2D geometry already in framebuffer pixels (window units times the
// DPI scale), drawn after everything staged before it this tick with `texture` (NO_TEXTURE draws
// white) inside `clip`, also in pixels (zero is the whole framebuffer). Indices count from the
// first of `vertices`. Staging replaces the shown overlay as stage_overlay does; geometry beyond
// the overlay's capacity (UI_MAX_VERTICES, UI_MAX_INDICES) is dropped.
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
  return self.ui_font_atlas
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
  if self.ui_stale do overlay_clear(self)
  self.ui_stale = false
}
