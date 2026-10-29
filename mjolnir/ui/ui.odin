package ui

import "../anchor"
import "../containers"
import "../geometry"
import "core:strings"

// NodeHandle identifies a UI node; stale after node_destroy.
NodeHandle :: distinct containers.Handle

// Direction is the axis a node's flow children are placed along.
Direction :: enum u8 {
  ROW, // children flow along x
  COLUMN, // children flow along y
}

// SizeKind says how a Size is resolved.
SizeKind :: enum u8 {
  FIT, // wraps the content: flow children, text, padding
  FIXED, // `value` pixels
  GROW, // shares the parent's free space by weight `value` (0 counts as 1), at least FIT
  PERCENT, // `value` (0..1) of the parent's content box
}

// Size is one axis of a node's size: a kind and its value.
Size :: struct {
  kind:  SizeKind,
  value: f32,
}

// Align places content within a box on one axis.
Align :: enum u8 {
  START,
  CENTER,
  END,
}

// Position says whether a node takes part in its parent's flow. A root is always ABSOLUTE in
// the window.
Position :: enum u8 {
  FLOW, // placed after the previous flow sibling
  ABSOLUTE, // placed by anchor and offset in the parent's rect
}

// Node is one UI node. The application sets its layout inputs and its looks; ui writes its
// rect, clip, text lines and mesh on update.
Node :: struct {
  // the node this one sits in; none for a root, which sits in the window
  parent:      NodeHandle,
  size:        [2]Size,
  padding:     [4]f32, // left, top, right, bottom
  gap:         f32, // between flow children
  direction:   Direction,
  // where the flow children (and text lines) sit in the content box, per axis
  align:       [2]Align,
  position:    Position,
  // ABSOLUTE and roots: the point at `anchor` (0..1 of each size) of this node sits on the same
  // point of the parent's rect (a root's is the window); {1, 0} pins the top-right corners
  anchor:      [2]f32,
  // added to the placed position, flow or absolute
  offset:      [2]f32,
  // children are clipped to this node's rect
  clip:        bool,
  // children shift by -scroll
  scroll:      [2]f32,
  hidden:      bool, // hides the subtree
  // added to the parent's z; higher draws and picks on top
  z:           i32,
  // sibling flow order, ascending; node_create gives each node the next value
  order:       i32,
  // hovered, pressed and clicked with its subtree (see update_input)
  interactive: bool,
  // takes keyboard focus when pressed
  focusable:   bool,
  // content, drawn in the style's color: one line of text, or wrapped lines when `wrap`
  text:        string, // owned; change it with set_text
  font_size:   f32, // pixels
  wrap:        bool,
  // Looks, after every layout input: changing only these repaints without a layout.
  // how it is drawn, in the look of its interaction (Interaction)
  style:       StyleHandle,
  // drawn in its ACTIVE look (a selected tab, a checked box), and so is its subtree
  active:      bool,
  // content: a texture the renderer knows (render.TextureHandle) drawn over the fill; 0 is none
  image:       u32,
  // the part of the image shown, 0..1 of it; zero size shows all of it
  image_rect:  Rect,
}

// Interaction picks a node's look in its StyleSet. A node that is not interactive takes the
// interaction of the node it sits in, so a label looks hovered with its button.
Interaction :: enum u8 {
  NORMAL,
  HOVERED, // the cursor is over it (hovered)
  PRESSED, // held down (pressed)
  ACTIVE, // Node.active, unless the node itself is pressed
}

// Style is one look: a fill, a border inside the rect, and the color the content (text, image)
// is drawn in.
Style :: struct {
  fill:         [4]u8, // alpha 0 fills nothing
  border:       f32, // width in reference units
  border_color: [4]u8,
  color:        [4]u8, // text color, image tint
}

// StyleSet is a style's look per interaction.
StyleSet :: [Interaction]Style

// StyleHandle names a StyleSet in UI.styles; style_create adds one. 0 is the default style: no
// fill, content in white.
StyleHandle :: distinct u32

// Rect is an axis-aligned rectangle: top-left `pos` and `size`.
Rect :: anchor.Rect

// Line is one laid-out line of a text node: text[start:end], `width` wide, its
// top-left at `pos`, to draw at font size `size`, all in window pixels.
Line :: struct {
  start, end: int,
  pos:        [2]f32,
  width:      f32,
  size:       f32,
}

// UI is a node tree with its layout, mesh and input state. Set up with init, free with shutdown.
UI :: struct {
  // the frame nodes are laid out in, fitted to the window by update; shrink it to magnify
  // everything (a UI scale)
  reference:  [2]f32,
  // the looks nodes name by Node.style; edit them in place to restyle every node using one
  styles:     [dynamic]StyleSet,
  // shown nodes, back to front: what is drawn, in order
  draw_order: [dynamic]NodeHandle,
  using _:    UI_State,
}

// Batch is a run of the mesh drawn with one texture inside one clip, both in framebuffer pixels;
// its indices count from its first vertex.
Batch :: struct {
  first_vertex, vertex_count: u32,
  first_index, index_count:   u32,
  // a texture the renderer knows, 0 for none (white), or FONT_TEXTURE
  texture:                    u32,
  clip:                       Rect,
}

// FONT_TEXTURE stands for the font's glyph atlas in Batch.texture: the renderer's copy of it.
FONT_TEXTURE :: max(u32)

@(private)
UI_State :: struct {
  // indexed by NodeHandle.index; slots says which are live
  nodes:        []Node,
  frame:        anchor.Frame, // the reference fitted to the window
  dpi:          f32, // framebuffer pixels per window unit
  slots:        containers.Slots,
  next_order:   i32,
  rects:        [dynamic]Rect,
  clips:        [dynamic]Rect, // where the node is visible
  line_ranges:  [dynamic][2]int, // the node's lines in `lines`
  lines:        [dynamic]Line,
  hovered:      NodeHandle, // interactive-or-within node under the cursor
  pressed:      NodeHandle, // node pressed on, until every button releases
  clicked:      NodeHandle, // node released on this tick, the one pressed
  focused:      NodeHandle, // focusable node last pressed
  topo:         [dynamic]u32, // node indices, parents before children
  children:     [dynamic]u32, // CSR child lists in flow order
  child_first:  [dynamic]u32,
  child_count:  [dynamic]u32,
  fit:          [dynamic][2]f32, // content size per axis
  shown:        [dynamic]bool,
  depth_z:      [dynamic]i32,
  interaction:  [dynamic]Interaction,
  // the mesh: every shown node's fill, border and glyphs, in draw order
  vertices:     [dynamic]geometry.Vertex2D,
  indices:      [dynamic]u32,
  batches:      [dynamic]Batch,
  // what the last update saw, to tell what changed since: nodes and styles as they were, the
  // input state painted, the atlas size glyph uvs were divided by
  dirty:        bool, // a node was created or destroyed, or its text set
  last_nodes:   [dynamic]Node,
  last_styles:  [dynamic]StyleSet,
  last_hovered: NodeHandle,
  last_pressed: NodeHandle,
  atlas_size:   [2]u32,
}

// init prepares `self` to hold up to `max_nodes` nodes, laid out in `reference`, a frame of
// your choosing that layout fits to the window.
init :: proc(self: ^UI, reference := [2]f32{1024, 768}, max_nodes: u32 = 4096) {
  self.reference = reference
  containers.slots_init(&self.slots, max_nodes)
  self.nodes = make([]Node, max_nodes)
  style_create(self, {color = {255, 255, 255, 255}})
  self.dirty = true
}

// style_create adds a look per interaction, for nodes to name by Node.style: hovered defaults
// to normal, pressed to hovered, active to normal.
style_create :: proc(self: ^UI, normal: Style, hovered: Maybe(Style) = nil, pressed: Maybe(Style) = nil, active: Maybe(Style) = nil) -> StyleHandle {
  hover := hovered.? or_else normal
  append(&self.styles, StyleSet{.NORMAL = normal, .HOVERED = hover, .PRESSED = pressed.? or_else hover, .ACTIVE = active.? or_else normal})
  return StyleHandle(len(self.styles) - 1)
}

// shutdown frees everything `self` owns.
shutdown :: proc(self: ^UI) {
  c: u32
  for i in containers.slots_next(&self.slots, &c) do delete(self.nodes[i].text)
  containers.slots_destroy(&self.slots)
  delete(self.nodes)
  delete(self.rects)
  delete(self.clips)
  delete(self.line_ranges)
  delete(self.lines)
  delete(self.draw_order)
  delete(self.topo)
  delete(self.children)
  delete(self.child_first)
  delete(self.child_count)
  delete(self.fit)
  delete(self.shown)
  delete(self.depth_z)
  delete(self.interaction)
  delete(self.styles)
  delete(self.vertices)
  delete(self.indices)
  delete(self.batches)
  delete(self.last_nodes)
  delete(self.last_styles)
  self^ = {}
}

// node_create adds `n`; its text is copied and its order is the next one. Laid out by the
// next update.
node_create :: proc(self: ^UI, n: Node) -> (handle: NodeHandle, ok: bool) #optional_ok {
  index := containers.slots_alloc(&self.slots) or_return
  handle = NodeHandle(containers.slots_handle(&self.slots, index))
  slot := &self.nodes[index]
  slot^ = n
  slot.text = strings.clone(n.text)
  slot.order = self.next_order
  self.next_order += 1
  self.dirty = true
  return handle, true
}

// node_destroy removes a node and its subtree.
node_destroy :: proc(self: ^UI, handle: NodeHandle) {
  if _, ok := node(self, handle); !ok do return
  // per index: 1 in the subtree, -1 not, 2 on the walk, 0 not known yet; a walk up the parents
  // settles a chain (one met twice is a parent cycle, outside any subtree)
  in_subtree := make([]i8, self.slots.high_water, context.temp_allocator)
  in_subtree[handle.index] = 1
  chain := make([dynamic]u32, context.temp_allocator)
  c: u32
  for i in containers.slots_next(&self.slots, &c) {
    clear(&chain)
    j := i
    for in_subtree[j] == 0 {
      append(&chain, j)
      in_subtree[j] = 2
      parent := self.nodes[j].parent
      if _, live := node(self, parent); !live do break
      j = parent.index
    }
    // a walk ending on itself reached a root (or a cycle): outside the subtree
    settled := in_subtree[j] if in_subtree[j] != 2 else -1
    for k in chain do in_subtree[k] = settled
  }
  self.dirty = true
  for doomed, i in in_subtree do if doomed == 1 {
    delete(self.nodes[i].text)
    containers.slots_free(&self.slots, u32(i))
  }
}

// node returns the node behind `handle`, to edit in place; false when stale. Change text
// with set_text. The next update sees what changed: writing the same values costs nothing.
node :: #force_inline proc(self: ^UI, handle: NodeHandle) -> (^Node, bool) #optional_ok {
  if !containers.slots_valid(&self.slots, handle) do return nil, false
  return &self.nodes[handle.index], true
}

@(private)
handle_of :: #force_inline proc(self: ^UI, index: u32) -> NodeHandle {
  return NodeHandle(containers.slots_handle(&self.slots, index))
}

// set_text replaces a node's text with a copy of `text`; the same text changes nothing, so
// setting it every tick costs no update.
set_text :: proc(self: ^UI, handle: NodeHandle, text: string) {
  n, ok := node(self, handle)
  if !ok || n.text == text do return
  delete(n.text)
  n.text = strings.clone(text)
  self.dirty = true
}

// rect returns the laid-out rect of a live node in window pixels; zero before its first update
// or for a stale handle.
rect :: proc(self: ^UI, handle: NodeHandle) -> Rect {
  if !laid_out(self, handle) do return {}
  return self.rects[handle.index]
}

// clip returns the region where a node is visible; zero before its first update or for a
// stale handle.
clip :: proc(self: ^UI, handle: NodeHandle) -> Rect {
  if !laid_out(self, handle) do return {}
  return self.clips[handle.index]
}

// max_scroll returns how far a node's content scrolls (Node.scroll) before it runs out, per
// axis, as of the last update: how much the content outgrows the node, in reference units.
max_scroll :: proc(self: ^UI, handle: NodeHandle) -> [2]f32 {
  if !laid_out(self, handle) || self.frame.scale <= 0 do return {}
  i := handle.index
  overflow := self.fit[i] - self.rects[i].size / self.frame.scale
  return {max(overflow.x, 0), max(overflow.y, 0)}
}

// lines returns the laid-out text lines of a node; none for a stale handle.
lines :: proc(self: ^UI, handle: NodeHandle) -> []Line {
  if !laid_out(self, handle) do return nil
  r := self.line_ranges[handle.index]
  return self.lines[r[0]:][:r[1]]
}

// A live node the last update covered.
@(private = "file")
laid_out :: proc(self: ^UI, handle: NodeHandle) -> bool {
  return containers.slots_valid(&self.slots, handle) && int(handle.index) < len(self.rects)
}

// look returns the style a node was painted in by the last update: its style's look for its
// interaction. For drawing the nodes another way than the mesh.
look :: proc(self: ^UI, handle: NodeHandle) -> Style {
  n, ok := node(self, handle)
  if !ok || int(handle.index) >= len(self.interaction) || int(n.style) >= len(self.styles) do return {}
  return self.styles[n.style][self.interaction[handle.index]]
}

// mesh returns what the last update painted, in framebuffer pixels: draw each batch's slice of
// the vertices and indices, in order, with its texture inside its clip.
mesh :: proc(self: ^UI) -> (vertices: []geometry.Vertex2D, indices: []u32, batches: []Batch) {
  return self.vertices[:], self.indices[:], self.batches[:]
}

// to_reference maps a window point (input.State.cursor) or movement (mouse_delta) into the
// reference frame of the last update, the one root offsets are in.
to_reference :: proc(self: ^UI, p: [2]f32) -> [2]f32 {
  if self.frame.scale <= 0 do return p
  return anchor.to_reference(p, self.frame)
}

// within reports whether `handle` is `h` or one of its ancestors; false for none.
@(private)
within :: proc(self: ^UI, h, handle: NodeHandle) -> bool {
  if handle == {} do return false
  h := h
  for {
    if h == handle do return true
    n := node(self, h) or_return
    h = n.parent
  }
}

// destroy removes a node, as node_destroy does.
destroy :: proc {
  node_destroy,
}
