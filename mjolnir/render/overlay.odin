package render

import "../font"

// stage_overlay submits the 2D overlay for the next frame only, replacing what was staged; call
// it every frame the UI should show. Text commands draw in text_font.
stage_overlay :: proc(self: ^Renderer, commands: []RenderCommand, text_font: ^font.Font = nil) {
  guard(self)
  overlay_clear(self)
  batch_commands(self, commands, text_font, dev.extent(&self.gpu))
  end_batch(self)
}
