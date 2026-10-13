package render

import "../input"
import "core:fmt"
import "core:math"
import "core:sync"
import "gpu"
import mu "vendor:microui"
import vk "vendor:vulkan"

// stage_overlay submits the 2D overlay for the next frame only; call it every frame the UI should show.
// The commands must stay valid until that frame is recorded; a non-empty atlas is copied.
stage_overlay :: proc(self: ^Renderer, list: DrawList) {
  ui := &self.ui
  ui.commands = list.commands
  if len(list.atlas) == 0 do return
  sync.recursive_mutex_lock(&self.mutex)
  defer sync.recursive_mutex_unlock(&self.mutex)
  if len(ui.atlas_pixels) != len(list.atlas) {
    delete(ui.atlas_pixels)
    ui.atlas_pixels = make([]u8, len(list.atlas))
  }
  copy(ui.atlas_pixels, list.atlas)
  ui.atlas_extent = list.atlas_size
  ui.atlas_dirty = true
}

// also when the GPU copy is gone (first frame, after setup)
@(private)
flush_ui_atlas :: proc(self: ^Renderer) -> (ret: vk.Result) {
  ui := &self.ui
  if len(ui.atlas_pixels) == 0 do return .SUCCESS
  if !ui.atlas_dirty && ui.font_atlas != 0 do return .SUCCESS
  ui.atlas_dirty = false
  destroy_texture(self, ui.font_atlas)
  ui.font_atlas, ret = allocate_alpha_texture(self, ui.atlas_pixels, ui.atlas_extent[0], ui.atlas_extent[1])
  return
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

// debug_ui_input feeds one input tick to the debug UI and captures the mouse and keyboard it
// owns (see input.State). Call first among input consumers on the update tick.
// With USE_PARALLEL_UPDATE the update thread feeds the context the render thread builds.
debug_ui_input :: proc(self: ^Renderer, s: ^input.State) {
  r := &self.ui
  ctx := &r.debug_ctx
  hovered := ctx.hover_root != nil
  x, y := i32(math.round(s.cursor.x)), i32(math.round(s.cursor.y))
  mu.input_mouse_move(ctx, x, y)
  for b in input.MouseButton {
    // a press over the debug UI belongs to it until the tick after release
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
  if ctx.hover_root != nil || r.debug_buttons != {} do s.mouse_captured = true
  if ctx.focus_id != 0 do s.keyboard_captured = true
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

@(private)
stats_panel :: proc(self: ^Renderer) {
  ctx := debug_ui(self)
  draws: u32
  if _, ok := main_camera(self); ok {
    draws = gpu.mapped(&self.draw_count_readback[self.gctx.frame_serial % gpu.FRAMES_IN_FLIGHT], u32)[MaterialType.PBR]
  }
  if mu.window(ctx, "Engine", {40, 40, 200, 200}, {}) {
    mu.label(ctx, fmt.tprintf("Textures %d", self.texture_slots.count))
    mu.label(ctx, fmt.tprintf("Materials %d", self.material_slots.count))
    mu.label(ctx, fmt.tprintf("Meshes %d", self.mesh_slots.count))
    mu.label(ctx, fmt.tprintf("Render slots %d", len(self.attachments)))
    mu.label(ctx, fmt.tprintf("Draw count: %d draws", draws))
  }
}
