package mjolnir

import cont "containers"
import "core:fmt"
import "render"
import mu "vendor:microui"

// Default debug stats panel rendered by render_and_present when debug_ui is
// enabled. Apps that want a different layout can replace this proc or skip
// it via their pre_render hook.
@(private)
populate_debug_ui :: proc(self: ^Engine) {
  ctx := &self.render.debug_ui.ctx
  // mu.window is a scoped (deferred) call: its matching end_window fires when
  // the enclosing scope exits. Widgets must live INSIDE the if-block, else the
  // layout stack is popped before they run (empty-stack crash in get_layout).
  if mu.window(ctx, "Engine", {40, 40, 200, 200}, {}) {
    mu.label(
      ctx,
      fmt.tprintf(
        "Objects %d",
        len(self.world.nodes.entries) - len(self.world.nodes.free_indices),
      ),
    )
    mu.label(
      ctx,
      fmt.tprintf("Textures %d", cont.count(self.render.texture_manager.images_2d)),
    )
    mu.label(
      ctx,
      fmt.tprintf(
        "Materials %d",
        len(self.world.materials.entries) - len(self.world.materials.free_indices),
      ),
    )
    mu.label(
      ctx,
      fmt.tprintf(
        "Meshes %d",
        len(self.world.meshes.entries) - len(self.world.meshes.free_indices),
      ),
    )
    if main_camera := get_main_camera(self); main_camera != nil {
      stats := render.visibility_stats(
        &self.render,
        self.world.main_camera.index,
        self.frame_index,
      )
      mu.label(ctx, fmt.tprintf("Total Objects: %d", stats.node_count))
      mu.label(ctx, fmt.tprintf("Draw count: %d draws", stats.opaque_draw_count))
    }
  }
}

