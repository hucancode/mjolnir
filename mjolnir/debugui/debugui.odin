package debugui

import "../anchor"
import "../input"
import "../render"
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
  vertices: [dynamic]render.Vertex2D,
  indices:  [dynamic]u32,
  commands: [dynamic]render.RenderCommand,
}

// init prepares the debug UI, laid out in a `reference` frame (the window's size by default,
// render.window_size), and uploads its atlas to r. Call it once render.ready, before
// render.setup if the application tears maps down, so the atlas outlives render.teardown.
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
  delete(self.vertices)
  delete(self.indices)
  delete(self.commands)
  self^ = {}
}

// window opens a microui window, as mu.window does, with `rect` in the reference frame: it
// starts there, and when the window size changes it holds to the edges `pin` says
// (one choice per axis; stretch widens it). It closes itself at the end of the enclosing scope.
@(deferred_in_out = window_end)
window :: proc(self: ^Context, title: string, rect: mu.Rect, pin: anchor.Anchor = {}, opt := mu.Options{}) -> bool {
  id := mu.get_id(&self.mu, title)
  from, placed := self.windows[id]
  r := rect
  if !placed {
    f := anchor.fit(to_anchor_rect(rect), pin, self.reference, self.size)
    r = from_anchor_rect(f)
  } else if from != self.size {
    if cnt := mu.get_container(&self.mu, title, opt); cnt != nil {
      cnt.rect = from_anchor_rect(anchor.fit(to_anchor_rect(cnt.rect), pin, from, self.size))
    }
  }
  self.windows[id] = self.size
  return mu.begin_window(&self.mu, title, r, opt)
}

@(private = "file")
window_end :: proc(self: ^Context, _: string, _: mu.Rect, _: anchor.Anchor, _: mu.Options, ok: bool) {
  if ok do mu.end_window(&self.mu)
}

@(private = "file")
to_anchor_rect :: proc(r: mu.Rect) -> anchor.Rect {
  return {{f32(r.x), f32(r.y)}, {f32(r.w), f32(r.h)}}
}

@(private = "file")
from_anchor_rect :: proc(r: anchor.Rect) -> mu.Rect {
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
  clear(&self.vertices)
  clear(&self.indices)
  clear(&self.commands)
  if !self.open do return
  mu.end(&self.mu)
  self.open = false
  // one mesh command per clip rect; the vertices are sliced once they stop growing
  Run :: struct {
    clip:          anchor.Rect,
    first_vertex:  int,
    first_index:   int,
  }
  runs := make([dynamic]Run, context.temp_allocator)
  append(&runs, Run{})
  hidden := false
  iter: ^mu.Command
  for variant in mu.next_command_iterator(&self.mu, &iter) {
    switch c in variant {
    case ^mu.Command_Rect:
      if !hidden do quad(self, c.rect, mu.default_atlas[mu.DEFAULT_ATLAS_WHITE], c.color)
    case ^mu.Command_Text:
      if hidden do continue
      dst := mu.Rect{c.pos.x, c.pos.y, 0, 0}
      for ch in c.str {
        if ch & 0xc0 == 0x80 do continue
        src := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + min(int(ch), 127)]
        dst.w, dst.h = src.w, src.h
        quad(self, dst, src, c.color)
        dst.x += dst.w
      }
    case ^mu.Command_Icon:
      if hidden do continue
      src := mu.default_atlas[c.id]
      x := c.rect.x + (c.rect.w - src.w) / 2
      y := c.rect.y + (c.rect.h - src.h) / 2
      quad(self, {x, y, src.w, src.h}, src, c.color)
    case ^mu.Command_Clip:
      // a zero clip would mean the whole framebuffer to render: skip what it hides
      hidden = c.rect.w <= 0 || c.rect.h <= 0
      clip := to_anchor_rect(c.rect)
      append(&runs, Run{
        clip = clip,
        first_vertex = len(self.vertices),
        first_index = len(self.indices),
      })
    case ^mu.Command_Jump:
      unreachable()
    }
  }
  for run, i in runs {
    last_vertex := runs[i + 1].first_vertex if i + 1 < len(runs) else len(self.vertices)
    last_index := runs[i + 1].first_index if i + 1 < len(runs) else len(self.indices)
    if last_index == run.first_index do continue
    // indices are relative to the run's first vertex
    for &idx in self.indices[run.first_index:last_index] do idx -= u32(run.first_vertex)
    append(&self.commands, render.RenderCommand{
      shape = render.DrawMeshCommand{
        vertices = self.vertices[run.first_vertex:last_vertex],
        indices = self.indices[run.first_index:last_index],
        texture = self.atlas,
      },
      z_order = max(i32),
      clip = run.clip,
    })
  }
  render.stage_overlay(r, self.commands[:])
}

@(private = "file")
quad :: proc(self: ^Context, dst, src: mu.Rect, color: mu.Color) {
  atlas_size := [2]f32{mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT}
  p0 := [2]f32{f32(dst.x), f32(dst.y)}
  p1 := [2]f32{f32(dst.x + dst.w), f32(dst.y + dst.h)}
  uv0 := [2]f32{f32(src.x), f32(src.y)} / atlas_size
  uv1 := [2]f32{f32(src.x + src.w), f32(src.y + src.h)} / atlas_size
  rgba := [4]u8{color.r, color.g, color.b, color.a}
  base := u32(len(self.vertices))
  append(&self.vertices,
    render.Vertex2D{p0, uv0, rgba},
    render.Vertex2D{{p1.x, p0.y}, {uv1.x, uv0.y}, rgba},
    render.Vertex2D{p1, uv1, rgba},
    render.Vertex2D{{p0.x, p1.y}, {uv0.x, uv1.y}, rgba},
  )
  append(&self.indices, base, base + 1, base + 2, base, base + 2, base + 3)
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

