package render

import "core:fmt"
import "core:log"
import "gpu"
import mu "vendor:microui"
import vk "vendor:vulkan"

// stage_overlay submits the 2D overlay for the next frame only; call it every frame the UI should show.
// The commands must stay valid until that frame is recorded; a non-empty atlas replaces the font atlas.
stage_overlay :: proc(self: ^Renderer, list: DrawList) {
  ui := &self.ui
  ui.commands = list.commands
  if len(list.atlas) == 0 do return
  guard(self)
  destroy_texture(self, ui.font_atlas)
  res: vk.Result
  ui.font_atlas, res = allocate_alpha_texture(self, list.atlas, list.atlas_size[0], list.atlas_size[1])
  if res != .SUCCESS do log.errorf("Font atlas upload failed: %v", res)
}

// debug_ctx returns the microui debug context itself, without opening a frame: the
// target of input.feed_microui. With USE_PARALLEL_UPDATE the update thread feeds the
// context the render thread builds.
debug_ctx :: proc(self: ^Renderer) -> ^mu.Context {
  return &self.ui.debug_ctx
}

// debug_ui returns the microui debug context for this frame. Build widgets on the render
// thread before frame, which draws and closes it; frames that never call it draw no debug UI.
debug_ui :: proc(self: ^Renderer) -> ^mu.Context {
  r := &self.ui
  if !r.debug_open {
    mu.begin(&r.debug_ctx)
    r.debug_open = true
  }
  return &r.debug_ctx
}

// true when there is a debug UI to draw
@(private)
debug_ui_close :: proc(self: ^Renderer) -> bool {
  r := &self.ui
  if !r.debug_open do return false
  mu.end(&r.debug_ctx)
  r.debug_open = false
  return true
}

@(private)
stats_panel :: proc(self: ^Renderer) {
  ctx := debug_ui(self)
  draws: u32
  if _, ok := main_camera(self); ok {
    draws = gpu.mapped(&self.draw_count_readback[write_frame(self)], u32)[MaterialType.PBR]
  }
  if mu.window(ctx, "Engine", {40, 40, 200, 200}, {}) {
    mu.label(ctx, fmt.tprintf("Textures %d", self.texture_slots.count))
    mu.label(ctx, fmt.tprintf("Materials %d", self.material_slots.count))
    mu.label(ctx, fmt.tprintf("Meshes %d", self.mesh_slots.count))
    mu.label(ctx, fmt.tprintf("Render slots %d", self.node_count))
    mu.label(ctx, fmt.tprintf("Draw count: %d draws", draws))
  }
}
