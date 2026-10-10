---
title: UI
---

Layer 2. Logical 2D UI — widget tree, layout, hit-testing, event
dispatch, font atlas. Its output is a `draw2d.DrawList`
(`draw_list`): the frame's commands plus the font atlas when it
changed. Drawing them is the renderer's job (`render.stage_ui`). Input arrives as an `input.State` snapshot.
`ui.Vertex2D` and `ui.NO_TEXTURE` re-export the `draw2d` types that
appear in widget APIs.

`init(&sys, font_data)` takes a TTF/OTF file in memory (it is copied)
and fails if the font cannot be parsed. Reading the file is the
caller's job.

## Widgets

Four kinds, all sharing a `WidgetBase` (position, z-order, visible
flag, parent, event handlers, user-data pointer):

- **Mesh2D** — arbitrary triangle list, for shapes the other
  primitives can't express.
- **Quad2D** — colored or textured rectangle. The workhorse.
- **Text2D** — fontstash-laid-out glyph quads with horizontal +
  vertical alignment inside a bounds box. Change the string with
  `set_text`.
- **Box** — container with children; the parent-relative coordinate
  origin for everything beneath it.

Each widget kind has its own distinct handle type
(`Quad2DHandle`, …) on top of `UIWidgetHandle` for compile-time
safety. `get_quad2d`, `get_text2d`, `get_mesh2d`, `get_box` resolve a
handle to its widget pointer (nil for a stale handle); edit fields
directly. Shared fields go through `get_widget_base(get_widget(&sys, h))`,
e.g. `position`, `visible`, `event_handlers` and `user_data` (the pointer
delivered as `event.user_data`). Text2D strings change through
`set_text(&sys, text_handle, str)`, which re-lays out the glyphs.

```odin
if q := ui.get_quad2d(&sys, button); q != nil {
  q.color = {255, 100, 100, 255}
  q.event_handlers = handlers
  q.user_data = app
}
```

`box_add_child` / `box_remove_child` build the tree;
`destroy_widget` frees a widget and, for a Box, its subtree.

## Layout

Layout is parent-relative + z-ordered. `draw_list` resolves
every `Box` subtree before generating draw commands.

Z-ordering uses a stable integer rather than insertion order so
overlays, modals, and HUD layers can be set explicitly without
re-parenting.

## Events

`process_input(&sys, &state)` runs one input tick through the widget
tree. Hit testing considers only interactive widgets — those with a
mouse handler on themselves or an ancestor — top-down by z-order.
`System` keeps the hovered, captured and focused widget across ticks:

- `HOVER_IN` / `HOVER_OUT` when the hovered widget changes, `MOVE` to
  the captured or hovered widget.
- `CLICK_DOWN` to the hovered widget, which captures the mouse until
  every button is released and takes keyboard focus (a press over
  nothing clears focus); `CLICK_UP` to the captured widget.
- `KEY_DOWN` / `KEY_UP` (with OS auto-repeat flagged) and text events
  to the focused widget.

Every event bubbles to the parents. `process_input` skips the tick
while another consumer has captured the mouse. Otherwise it marks the
mouse captured while a widget is hovered or holds a press, and the
keyboard captured while the focused widget handles key or text
events. Hit testing and dispatch are internal; `process_input` is
the only entry point.

## Text

Fontstash backs glyph rasterization into a single atlas managed by
the UI system. Glyphs are cached on first use. `draw_list` carries the atlas pixels
only on frames where glyphs were added.
