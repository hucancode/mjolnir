// Retained 2D layout: a tree of nodes in one flat pool, laid out by flex
// rows and columns, anchors, text wrapping, clipping and scrolling, plus hit
// testing. ui draws nothing: the application turns rects and text lines
// into whatever its renderer draws (render's 2D overlay commands, say).
package ui

import cont "../containers"
import "core:strings"

NodeHandle :: distinct cont.Handle

Direction :: enum u8 {
  ROW, // children flow along x
  COLUMN, // children flow along y
}

SizeKind :: enum u8 {
  FIT, // wraps the content: flow children, text, padding
  FIXED, // `value` pixels
  GROW, // shares the parent's free space by weight `value` (0 counts as 1), at least FIT
  PERCENT, // `value` (0..1) of the parent's content box
}

Size :: struct {
  kind:  SizeKind,
  value: f32,
}

Align :: enum u8 {
  START,
  CENTER,
  END,
}

Position :: enum u8 {
  FLOW, // placed after the previous flow sibling
  ABSOLUTE, // placed by anchor and offset in the parent's rect
}

// One node. Its layout inputs are what the application sets; ui writes its
// rect, clip and text lines on layout.
Node :: struct {
  // the node this one sits in; none for a root, which sits in the viewport
  parent:      NodeHandle,
  size:        [2]Size,
  padding:     [4]f32, // left, top, right, bottom
  gap:         f32, // between flow children
  direction:   Direction,
  // where the flow children (and text lines) sit in the content box, per axis
  align:       [2]Align,
  position:    Position,
  // ABSOLUTE: the point at `anchor` (0..1 of each size) of this node sits on
  // the same point of the parent's rect; {1, 0} pins the top-right corners
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
  // sibling flow order, ascending; create gives each node the next value
  order:       i32,
  // hovered, pressed and clicked with its subtree (see update_input)
  interactive: bool,
  // takes keyboard focus when pressed
  focusable:   bool,
  // content: one line of text, or wrapped lines when `wrap`
  text:        string, // owned; change it with set_text
  font_size:   f32,
  wrap:        bool,
}

Rect :: struct {
  pos, size: [2]f32,
}

// One laid-out line of a text node: text[start:end], `width` wide, its
// top-left at `pos`.
Line :: struct {
  start, end: int,
  pos:        [2]f32,
  width:      f32,
}

UI :: struct {
  nodes:        cont.Pool(Node),
  next_order:   i32,
  // ---------- layout output, by node index ----------
  rects:        [dynamic]Rect,
  clips:        [dynamic]Rect, // where the node is visible
  line_ranges:  [dynamic][2]int, // the node's lines in `lines`
  lines:        [dynamic]Line,
  // shown nodes, back to front: what to draw, in order
  draw_order:   [dynamic]NodeHandle,
  // ---------- input state (update_input) ----------
  hovered:      NodeHandle, // interactive-or-within node under the cursor
  pressed:      NodeHandle, // node pressed on, until every button releases
  clicked:      NodeHandle, // node released on this tick, the one pressed
  focused:      NodeHandle, // focusable node last pressed
  // ---------- layout scratch ----------
  topo:         [dynamic]u32, // node indices, parents before children
  children:     [dynamic]u32, // CSR child lists in flow order
  child_first:  [dynamic]u32,
  child_count:  [dynamic]u32,
  fit:          [dynamic][2]f32, // content size per axis
  shown:        [dynamic]bool,
  depth_z:      [dynamic]i32,
}

init :: proc(self: ^UI, max_nodes: u32 = 4096) {
  cont.init(&self.nodes, max_nodes)
}

destroy :: proc(self: ^UI) {
  cont.destroy(&self.nodes, proc(n: ^Node) {delete(n.text)})
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

// Add `n`; its text is copied and its order is the next one. Laid out by the
// next layout.
create :: proc(self: ^UI, n: Node) -> (handle: NodeHandle, ok: bool) #optional_ok {
  slot: ^Node
  handle, slot = cont.alloc(&self.nodes, NodeHandle) or_return
  slot^ = n
  slot.text = strings.clone(n.text)
  slot.order = self.next_order
  self.next_order += 1
  return handle, true
}

// Remove a node and its subtree.
destroy_node :: proc(self: ^UI, handle: NodeHandle) {
  n, ok := cont.get(self.nodes, handle)
  if !ok do return
  delete(n.text)
  cont.free(&self.nodes, handle)
  it := cont.iterator(&self.nodes)
  for child, h in cont.next(&it, NodeHandle) do if child.parent == handle do destroy_node(self, h)
}

// The node behind `handle`, to edit in place; nil when stale. Change text
// with set_text.
node :: proc(self: ^UI, handle: NodeHandle) -> ^Node {
  return cont.get(self.nodes, handle)
}

set_text :: proc(self: ^UI, handle: NodeHandle, text: string) {
  n, ok := cont.get(self.nodes, handle)
  if !ok do return
  delete(n.text)
  n.text = strings.clone(text)
}

// Layout output of a live node; zero before its first layout.
rect :: proc(self: ^UI, handle: NodeHandle) -> Rect {
  return self.rects[handle.index] if int(handle.index) < len(self.rects) else {}
}

clip :: proc(self: ^UI, handle: NodeHandle) -> Rect {
  return self.clips[handle.index] if int(handle.index) < len(self.clips) else {}
}

lines :: proc(self: ^UI, handle: NodeHandle) -> []Line {
  if int(handle.index) >= len(self.line_ranges) do return nil
  r := self.line_ranges[handle.index]
  return self.lines[r[0]:][:r[1]]
}

// Whether `handle` is `node` or one of its ancestors; false for none.
within :: proc(self: ^UI, node, handle: NodeHandle) -> bool {
  if handle == {} do return false
  h := node
  for {
    if h == handle do return true
    n := cont.get(self.nodes, h) or_return
    h = n.parent
  }
}
