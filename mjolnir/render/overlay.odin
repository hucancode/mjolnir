package render

import "core:fmt"
import "core:log"
import mu "vendor:microui"

// stage_overlay submits the 2D overlay for the next frame only, replacing what was staged; call
// it every frame the UI should show. The commands are batched at once; a non-empty atlas
// replaces the font atlas.
stage_overlay :: proc(self: ^Renderer, list: DrawList) {
  guard(self)
  if len(list.atlas) > 0 {
    destroy_texture(self, self.ui_font_atlas)
    ok: bool
    self.ui_font_atlas, ok = allocate_alpha_texture(self, list.atlas, list.atlas_size[0], list.atlas_size[1])
    self.ui_font_atlas_size = {f32(list.atlas_size[0]), f32(list.atlas_size[1])}
    if !ok do log.errorf("Font atlas upload failed")
  }
  overlay_clear(self)
  batch_commands(self, list.commands, dev.extent(&self.gpu))
  end_batch(self)
}

// debug_ctx returns the microui debug context itself, without opening a frame: the
// target of input.feed_microui. With USE_PARALLEL_UPDATE the update thread feeds the
// context the render thread builds.
debug_ctx :: proc(self: ^Renderer) -> ^mu.Context {
  return &self.ui_debug_ctx
}

// debug_ui returns the microui debug context for this frame. Build widgets on the render
// thread before frame, which draws and closes it; frames that never call it draw no debug UI.
debug_ui :: proc(self: ^Renderer) -> ^mu.Context {
  if !self.ui_debug_open {
    mu.begin(&self.ui_debug_ctx)
    self.ui_debug_open = true
  }
  return &self.ui_debug_ctx
}

// true when there is a debug UI to draw
@(private)
debug_ui_close :: proc(self: ^Renderer) -> bool {
  if !self.ui_debug_open do return false
  mu.end(&self.ui_debug_ctx)
  self.ui_debug_open = false
  return true
}

@(private)
stats_panel :: proc(self: ^Renderer) {
  ctx := debug_ui(self)
  draws: u32
  if _, ok := main_camera(self); ok {
    draws = draw_count(self, current_frame(self))
  }
  if mu.window(ctx, "Engine", {40, 40, 200, 200}, {}) {
    mu.label(ctx, fmt.tprintf("Textures %d", self.texture_slots.count))
    mu.label(ctx, fmt.tprintf("Materials %d", self.material_slots.count))
    mu.label(ctx, fmt.tprintf("Meshes %d", self.mesh_slots.count))
    mu.label(ctx, fmt.tprintf("Render slots %d", self.node_count))
    mu.label(ctx, fmt.tprintf("Draw count: %d draws", draws))
  }
}
