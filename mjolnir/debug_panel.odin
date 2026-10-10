package mjolnir

import "core:fmt"
import "render"
import mu "vendor:microui"
import "world"

// Built-in engine stats panel, drawn when RunConfig.show_engine_stats is set.
@(private)
populate_debug_ui :: proc(self: ^Engine) {
  ctx := render.debug_ui(&self.render)
  stats := render.stats(&self.render)
  // mu.window is scoped: widgets must stay inside the if-block.
  if mu.window(ctx, "Engine", {40, 40, 200, 200}, {}) {
    mu.label(ctx, fmt.tprintf("Objects %d", world.node_count(&self.world)))
    mu.label(ctx, fmt.tprintf("Textures %d", stats.textures))
    mu.label(ctx, fmt.tprintf("Materials %d", stats.materials))
    mu.label(ctx, fmt.tprintf("Meshes %d", stats.meshes))
    mu.label(ctx, fmt.tprintf("Render slots %d", stats.nodes))
    mu.label(ctx, fmt.tprintf("Draw count: %d draws", stats.opaque_draw_count))
  }
}
