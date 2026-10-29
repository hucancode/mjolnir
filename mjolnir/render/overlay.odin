package render

import "../font"

// stage_overlay submits 2D draws, each tick. Calls of one tick add up (a HUD and a debug
// panel, say); the first call after render.update or a frame replaces what was shown.
// Frames keep drawing it until then; stage_overlay(r, nil) hides it. Text commands draw in
// text_font.
stage_overlay :: proc(self: ^Renderer, commands: []RenderCommand, text_font: ^font.Font = nil) {
  guard(self)
  if self.ui_stale do overlay_clear(self)
  self.ui_stale = false
  batch_commands(self, commands, text_font, dev.extent(&self.gpu))
  end_batch(self)
}

// window_size returns the window in the units overlay commands and the cursor use: its
// framebuffer divided by the DPI scale the last frame measured (init measures it before the first).
window_size :: proc(self: ^Renderer) -> [2]f32 {
  extent := dev.extent(&self.gpu)
  return {f32(extent.x), f32(extent.y)} / (self.dpi_scale if self.dpi_scale > 0 else 1)
}
