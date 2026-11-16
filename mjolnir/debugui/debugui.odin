package debugui

import "../input"
import "../render"
import "../ui"
import "core:math"
import mu "vendor:microui"

// Context is the debug UI: build widgets on its microui context (mu) between begin and end.
// Windows are declared in a reference frame (the window at init by default) and keep to their
// edges when the window differs from it; nothing scales but the display's DPI.
Context :: struct {
  mu:      mu.Context,
  using _: Context_State,
}

@(private)
Context_State :: struct {
  // microui's builtin font and icon atlas
  atlas:    render.TextureHandle,
  // the frame windows are declared in, and the window's size on the last feed
  reference: [2]f32,
  size:     [2]f32,
  // the window size each window was last placed in
  windows:  map[mu.Id][2]f32,
  // buttons pressed over the UI, owned by it through release
  buttons:  input.ButtonSet,
  // begin opened mu this tick; end closes it
  open:     bool,
  // this tick's widgets, drawn over everything
  canvas:   ui.Canvas,
}

// init prepares the debug UI, laid out in a `reference` frame (the window's size by default,
// render.window_size), and uploads its atlas to r. Call it once render.ready, and again
// (after shutdown) after each render.teardown, which frees the atlas.
init :: proc(self: ^Context, r: ^render.Renderer, reference := [2]f32{}) -> bool {
  mu.init(&self.mu)
  reference := reference if reference != {} else render.window_size(r)
  self.reference = reference
  self.size = reference
  self.mu.text_width = mu.default_atlas_text_width
  self.mu.text_height = mu.default_atlas_text_height
  ok: bool
  self.atlas, ok = render.texture_create(r, mu.default_atlas_alpha[:], {mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT}, .A8)
  return ok
}

// shutdown frees what the debug UI holds; render.shutdown frees its atlas.
shutdown :: proc(self: ^Context) {
  delete(self.windows)
  ui.destroy(&self.canvas)
  self^ = {}
}

// window opens a microui window, as mu.window does, with `rect` in the reference frame: it
// starts there, and when the window size changes it holds to the edges `pin` says
// (one choice per axis; stretch widens it). It closes itself at the end of the enclosing scope.
@(deferred_in_out = window_end)
window :: proc(self: ^Context, title: string, rect: mu.Rect, pin: ui.Anchor = {}, opt := mu.Options{}) -> bool {
  id := mu.get_id(&self.mu, title)
  from, placed := self.windows[id]
  r := rect
  if !placed {
    f := ui.fit(to_rect(rect), pin, self.reference, self.size)
    r = from_rect(f)
  } else if from != self.size {
    if cnt := mu.get_container(&self.mu, title, opt); cnt != nil {
      cnt.rect = from_rect(ui.fit(to_rect(cnt.rect), pin, from, self.size))
    }
  }
  self.windows[id] = self.size
  return mu.begin_window(&self.mu, title, r, opt)
}

@(private = "file")
window_end :: proc(self: ^Context, _: string, _: mu.Rect, _: ui.Anchor, _: mu.Options, ok: bool) {
  if ok do mu.end_window(&self.mu)
}

@(private = "file")
to_rect :: proc(r: mu.Rect) -> ui.Rect {
  return {{f32(r.x), f32(r.y)}, {f32(r.w), f32(r.h)}}
}

@(private = "file")
from_rect :: proc(r: ui.Rect) -> mu.Rect {
  return {i32(math.round(r.pos.x)), i32(math.round(r.pos.y)), i32(math.round(r.size.x)), i32(math.round(r.size.y))}
}

// begin returns the microui context for this tick. Its first call of a tick feeds it the tick's
// input and r's window size, and captures the mouse and keyboard the UI uses
// (input.State.mouse_captured / keyboard_captured): call it before your other input consumers,
// build the widgets, then call end.
begin :: proc(self: ^Context, s: ^input.State, r: ^render.Renderer) -> ^mu.Context {
  if !self.open {
    feed(self, s, r)
    mu.begin(&self.mu)
    self.open = true
  }
  return &self.mu
}

// end closes this tick's UI and stages it on r over everything else (render.stage_overlay);
// nothing when begin was not called.
end :: proc(self: ^Context, r: ^render.Renderer) {
  c := &self.canvas
  ui.reset(c)
  if !self.open do return
  mu.end(&self.mu)
  self.open = false
  c.z = max(i32)
  hidden := false
  iter: ^mu.Command
  for variant in mu.next_command_iterator(&self.mu, &iter) {
    switch cmd in variant {
    case ^mu.Command_Rect:
      if !hidden do quad(self, cmd.rect, mu.default_atlas[mu.DEFAULT_ATLAS_WHITE], cmd.color)
    case ^mu.Command_Text:
      if hidden do continue
      dst := mu.Rect{cmd.pos.x, cmd.pos.y, 0, 0}
      for ch in cmd.str {
        if ch & 0xc0 == 0x80 do continue
        src := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + min(int(ch), 127)]
        dst.w, dst.h = src.w, src.h
        quad(self, dst, src, cmd.color)
        dst.x += dst.w
      }
    case ^mu.Command_Icon:
      if hidden do continue
      src := mu.default_atlas[cmd.id]
      x := cmd.rect.x + (cmd.rect.w - src.w) / 2
      y := cmd.rect.y + (cmd.rect.h - src.h) / 2
      quad(self, {x, y, src.w, src.h}, src, cmd.color)
    case ^mu.Command_Clip:
      // a zero clip would mean the whole window: skip what it hides
      hidden = cmd.rect.w <= 0 || cmd.rect.h <= 0
      c.clip = to_rect(cmd.rect)
    case ^mu.Command_Jump:
      unreachable()
    }
  }
  render.stage_overlay(r, {c})
}

// Draws the atlas cell `src` over `dst`.
@(private = "file")
quad :: proc(self: ^Context, dst, src: mu.Rect, color: mu.Color) {
  atlas := [2]f32{mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT}
  uv0 := [2]f32{f32(src.x), f32(src.y)} / atlas
  uv1 := [2]f32{f32(src.x + src.w), f32(src.y + src.h)} / atlas
  uv := [4][2]f32{uv0, {uv1.x, uv0.y}, uv1, {uv0.x, uv1.y}}
  ui.rect(&self.canvas, to_rect(dst), {color.r, color.g, color.b, color.a}, u32(self.atlas), uv)
}

// Passes one input tick to the debug UI and reads r's window size (which windows keep to their
// edges in).
@(private = "file")
feed :: proc(self: ^Context, s: ^input.State, r: ^render.Renderer) {
  ctx := &self.mu
  hovered := ctx.hover_root != nil
  self.size = render.window_size(r)
  x, y := i32(math.round(s.cursor.x)), i32(math.round(s.cursor.y))
  mu.input_mouse_move(ctx, x, y)
  for b in input.MouseButton {
    // a press over the debug UI belongs to it until the tick after release
    if input.mouse_pressed(s, b) && hovered do self.buttons += {b}
    else if !input.mouse_down(s, b) && !input.mouse_released(s, b) do self.buttons -= {b}
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
  if ctx.hover_root != nil || self.buttons != {} do s.mouse_captured = true
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

