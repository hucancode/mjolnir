package debugui

import "../input"
import "../render"
import "core:math"
import mu "vendor:microui"

// Context is the debug UI: build widgets on its microui context (mu) between begin and end.
Context :: struct {
  mu:      mu.Context,
  using _: Context_State,
}

@(private)
Context_State :: struct {
  // microui's builtin font and icon atlas
  atlas:    render.TextureHandle,
  // buttons pressed over the UI, owned by it through release
  buttons:  input.ButtonSet,
  // begin opened mu this tick; end closes it
  open:     bool,
  vertices: [dynamic]render.Vertex2D,
  indices:  [dynamic]u32,
  commands: [dynamic]render.RenderCommand,
}

// init prepares the debug UI and uploads its atlas to r. Call it once render.ready, before
// render.setup if the application tears maps down, so the atlas outlives render.teardown.
init :: proc(self: ^Context, r: ^render.Renderer) -> bool {
  mu.init(&self.mu)
  self.mu.text_width = mu.default_atlas_text_width
  self.mu.text_height = mu.default_atlas_text_height
  ok: bool
  self.atlas, ok = render.texture_create(r, mu.default_atlas_alpha[:], {mu.DEFAULT_ATLAS_WIDTH, mu.DEFAULT_ATLAS_HEIGHT}, .A8)
  return ok
}

// shutdown frees what the debug UI holds; render.shutdown frees its atlas.
shutdown :: proc(self: ^Context) {
  delete(self.vertices)
  delete(self.indices)
  delete(self.commands)
  self^ = {}
}

// begin returns the microui context for this tick, opening it on the first call. Build
// widgets with it in update after feed, then hand end's commands to render.stage_overlay.
begin :: proc(self: ^Context) -> ^mu.Context {
  if !self.open {
    mu.begin(&self.mu)
    self.open = true
  }
  return &self.mu
}

// end closes this tick's UI and returns it as overlay commands drawn over everything else;
// none when begin was not called. Valid until the next end.
end :: proc(self: ^Context) -> []render.RenderCommand {
  clear(&self.vertices)
  clear(&self.indices)
  clear(&self.commands)
  if !self.open do return nil
  mu.end(&self.mu)
  self.open = false
  // one mesh command per clip rect; the vertices are sliced once they stop growing
  Run :: struct {
    clip:          [4]f32,
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
      append(&runs, Run{
        clip = [4]f32{f32(c.rect.x), f32(c.rect.y), f32(c.rect.w), f32(c.rect.h)},
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
  return self.commands[:]
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

// feed passes one input tick to the debug UI and captures the mouse and keyboard it uses
// (input.State.mouse_captured / keyboard_captured). Call it first among input consumers on
// the update tick.
feed :: proc(self: ^Context, s: ^input.State) {
  ctx := &self.mu
  hovered := ctx.hover_root != nil
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

