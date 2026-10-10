---
title: UI
---

Layer 2. Logical 2D UI — widget tree, layout, hit-testing, event
dispatch, font atlas. Its output is a list of `draw2d` commands
(`build_commands`); drawing them is the renderer's job
(`render.stage_ui`). `ui.Vertex2D` and `ui.NO_TEXTURE` re-export the
`draw2d` types that appear in widget APIs. `init` fails if the font
cannot be loaded.

## Widgets

Four kinds, all sharing a `WidgetBase` (position, z-order, visible
flag, parent, event handlers, user-data pointer):

- **Mesh2D** — arbitrary triangle list, for shapes the other
  primitives can't express.
- **Quad2D** — colored or textured rectangle. The workhorse.
- **Text2D** — fontstash-laid-out glyph quads with horizontal +
  vertical alignment inside a bounds box.
- **Box** — container with children; the parent-relative coordinate
  origin for everything beneath it.

Each widget kind has its own distinct handle type
(`Quad2DHandle`, …) on top of `UIWidgetHandle` for compile-time
safety.

## Layout

Layout is parent-relative + z-ordered. `compute_layout_all` resolves
every `Box` subtree once per frame after user mutations; the engine
calls it before generating draw commands.

Z-ordering uses a stable integer rather than insertion order so
overlays, modals, and HUD layers can be set explicitly without
re-parenting.

## Events

The engine calls `process_mouse(&sys, position, buttons)` once per
tick with the cursor position and raw button state. It picks the
widget under the cursor (top-down by z-order, first whose bounds
contain the point) and dispatches events to it. `System` keeps the
previous tick's hovered widget and button state, so hover transitions
(`HOVER_IN` / `HOVER_OUT`) and press / release edges need no
caller-side bookkeeping. `pick_widget` and `dispatch_mouse_event` are
available for custom input routing. Click events bubble parent-ward by
default so a click on a child of a `Box` also fires on the `Box`
unless the child stops propagation.

## Text

Fontstash backs glyph rasterization into a single atlas managed by
the UI system. Glyphs are cached on first use. `take_font_atlas`
returns the atlas pixels and whether glyphs were added since the last
call; the engine uploads them with `render.stage_ui_font_atlas` when
they change.
