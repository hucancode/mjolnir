package render

import "../draw2d"
import "gpu"
import cont "../containers"
import "core:sync"
import ui_render "ui"
import mu "vendor:microui"
import vk "vendor:vulkan"

// Submit this frame's 2D overlay draw commands. The slice must stay valid
// until the frame is recorded.
stage_ui :: proc(self: ^Manager, commands: []draw2d.RenderCommand) {
  ui_render.stage_commands(&self.internal.ui, commands)
}

// Stage the overlay font atlas (R8 pixels). The pixels are copied; flush
// uploads them.
stage_ui_font_atlas :: proc(self: ^Manager, pixels: []u8, width, height: u32) {
  if len(pixels) == 0 do return
  sync.mutex_lock(&self.internal.staging.mutex)
  defer sync.mutex_unlock(&self.internal.staging.mutex)
  if len(self.internal.ui_atlas_pixels) != len(pixels) {
    delete(self.internal.ui_atlas_pixels)
    self.internal.ui_atlas_pixels = make([]u8, len(pixels))
  }
  copy(self.internal.ui_atlas_pixels, pixels)
  self.internal.ui_atlas_extent = {width, height}
  self.internal.ui_atlas_dirty = true
}

// Upload the staged atlas when it changed, or when the GPU copy is gone
// (first frame, after setup).
@(private)
flush_ui_atlas :: proc(self: ^Manager, gctx: ^gpu.GPUContext) -> vk.Result {
  if len(self.internal.ui_atlas_pixels) == 0 do return .SUCCESS
  if !self.internal.ui_atlas_dirty && self.internal.ui.font_atlas != {} do return .SUCCESS
  self.internal.ui_atlas_dirty = false
  return ui_render.upload_font_atlas(
    &self.internal.ui,
    gctx,
    &self.texture_manager,
    self.internal.ui_atlas_pixels,
    self.internal.ui_atlas_extent[0],
    self.internal.ui_atlas_extent[1],
  )
}

// The microui debug context. Feed it input, then build widgets between
// debug_ui_begin and debug_ui_end; frame draws it when debug UI is enabled.
debug_ui :: proc(self: ^Manager) -> ^mu.Context {
  return &self.internal.ui.debug_ctx
}

debug_ui_begin :: proc(self: ^Manager) -> ^mu.Context {
  mu.begin(&self.internal.ui.debug_ctx)
  return &self.internal.ui.debug_ctx
}

debug_ui_end :: proc(self: ^Manager) {
  mu.end(&self.internal.ui.debug_ctx)
}

// True when the debug UI is hovered; mouse input belongs to it.
debug_ui_wants_mouse :: proc(self: ^Manager) -> bool {
  return ui_render.debug_wants_mouse(&self.internal.ui)
}

// True when a debug UI widget has keyboard focus.
debug_ui_wants_keyboard :: proc(self: ^Manager) -> bool {
  return ui_render.debug_wants_keyboard(&self.internal.ui)
}

// Offer a mouse button edge to the debug UI. A press over the UI belongs to
// it until the matching release. True when the debug UI consumed the edge.
debug_ui_claim_button :: proc(self: ^Manager, button: int, pressed: bool) -> bool {
  return ui_render.debug_claim_button(&self.internal.ui, button, pressed)
}

Stats :: struct {
  textures:          int,
  meshes:            int,
  materials:         int,
  nodes:             u32, // render slots in use
  // Main camera draws; zero without a main camera.
  opaque_draw_count: u32,
}

// Resource counts and main camera visibility for the frame being recorded.
stats :: proc(self: ^Manager) -> (ret: Stats) {
  ret.textures = cont.count(self.texture_manager.images_2d)
  ret.meshes = cont.count(self.meshes)
  ret.materials = cont.count(self.materials)
  ret.nodes = self.node_count
  if _, ok := main_camera(self); ok {
    ret.opaque_draw_count = visibility_stats(self, self.main_camera).opaque_draw_count
  }
  return
}
