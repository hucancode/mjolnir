---
title: UI
---

Layer 2. Logical 2D UI — widget tree, layout, hit-testing, event
dispatch, font atlas. The GPU side lives in `mjolnir/render/ui/` and
is driven by the engine.

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

The engine's input loop calls `pick_widget(point)` each frame, then
`dispatch_mouse_event` with the resulting handle. The picker walks
the widget tree top-down by z-order and returns the first widget
whose bounds contain the cursor.

Hover transitions (`HOVER_IN` / `HOVER_OUT`) are derived by tracking
the previous-frame hovered widget. Click events bubble parent-ward by
default so a click on a child of a `Box` also fires on the `Box`
unless the child stops propagation.

## Text

Fontstash backs glyph rasterization into a single atlas texture
managed by the UI system. Glyphs are cached on first use; the engine
calls `update_font_atlas` once per frame to upload any new glyphs to
the GPU.
