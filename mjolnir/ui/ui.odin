package ui

import "../anchor"
import "../containers"
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

// Position says whether a node takes part in its parent's flow.
Position :: enum u8 {
  FLOW, // placed after the previous flow sibling
  ABSOLUTE, // placed by anchor and offset in the parent's rect
}

// Pin is how a root holds to the window edges (anchor.Anchor): {.RIGHT, .BOTTOM}, or
// {.STRETCH, .STRETCH} to fill it.
Pin :: anchor.Anchor

// Node is one UI node. The application sets its layout inputs; ui writes its
// rect, clip and text lines on layout.
Node :: struct {
  // the node this one sits in; none for a root, which sits in the reference frame at `offset`
  parent:      NodeHandle,
  size:        [2]Size,
  padding:     [4]f32, // left, top, right, bottom
  gap:         f32, // between flow children
  direction:   Direction,
  // where the flow children (and text lines) sit in the content box, per axis
  align:       [2]Align,
  position:    Position,
  // ABSOLUTE (not roots, see pin): the point at `anchor` (0..1 of each size) of this node sits on
  // the same point of the parent's rect; {1, 0} pins the top-right corners
  anchor:      [2]f32,
  // roots: where the node holds when the window differs from the reference frame, one choice
  // per axis (stretch widens it). Default is top-left.
  pin:         Pin,
  // added to the placed position, flow or absolute; for a root, its top-left in the reference frame
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
  // content: one line of text, or wrapped lines when `wrap`
  text:        string, // owned; change it with set_text
  font_size:   f32, // pixels
  wrap:        bool,
}

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

// UI is a node tree with its layout output and input state. Set up with init, free with shutdown.
UI :: struct {
  // shown nodes, back to front: what to draw, in order
  draw_order:   [dynamic]NodeHandle,
  using _: UI_State,
}

@(private)
UI_State :: struct {
  // indexed by NodeHandle.index; slots says which are live
  nodes:        []Node,
  reference:    [2]f32, // the frame nodes are laid out in (init)
  frame:        anchor.Frame, // ...fitted to the window
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
}

// init prepares `self` to hold up to `max_nodes` nodes, laid out in `reference`, a frame of
// your choosing that layout fits to the window.
init :: proc(self: ^UI, reference := [2]f32{1024, 768}, max_nodes: u32 = 4096) {
  self.reference = reference
  containers.slots_init(&self.slots, max_nodes)
  self.nodes = make([]Node, max_nodes)
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
  self^ = {}
}

// node_create adds `n`; its text is copied and its order is the next one. Laid out by the
// next layout.
node_create :: proc(self: ^UI, n: Node) -> (handle: NodeHandle, ok: bool) #optional_ok {
  index := containers.slots_alloc(&self.slots) or_return
  handle = NodeHandle(containers.slots_handle(&self.slots, index))
  slot := &self.nodes[index]
  slot^ = n
  slot.text = strings.clone(n.text)
  slot.order = self.next_order
  self.next_order += 1
  return handle, true
}

// node_destroy removes a node and its subtree.
node_destroy :: proc(self: ^UI, handle: NodeHandle) {
  n, ok := lookup(self, handle)
  if !ok do return
  delete(n.text)
  containers.slots_free(&self.slots, handle.index)
  c: u32
  for i in containers.slots_next(&self.slots, &c) {
    if self.nodes[i].parent == handle do node_destroy(self, NodeHandle(containers.slots_handle(&self.slots, i)))
  }
}

// node returns the node behind `handle`, to edit in place; false when stale. Change text
// with set_text.
node :: proc(self: ^UI, handle: NodeHandle) -> (^Node, bool) #optional_ok {
  return lookup(self, handle)
}

@(private)
lookup :: #force_inline proc(self: ^UI, handle: NodeHandle) -> (^Node, bool) #optional_ok {
  if !containers.slots_valid(&self.slots, handle) do return nil, false
  return &self.nodes[handle.index], true
}

// set_text replaces a node's text with a copy of `text`.
set_text :: proc(self: ^UI, handle: NodeHandle, text: string) {
  n, ok := lookup(self, handle)
  if !ok do return
  delete(n.text)
  n.text = strings.clone(text)
}

// rect returns the laid-out rect of a live node in window pixels; zero before its first layout
// or for a stale handle.
rect :: proc(self: ^UI, handle: NodeHandle) -> Rect {
  if !laid_out(self, handle) do return {}
  return self.rects[handle.index]
}

// clip returns the region where a node is visible; zero before its first layout or for a
// stale handle.
clip :: proc(self: ^UI, handle: NodeHandle) -> Rect {
  if !laid_out(self, handle) do return {}
  return self.clips[handle.index]
}

// lines returns the laid-out text lines of a node; none for a stale handle.
lines :: proc(self: ^UI, handle: NodeHandle) -> []Line {
  if !laid_out(self, handle) do return nil
  r := self.line_ranges[handle.index]
  return self.lines[r[0]:][:r[1]]
}

// A live node the last layout covered.
@(private = "file")
laid_out :: proc(self: ^UI, handle: NodeHandle) -> bool {
  return containers.slots_valid(&self.slots, handle) && int(handle.index) < len(self.rects)
}

// within reports whether `handle` is `node` or one of its ancestors; false for none.
@(private)
within :: proc(self: ^UI, node, handle: NodeHandle) -> bool {
  if handle == {} do return false
  h := node
  for {
    if h == handle do return true
    n := lookup(self, h) or_return
    h = n.parent
  }
}

// destroy removes a node, as node_destroy does.
destroy :: proc {
  node_destroy,
}
