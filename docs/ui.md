---
title: UI
---

Layer 2. Retained 2D layout and hit testing over one flat pool of
nodes: flex rows and columns, anchors, text wrapping, clipping and
scrolling. `ui` draws nothing and holds no looks: it outputs a rect,
a clip rect and text lines per node, and the application turns them
into whatever its renderer draws, normally render's 2D overlay
commands. It imports `containers`, `input` and `font` only.

`font` (layer 1) wraps fontstash: `font.init(&f, ttf_data)`,
`measure`, `line_height`, `glyphs` (quads with uvs in atlas texels)
and `atlas` (the R8 pixels and whether they changed). `ui` measures
and wraps text with it; the application draws with it.

## Nodes

`ui.init(&gui)`, then `ui.create(&gui, ui.Node{...})` adds a node and
returns its `NodeHandle`. Every field is a layout input; zero values
are sensible defaults (a visible, content-sized row at the parent's
start):

- `parent` — the node it sits in; none makes it a root, sitting in the
  viewport.
- `size: [2]Size` per axis: `FIT` wraps the content (flow children,
  text, padding), `FIXED` is `value` pixels, `GROW` shares the parent's
  free space by weight `value` (at least its fit), `PERCENT` is `value`
  of the parent's content box.
- `padding` (left, top, right, bottom), `gap` between flow children,
  `direction` (`ROW`, `COLUMN`) of the flow, and `align` per axis
  (`START`, `CENTER`, `END`) of the flow children and text lines in the
  content box.
- `position`: `FLOW` follows the previous sibling; `ABSOLUTE` puts the
  node's `anchor` point (0..1 of its size) on the same point of the
  parent's rect, so `{1, 0}` pins top-right corners. `offset` is added
  either way.
- `clip` clips the children to the node; `scroll` shifts them by
  `-scroll`.
- `hidden` hides the subtree, which then takes no space. `z` is added
  to the parent's; higher draws and picks on top. `order` is the flow
  order among siblings, the creation order by default.
- `interactive` makes the node, and every node inside it, hoverable and
  clickable; `focusable` lets a press focus it.
- `text`, `font_size`, `wrap`: a text node's content, wrapped at word
  boundaries to its width when `wrap`. Change text with `set_text`;
  `ui.node(&gui, h)` returns a pointer for every other field.

`destroy_node` removes a node and its subtree. The parent link is the
only tree link, so re-parenting is one field write.

## Layout

`ui.layout(&gui, viewport, &font)` lays out every node in a fixed
sequence of passes over the nodes in tree order, with no recursion:
content sizes bottom-up and sizes top-down per axis (widths, then text
wrapping, then heights), then positions, clips, visibility and depth
top-down. It writes:

- `ui.rect(&gui, h)` and `ui.clip(&gui, h)` — where the node is and
  the part of the viewport it may draw in;
- `ui.lines(&gui, h)` — its text lines, each a byte range of `text`
  with its top-left and width;
- `gui.draw_order` — every shown node, back to front.

Work in any unit as long as the viewport, font sizes and cursor agree,
e.g. window pixels, scaling by the DPI scale when drawing.

## Input

`ui.update_input(&gui, &state)` runs one tick against the last layout.
`pick` finds the topmost shown node under the cursor, inside its clip,
that is interactive or inside an interactive node. The UI tracks that
node as hovered, the node pressed until every button releases, the
nearest focusable node of the last press, and a click when a press is
released over the node it started on. The queries `hovered`,
`pressed`, `clicked` and `focused` are true for a node and everything
inside it, so a button's label acts for the button. There are no
callbacks: the application polls. `update_input` captures the mouse
while a node is hovered or pressed and the keyboard while one is
focused; it skips a tick whose mouse an earlier consumer captured.

## Drawing

The application walks `gui.draw_order` and emits commands; render sorts
them by `z_order` and batches by clip:

```odin
for h, z in gui.draw_order {
  r, c := ui.rect(&gui, h), ui.clip(&gui, h)
  clip := [4]f32{c.pos.x, c.pos.y, c.size.x, c.size.y}
  if look, ok := looks[h]; ok do append(&cmds, render.DrawQuadCommand{r.pos, r.size, look.color, look.texture, i32(z), clip})
  n := ui.node(&gui, h)
  for line in ui.lines(&gui, h) {
    glyphs := make([dynamic]font.Glyph, context.temp_allocator)
    font.glyphs(&f, n.text[line.start:line.end], line.pos, n.font_size, &glyphs)
    append(&cmds, render.DrawTextCommand{glyphs[:], text_color, i32(z), clip})
  }
}
pixels, size, changed := font.atlas(&f)
render.stage_overlay(&r, {commands = cmds[:], atlas = pixels if changed else nil, atlas_size = size})
```

`examples/ui` shows a button with hover and press colors, a flex
panel, wrapped text, a scrolled list, an anchored HUD corner, an image
and a mesh.
