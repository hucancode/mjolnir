# `mjolnir/ui` — API Reference

Layer 2. Logical 2D UI: widget tree, layout, hit-testing, event dispatch,
font atlas. The render side lives in `mjolnir/render/ui/`.

## System

```odin
System :: struct {
  widget_pool:      cont.Pool(Widget),
  default_texture:  gpu.Texture2DHandle,
  font_context:     ^fs.FontContext,        // fontstash
  font_atlas:       gpu.Texture2DHandle,
  font_atlas_dirty: bool,
  staging:          [dynamic]cmd.RenderCommand,
}
```

```odin
init                   (self, max_widgets: u32 = 4096)
init_gpu_resources     (self, gctx, texture_manager)
shutdown_gpu_resources (self, gctx, texture_manager)
shutdown               (self)

update_font_atlas (self, gctx, texture_manager)
get_font_atlas_id (self) -> u32
generate_render_commands(self)
```

## Widgets

```odin
WidgetType :: enum { Mesh2D, Quad2D, Text2D, Box }

Widget :: union { Mesh2D, Quad2D, Text2D, Box }

UIWidgetHandle :: distinct cont.Handle
Mesh2DHandle   :: distinct UIWidgetHandle
Quad2DHandle   :: distinct UIWidgetHandle
Text2DHandle   :: distinct UIWidgetHandle
BoxHandle      :: distinct UIWidgetHandle

HorizontalAlign :: enum { Left, Center, Right }
VerticalAlign   :: enum { Top, Middle, Bottom }

WidgetBase :: struct {
  position:       [2]f32,
  world_position: [2]f32,
  z_order:        i32,
  visible:        bool,
  parent:         Maybe(UIWidgetHandle),
  event_handlers: EventHandlers,
  user_data:      rawptr,
}

Mesh2D :: struct {
  using base:    WidgetBase,
  vertices:      []cmd.Vertex2D,
  indices:       []u32,
  texture:       gpu.Texture2DHandle,
  vertex_offset: u32,
  index_offset:  u32,
}

Quad2D :: struct {
  using base: WidgetBase,
  size:       [2]f32,
  texture:    gpu.Texture2DHandle,
  color:      [4]u8,
}

GlyphQuad :: struct { p0, p1, uv0, uv1: [2]f32 }

Text2D :: struct {
  using base:  WidgetBase,
  text:        string,
  font_size:   f32,
  color:       [4]u8,
  glyphs:      [dynamic]GlyphQuad,
  bounds:      [2]f32,
  h_align:     HorizontalAlign,
  v_align:     VerticalAlign,
  text_width:  f32,
  text_height: f32,
}

Box :: struct {
  using base:       WidgetBase,
  size:             [2]f32,
  background_color: [4]u8,
  children:         [dynamic]UIWidgetHandle,
}

get_widget_base(widget: ^Widget) -> ^WidgetBase
```

## Lookups

```odin
get_widget(sys, handle: UIWidgetHandle) -> ^Widget
get_mesh2d(sys, Mesh2DHandle)           -> ^Mesh2D
get_quad2d(sys, Quad2DHandle)           -> ^Quad2D
get_text2d(sys, Text2DHandle)           -> ^Text2D
get_box   (sys, BoxHandle)              -> ^Box
```

## Mutators

```odin
set_position     (widget: ^Widget, position: [2]f32)
set_z_order      (widget: ^Widget, z: i32)
set_visible      (widget: ^Widget, visible: bool)
set_event_handler(widget: ^Widget, handlers: EventHandlers)
set_user_data    (widget: ^Widget, data: rawptr)
destroy_widget   (sys, handle: UIWidgetHandle)
```

## Primitives

```odin
create_mesh2d(sys, position, vertices: []cmd.Vertex2D, indices: []u32,
              texture: gpu.Texture2DHandle = {}, z_order = 0) -> (Mesh2DHandle, bool)
create_quad2d(sys, position, size, texture = {}, color = {255,255,255,255}, z_order = 0)
             -> (Quad2DHandle, bool)
```

## Text

```odin
create_text2d(sys, position, text: string, font_size: f32,
              color = {255,255,255,255}, z_order = 0,
              bounds = {0,0}, h_align = .Left, v_align = .Top)
             -> (Text2DHandle, bool)
text_layout(text: ^Text2D, font_ctx: ^fs.FontContext)
set_text   (sys, handle: Text2DHandle, new_text: string)
```

## Box (container)

```odin
create_box       (sys, position, size, background_color = {0,0,0,0}, z_order = 0)
                -> (BoxHandle, bool)
box_add_child    (sys, parent: BoxHandle, child: UIWidgetHandle)
box_remove_child (sys, parent: BoxHandle, child: UIWidgetHandle)
```

## Layout

```odin
compute_layout    (sys, root: UIWidgetHandle)
compute_layout_all(sys)
```

## Events

```odin
MouseEventType :: enum { CLICK_DOWN, CLICK_UP, MOVE, HOVER_IN, HOVER_OUT }
KeyEventType   :: enum { KEY_DOWN, KEY_UP }

MouseEvent :: struct { type: MouseEventType, position: [2]f32, button: i32, widget: UIWidgetHandle, user_data: rawptr }
KeyEvent   :: struct { type: KeyEventType, key: i32, widget: UIWidgetHandle, user_data: rawptr }

MouseEventProc :: #type proc(event: MouseEvent)
KeyEventProc   :: #type proc(event: KeyEvent)

EventHandlers :: struct {
  on_mouse_down: MouseEventProc,
  on_mouse_up:   MouseEventProc,
  on_move:       MouseEventProc,
  on_hover_in:   MouseEventProc,
  on_hover_out:  MouseEventProc,
  on_key_down:   KeyEventProc,
  on_key_up:     KeyEventProc,
}

point_in_widget   (widget, point: [2]f32) -> bool
pick_widget       (sys, point: [2]f32)    -> Maybe(UIWidgetHandle)
dispatch_mouse_event(sys, widget_handle, event: MouseEvent, bubble = true)
dispatch_key_event  (sys, widget_handle, event: KeyEvent,   bubble = true)
```

The engine main loop calls `pick_widget` + `dispatch_mouse_event` on every
frame inside `update_input`, generating HOVER/CLICK events automatically. You
register handlers via `set_event_handler`.
