package render

import "../font"

// stage_overlay submits 2D draws, each tick in update. Calls of one tick add up (a HUD and
// debugui.end, say); the first call after render.update or a frame replaces what was shown.
// Frames keep drawing it until then; stage_overlay(r, nil) hides it. Text commands draw in
// text_font.
stage_overlay :: proc(self: ^Renderer, commands: []RenderCommand, text_font: ^font.Font = nil) {
  guard(self)
  if self.ui_stale do overlay_clear(self)
  self.ui_stale = false
  batch_commands(self, commands, text_font, dev.extent(&self.gpu))
  end_batch(self)
}
