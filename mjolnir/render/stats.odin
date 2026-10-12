package render

import "gpu"
import "core:fmt"
import mu "vendor:microui"

// Engine stats window in the debug UI: resource counts and the main camera's
// opaque draws of the last frame recorded in this slot.
@(private)
stats_panel :: proc(self: ^Manager) {
  ctx := debug_ui(self)
  draws: u32
  if _, ok := main_camera(self); ok {
    draws = gpu.mapped(&self.draw_count_readback[self.gctx.frame_serial % gpu.FRAMES_IN_FLIGHT], u32)[MaterialType.PBR]
  }
  // mu.window is scoped: widgets must stay inside the if-block.
  if mu.window(ctx, "Engine", {40, 40, 200, 200}, {}) {
    mu.label(ctx, fmt.tprintf("Textures %d", self.texture_slots.count))
    mu.label(ctx, fmt.tprintf("Materials %d", self.material_slots.count))
    mu.label(ctx, fmt.tprintf("Meshes %d", self.mesh_slots.count))
    mu.label(ctx, fmt.tprintf("Render slots %d", self.node_count))
    mu.label(ctx, fmt.tprintf("Draw count: %d draws", draws))
  }
}
