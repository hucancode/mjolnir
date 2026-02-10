package ui

import cont "../containers"
import "core:log"
import "core:strings"
import fs "vendor:fontstash"

create_text2d :: proc(
  sys: ^System,
  renderer: ^Renderer,
  position: [2]f32,
  text: string,
  font_size: f32,
  color: [4]u8 = {255, 255, 255, 255},
  z_order: i32 = 0,
  bounds: [2]f32 = {0, 0},
  h_align: HorizontalAlign = .Left,
  v_align: VerticalAlign = .Top,
) -> (
  Text2DHandle,
  bool,
) {
  handle, widget, ok := cont.alloc(&sys.widget_pool, UIWidgetHandle)
  if !ok {
    log.error("Failed to allocate UI widget handle for Text2D")
    return {}, false
  }

  text_copy := strings.clone(text)
  glyphs := make([dynamic]GlyphQuad, 0, len(text))

  widget^ = Text2D {
    type           = .Text2D,
    position       = position,
    world_position = position,
    z_order        = z_order,
    visible        = true,
    text           = text_copy,
    font_size      = font_size,
    color          = color,
    glyphs         = glyphs,
    bounds         = bounds,
    h_align        = h_align,
    v_align        = v_align,
  }

  // Layout text
  text_layout(&widget.(Text2D), renderer.font_context)

  return Text2DHandle(handle), true
}

text_layout :: proc(text: ^Text2D, font_ctx: ^fs.FontContext) {
  if font_ctx == nil do return

  clear(&text.glyphs)

  if len(text.text) == 0 do return

  // Set up fontstash state
  fs.ClearState(font_ctx)
  fs.SetSize(font_ctx, text.font_size)
  fs.SetFont(font_ctx, 0) // Use default font (index 0)

  // Measure text bounds first
  bounds: [4]f32
  fs.TextBounds(font_ctx, text.text, 0, 0, &bounds)
  text.text_width = bounds[2] - bounds[0]
  text.text_height = bounds[3] - bounds[1]

  // Calculate alignment offset
  offset_x: f32 = 0
  offset_y: f32 = 0

  if text.bounds.x > 0 && text.bounds.y > 0 {
    // Horizontal alignment
    switch text.h_align {
    case .Left:
      offset_x = 0
    case .Center:
      offset_x = (text.bounds.x - text.text_width) / 2
    case .Right:
      offset_x = text.bounds.x - text.text_width
    }

    // Vertical alignment
    switch text.v_align {
    case .Top:
      offset_y = 0
    case .Middle:
      offset_y = (text.bounds.y - text.text_height) / 2
    case .Bottom:
      offset_y = text.bounds.y - text.text_height
    }
  }

  // Initialize text iterator with alignment offset
  iter := fs.TextIterInit(font_ctx, offset_x, offset_y, text.text)

  // Iterate through glyphs
  quad: fs.Quad
  glyph_index := 0
  for fs.TextIterNext(font_ctx, &iter, &quad) {
    // Store the fontstash quad directly
    glyph := GlyphQuad {
      x0 = quad.x0,
      y0 = quad.y0,
      x1 = quad.x1,
      y1 = quad.y1,
      s0 = quad.s0,
      t0 = quad.t0,
      s1 = quad.s1,
      t1 = quad.t1,
    }
    append(&text.glyphs, glyph)
    glyph_index += 1
  }
  // Force fontstash to rasterize the glyphs we just laid out
  dirty_rect: [4]f32
  if fs.ValidateTexture(font_ctx, &dirty_rect) {
    log.debugf(
      "Forced glyph rasterization: dirty rect (%.0f,%.0f,%.0f,%.0f)",
      dirty_rect[0],
      dirty_rect[1],
      dirty_rect[2],
      dirty_rect[3],
    )
  }
  log.debugf(
    "Text layout complete: '%s' -> %d glyphs, size: %.1fx%.1f, offset: %.1f,%.1f",
    text.text,
    len(text.glyphs),
    text.text_width,
    text.text_height,
    offset_x,
    offset_y,
  )
}

set_text :: proc(
  sys: ^System,
  renderer: ^Renderer,
  handle: Text2DHandle,
  new_text: string,
) {
  text_widget := get_text2d(sys, handle)
  if text_widget == nil do return

  delete(text_widget.text)
  text_widget.text = strings.clone(new_text)

  // Re-layout
  text_layout(text_widget, renderer.font_context)
}
