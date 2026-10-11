package render

import cont "../containers"
import "core:log"
import "core:slice"
import fs "vendor:fontstash"

UISystem :: struct {
  widget_pool:  cont.Pool(Widget),
  font_context: ^fs.FontContext,
  // atlas size the text glyph uvs were laid out against
  atlas_size:   [2]int,
  staging:      [dynamic]RenderCommand,
  hovered:      Maybe(UIWidgetHandle), // interactive widget under the cursor
  captured:     Maybe(UIWidgetHandle), // pressed widget, kept until all buttons release
  focused:      Maybe(UIWidgetHandle), // receives key and text events
}

// Glyph sizes rasterized at init so the first atlas upload covers typical
// text without growing the atlas; other sizes rasterize on first use.
DEFAULT_PREWARM_SIZES :: []f32{14, 16, 20, 24}

// font_data is a TTF/OTF file in memory; it is copied.
ui_init :: proc(
  self: ^UISystem,
  font_data: []u8,
  max_widgets: u32 = 4096,
  prewarm_sizes: []f32 = DEFAULT_PREWARM_SIZES,
) -> bool {
  cont.init(&self.widget_pool, max_widgets)
  self.staging = make([dynamic]RenderCommand, 0, 256)
  font_atlas_width := 512
  font_atlas_height := 512
  self.font_context = new(fs.FontContext)
  fs.Init(self.font_context, font_atlas_width, font_atlas_height, .TOPLEFT)
  font_index := fs.AddFontMem(self.font_context, "default", slice.clone(font_data), true)
  if font_index == fs.INVALID {
    log.errorf("Failed to load UI font (%d bytes)", len(font_data))
    return false
  }
  fs.SetFont(self.font_context, font_index)
  fs.SetColor(self.font_context, {255, 255, 255, 255})
  test_string := " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
  for size in prewarm_sizes {
    fs.SetSize(self.font_context, size)
    iter := fs.TextIterInit(self.font_context, 0, 0, test_string)
    quad: fs.Quad
    for fs.TextIterNext(self.font_context, &iter, &quad) {}
  }
  log.info("UI system initialized with fontstash")
  return true
}

ui_shutdown :: proc(self: ^UISystem) {
  cont.destroy(&self.widget_pool, cleanup_widget)
  delete(self.staging)
  if self.font_context != nil {
    fs.Destroy(self.font_context)
    free(self.font_context)
  }
  log.info("UI system shutdown")
}

// Font atlas pixels (R8, width x height). changed is true when glyphs were
// rasterized since the previous call.
@(private = "file")
take_font_atlas :: proc(
  self: ^UISystem,
) -> (
  pixels: []u8,
  width, height: u32,
  changed: bool,
) {
  if self.font_context == nil do return
  dirty_rect: [4]f32
  changed = fs.ValidateTexture(self.font_context, &dirty_rect)
  pixels = self.font_context.textureData
  width = u32(self.font_context.width)
  height = u32(self.font_context.height)
  return
}

@(private)
cleanup_widget :: proc(widget: ^Widget) {
  switch &w in widget {
  case Mesh2D:
    delete(w.vertices)
    delete(w.indices)
  case Quad2D:
  // No dynamic allocations
  case Text2D:
    delete(w.text)
    delete(w.glyphs)
  case Box:
    delete(w.children)
  }
}

UIWidgetHandle :: distinct cont.Handle
Mesh2DHandle :: distinct UIWidgetHandle
Quad2DHandle :: distinct UIWidgetHandle
Text2DHandle :: distinct UIWidgetHandle
BoxHandle :: distinct UIWidgetHandle

get_widget :: proc(sys: ^UISystem, handle: UIWidgetHandle) -> ^Widget {
  widget, ok := cont.get(sys.widget_pool, handle)
  if !ok do return nil
  return widget
}

// The widget behind `handle` as a T (Quad2D, Text2D, Mesh2D or Box); nil when
// the handle is stale or the widget is another kind.
get_as :: proc(sys: ^UISystem, handle: $H, $T: typeid) -> ^T {
  widget := get_widget(sys, UIWidgetHandle(handle))
  if widget == nil do return nil
  w, ok := &widget.(T)
  return w if ok else nil
}

// Destroy a widget and, for a Box, its children.
destroy_widget :: proc(sys: ^UISystem, handle: UIWidgetHandle) {
  widget := get_widget(sys, handle)
  if widget == nil do return
  if box, is_box := widget.(Box); is_box {
    for child in box.children do destroy_widget(sys, child)
  }
  cleanup_widget(widget)
  cont.free(&sys.widget_pool, handle)
}

// This frame's draw commands plus the font atlas when it changed. Hand it to
// the 2D renderer; the commands stay valid until the next call.
draw_list :: proc(sys: ^UISystem) -> DrawList {
  relayout_on_atlas_growth(sys)
  list := DrawList{commands = build_commands(sys)}
  if pixels, w, h, changed := take_font_atlas(sys); changed {
    list.atlas = pixels
    list.atlas_size = {w, h}
  }
  return list
}

// Growing the atlas rescales every glyph uv; lay all text out again against
// the new size.
@(private = "file")
relayout_on_atlas_growth :: proc(sys: ^UISystem) {
  if sys.font_context == nil do return
  size := [2]int{sys.font_context.width, sys.font_context.height}
  if size == sys.atlas_size do return
  sys.atlas_size = size
  it := cont.iterator(&sys.widget_pool)
  for widget in cont.next(&it, UIWidgetHandle) {
    if text, ok := &widget.(Text2D); ok do text_layout(text, sys.font_context)
  }
}

// Lay out all widgets and return this frame's draw commands. The slice is
// valid until the next call; glyph data lives in the temp allocator.
@(private)
build_commands :: proc(sys: ^UISystem) -> []RenderCommand {
  compute_layout_all(sys)
  clear(&sys.staging)

  it := cont.iterator(&sys.widget_pool)
  for widget in cont.next(&it, UIWidgetHandle) {
    if !get_widget_base(widget).visible do continue

    switch &w in widget {
    case Quad2D:
      command := DrawQuadCommand {
        position   = w.world_position,
        size       = w.size,
        color      = w.color,
        texture_id = w.texture,
        z_order    = w.z_order,
      }
      append(&sys.staging, command)

    case Mesh2D:
      command := DrawMeshCommand {
        position   = w.world_position,
        vertices   = w.vertices,
        indices    = w.indices,
        texture_id = w.texture,
        z_order    = w.z_order,
      }
      append(&sys.staging, command)

    case Text2D:
      // Convert glyphs to draw commands
      glyphs := make([]DrawTextGlyph, len(w.glyphs), context.temp_allocator)
      for glyph, idx in w.glyphs {
        glyphs[idx] = DrawTextGlyph {
          p0    = glyph.p0,
          p1    = glyph.p1,
          uv0   = glyph.uv0,
          uv1   = glyph.uv1,
          color = w.color,
        }
      }
      command := DrawTextCommand {
        position = w.world_position,
        glyphs   = glyphs,
        z_order  = w.z_order,
      }
      append(&sys.staging, command)

    case Box:
      if w.background_color.a == 0 do continue
      command := DrawQuadCommand {
        position   = w.world_position,
        size       = w.size,
        color      = w.background_color,
        texture_id = NO_TEXTURE,
        z_order    = w.z_order,
      }
      append(&sys.staging, command)
    }
  }
  return sys.staging[:]
}
