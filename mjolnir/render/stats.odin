package render

import cont "../containers"
import "gpu"
import "core:fmt"
import mu "vendor:microui"

Stats :: struct {
  textures:          int,
  meshes:            int,
  materials:         int,
  nodes:             u32, // render slots in use
  // Main camera draws of the last frame recorded in this slot; zero without
  // a main camera.
  opaque_draw_count: u32,
}

// Resource counts and main camera visibility for the frame being recorded.
stats :: proc(self: ^Manager) -> (ret: Stats) {
  ret.textures = cont.count(self.texture_manager.images)
  ret.meshes = cont.count(self.meshes)
  ret.materials = cont.count(self.materials)
  ret.nodes = self.node_count
  if _, ok := main_camera(self); ok {
    readback := &self.internal.draw_count_readback[self.frame_index]
    ret.opaque_draw_count = gpu.mapped(readback, u32)[MaterialType.PBR]
  }
  return
}

// Engine stats window in the debug UI.
@(private)
stats_panel :: proc(self: ^Manager) {
  ctx := debug_ui(self)
  s := stats(self)
  // mu.window is scoped: widgets must stay inside the if-block.
  if mu.window(ctx, "Engine", {40, 40, 200, 200}, {}) {
    mu.label(ctx, fmt.tprintf("Textures %d", s.textures))
    mu.label(ctx, fmt.tprintf("Materials %d", s.materials))
    mu.label(ctx, fmt.tprintf("Meshes %d", s.meshes))
    mu.label(ctx, fmt.tprintf("Render slots %d", s.nodes))
    mu.label(ctx, fmt.tprintf("Draw count: %d draws", s.opaque_draw_count))
  }
}
