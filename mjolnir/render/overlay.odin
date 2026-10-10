package render

import "../draw2d"
import "bindless"
import "../input"
import "gpu"
import cont "../containers"
import "core:math"
import "core:sync"
import ui_render "ui"
import mu "vendor:microui"
import vk "vendor:vulkan"

// Submit this frame's 2D overlay draw commands. The slice must stay valid
// until the frame is recorded.
stage_ui :: proc(self: ^Manager, commands: []draw2d.RenderCommand) {
  self.internal.ui.commands = commands
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

// The microui debug context. Feed it with debug_ui_input, then build widgets between
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

// Feed one input tick to the debug UI. Call on the update tick, before
// debug_ui_begin. With USE_PARALLEL_UPDATE the update thread feeds the
// microui context that the render thread builds, sharing it across threads.
debug_ui_input :: proc(self: ^Manager, s: ^input.State) {
  r := &self.internal.ui
  ctx := &r.debug_ctx
  hovered := ctx.hover_root != nil
  x, y := i32(math.round(s.cursor.x)), i32(math.round(s.cursor.y))
  mu.input_mouse_move(ctx, x, y)
  for b in input.MouseButton {
    // A press over the debug UI belongs to it until the tick after release.
    if input.mouse_pressed(s, b) && hovered do r.debug_buttons += {int(b)}
    else if !input.mouse_down(s, b) && !input.mouse_released(s, b) do r.debug_buttons -= {int(b)}
    mb: mu.Mouse
    #partial switch b {
    case .LEFT:   mb = .LEFT
    case .RIGHT:  mb = .RIGHT
    case .MIDDLE: mb = .MIDDLE
    case:         continue
    }
    if input.mouse_pressed(s, b) do mu.input_mouse_down(ctx, x, y, mb)
    if input.mouse_released(s, b) do mu.input_mouse_up(ctx, x, y, mb)
  }
  if s.scroll != {} {
    mu.input_scroll(ctx, -i32(math.round(s.scroll.x)), -i32(math.round(s.scroll.y)))
  }
  it := 0
  for key, pressed in input.next_key_edge(s, &it) {
    mk := mu_key(key) or_continue
    if pressed do mu.input_key_down(ctx, mk)
    else do mu.input_key_up(ctx, mk)
  }
  for key in input.Key {
    if !input.key_repeated(s, key) do continue
    if mk, ok := mu_key(key); ok do mu.input_key_down(ctx, mk)
  }
  if t := input.text(s); len(t) > 0 do mu.input_text(ctx, t)
}

// True when the debug UI is hovered or holds a button pressed over it; mouse
// input belongs to it.
debug_ui_wants_mouse :: proc(self: ^Manager) -> bool {
  r := &self.internal.ui
  return r.debug_ctx.hover_root != nil || r.debug_buttons != {}
}

// True when a debug UI widget has keyboard focus.
debug_ui_wants_keyboard :: proc(self: ^Manager) -> bool {
  return self.internal.ui.debug_ctx.focus_id != 0
}

// microui models only editing and modifier keys; text arrives as chars.
@(private = "file")
mu_key :: proc(key: input.Key) -> (mu.Key, bool) {
  #partial switch key {
  case .LEFT_SHIFT, .RIGHT_SHIFT:     return .SHIFT, true
  case .LEFT_CONTROL, .RIGHT_CONTROL: return .CTRL, true
  case .LEFT_ALT, .RIGHT_ALT:         return .ALT, true
  case .BACKSPACE:                    return .BACKSPACE, true
  case .DELETE:                       return .DELETE, true
  case .ENTER:                        return .RETURN, true
  case .LEFT:                         return .LEFT, true
  case .RIGHT:                        return .RIGHT, true
  case .HOME:                         return .HOME, true
  case .END:                          return .END, true
  case .A:                            return .A, true
  case .X:                            return .X, true
  case .C:                            return .C, true
  case .V:                            return .V, true
  }
  return .SHIFT, false
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
  if cam, ok := main_camera(self); ok {
    ret.opaque_draw_count = cam.draws.count[self.frame_index].mapped[bindless.DrawPipeline.OPAQUE]
  }
  return
}
