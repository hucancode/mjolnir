package ui

import res "../resources"
import "core:log"

HorizontalAlign :: enum {
  Left,
  Center,
  Right,
}

VerticalAlign :: enum {
  Top,
  Middle,
  Bottom,
}

WidgetBase :: struct {
  type:           WidgetType,
  position:       [2]f32,
  world_position: [2]f32,
  z_order:        i32,
  visible:        bool,
  parent:         Maybe(UIWidgetHandle),
  event_handlers: EventHandlers,
  user_data:      rawptr,
}

Mesh2D :: struct {
  using widget_base: WidgetBase,
  vertices:          []Vertex2D,
  indices:           []u32,
  texture:           res.Image2DHandle,
  vertex_offset:     u32,
  index_offset:      u32,
}

Quad2D :: struct {
  using widget_base: WidgetBase,
  size:              [2]f32,
  texture:           res.Image2DHandle,
  color:             [4]u8,
}

// Store fontstash quad directly for correct rendering
GlyphQuad :: struct {
  x0, y0, x1, y1: f32, // positions
  s0, t0, s1, t1: f32, // UVs
}

Text2D :: struct {
  using widget_base: WidgetBase,
  text:              string,
  font_size:         f32,
  color:             [4]u8,
  glyphs:            [dynamic]GlyphQuad,
  bounds:            [2]f32, // Width and height of the alignment rectangle (0,0 = no bounds)
  h_align:           HorizontalAlign,
  v_align:           VerticalAlign,
  text_width:        f32, // Actual width of the laid out text
  text_height:       f32, // Actual height of the laid out text
}

Box :: struct {
  using widget_base: WidgetBase,
  size:              [2]f32,
  background_color:  [4]u8,
  children:          [dynamic]UIWidgetHandle,
}

Widget :: union {
  Mesh2D,
  Quad2D,
  Text2D,
  Box,
}

get_widget_base :: proc(widget: ^Widget) -> ^WidgetBase {
  switch &w in widget {
  case Mesh2D:
    return &w.widget_base
  case Quad2D:
    return &w.widget_base
  case Text2D:
    return &w.widget_base
  case Box:
    return &w.widget_base
  }
  return nil
}

get_widget_type :: proc(widget: ^Widget) -> WidgetType {
  switch w in widget {
  case Mesh2D:
    return .Mesh2D
  case Quad2D:
    return .Quad2D
  case Text2D:
    return .Text2D
  case Box:
    return .Box
  }
  return .Box
}
