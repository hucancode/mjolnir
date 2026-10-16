package render

import "core:log"

// stage_overlay submits the 2D overlay for the next frame only, replacing what was staged; call
// it every frame the UI should show. The commands are batched at once; a non-empty atlas
// replaces the font atlas.
stage_overlay :: proc(self: ^Renderer, list: DrawList) {
  guard(self)
  if len(list.atlas) > 0 {
    texture_destroy(self, self.ui_font_atlas)
    ok: bool
    self.ui_font_atlas, ok = allocate_alpha_texture(self, list.atlas, list.atlas_size[0], list.atlas_size[1])
    self.ui_font_atlas_size = {f32(list.atlas_size[0]), f32(list.atlas_size[1])}
    if !ok do log.errorf("Font atlas upload failed")
  }
  overlay_clear(self)
  batch_commands(self, list.commands, dev.extent(&self.gpu))
  end_batch(self)
}
