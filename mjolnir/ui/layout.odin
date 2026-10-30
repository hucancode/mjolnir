package ui

import "../anchor"
import "../containers"
import "../font"
import "core:mem"
import "core:slice"
import "core:strings"

@(private = "file")
ALIGN_FACTOR := [Align]f32 {
  .START  = 0,
  .CENTER = 0.5,
  .END    = 1,
}

// update brings the layout and the mesh up to date for a window of `window` units
// (render.window_size) at `dpi` framebuffer pixels per unit, with text measured and drawn in f
// (nil for a tree without text; pass the same font every time). Every node is laid out in the
// reference frame scaled up or down until one axis matches the window, so the window is the
// reference widened on the other axis; roots sit in it as ABSOLUTE nodes do in their parent.
// Rects, clips and lines come out in window pixels, the mesh in framebuffer pixels.
// Only what changed since the last update is redone; it returns what it redid.
update :: proc(self: ^UI, window: [2]f32, f: ^font.Font, dpi: f32 = 1) -> (laid_out, painted: bool) {
  n := int(self.slots.high_water)
  frame := anchor.frame(self.reference, window)
  atlas := font.atlas_size(f) if f != nil else {}
  laid_out = self.dirty || frame != self.frame || dpi != self.dpi || n != len(self.last_nodes)
  painted = laid_out || atlas != self.atlas_size || self.hovered != self.last_hovered || self.pressed != self.last_pressed
  painted ||= len(self.styles) != len(self.last_styles) || mem.compare(slice.to_bytes(self.styles[:]), slice.to_bytes(self.last_styles[:])) != 0
  if !laid_out && mem.compare(slice.to_bytes(self.nodes[:n]), slice.to_bytes(self.last_nodes[:])) != 0 {
    painted = true
    // the layout inputs are the bytes before the looks
    for &last, i in self.last_nodes {
      laid_out ||= mem.compare_ptrs(&self.nodes[i], &last, int(offset_of(Node, style))) != 0
    }
  }
  if laid_out do layout(self, frame, f)
  if !painted do return
  paint(self, f, dpi)
  self.dirty = false
  self.dpi = dpi
  self.atlas_size = font.atlas_size(f) if f != nil else {}
  self.last_hovered, self.last_pressed = self.hovered, self.pressed
  resize(&self.last_nodes, n)
  copy(self.last_nodes[:], self.nodes[:n])
  resize(&self.last_styles, len(self.styles))
  copy(self.last_styles[:], self.styles[:])
  return
}

// A fixed sequence of passes over the nodes in tree order: widths resolve before text wraps,
// heights after.
@(private = "file")
layout :: proc(self: ^UI, frame: anchor.Frame, f: ^font.Font) {
  self.frame = frame
  n := int(self.slots.high_water)
  resize(&self.rects, n)
  resize(&self.clips, n)
  resize(&self.line_ranges, n)
  resize(&self.fit, n)
  resize(&self.shown, n)
  resize(&self.depth_z, n)
  resize(&self.child_first, n)
  resize(&self.child_count, n)
  build_tree(self)
  fit_axis(self, f, 0)
  size_axis(self, 0)
  wrap_text(self, f)
  fit_axis(self, f, 1)
  size_axis(self, 1)
  place(self, f)
  to_window(self)
}

@(private)
children_of :: #force_inline proc(self: ^UI, i: u32) -> []u32 {
  return self.children[self.child_first[i]:][:self.child_count[i]]
}

// Index of a node's parent, or -1 for a root (no parent, or a stale one).
@(private)
parent_of :: proc(self: ^UI, i: u32) -> int {
  p := self.nodes[i].parent
  if !containers.slots_valid(&self.slots, p) do return -1
  return int(p.index)
}

// Sort node indices by `key`, then by index: one u64 sort.
@(private = "file")
sort_indices :: proc(indices: []u32, key: proc(self: ^UI, i: u32) -> i32, self: ^UI) {
  keys := make([]u64, len(indices), context.temp_allocator)
  // flipping the sign bit orders signed keys as unsigned
  for i, k in indices do keys[k] = u64(u32(key(self, i)) ~ 0x8000_0000) << 32 | u64(i)
  slice.sort(keys)
  for key, k in keys do indices[k] = u32(key)
}

// CSR child lists in flow order, and `topo`: every live node, parents
// before children, roots first.
@(private = "file")
build_tree :: proc(self: ^UI) {
  clear(&self.topo)
  slice.zero(self.child_count[:])
  c: u32
  for i in containers.slots_next(&self.slots, &c) {
    p := parent_of(self, i)
    if p < 0 do append(&self.topo, i)
    else do self.child_count[p] += 1
  }
  total: u32
  for count, i in self.child_count {
    self.child_first[i] = total
    total += count
  }
  resize(&self.children, int(total))
  fill := make([]u32, len(self.child_count), context.temp_allocator)
  c = 0
  for i in containers.slots_next(&self.slots, &c) {
    p := parent_of(self, i)
    if p < 0 do continue
    self.children[self.child_first[p] + fill[p]] = i
    fill[p] += 1
  }
  order :: proc(self: ^UI, i: u32) -> i32 {return self.nodes[i].order}
  sort_indices(self.topo[:], order, self)
  for count, i in self.child_count do if count > 1 do sort_indices(children_of(self, u32(i)), order, self)
  for k := 0; k < len(self.topo); k += 1 do append(&self.topo, ..children_of(self, self.topo[k]))
}

// Padding along `axis`, both sides.
@(private = "file")
padding :: proc(nd: ^Node, axis: int) -> f32 {
  return nd.padding[axis] + nd.padding[axis + 2]
}

@(private = "file")
flow_axis :: proc(nd: ^Node) -> int {
  return 0 if nd.direction == .ROW else 1
}

// Whether a child takes part in its parent's flow.
@(private = "file")
flows :: proc(nd: ^Node) -> bool {
  return nd.position == .FLOW && !nd.hidden
}

// Content size along `axis`, children before parents: flow children summed
// along the flow axis (plus gaps) or the largest across it, text, padding.
// A FIXED child counts its size, a PERCENT one nothing, a clipping one its least.
@(private = "file")
fit_axis :: proc(self: ^UI, f: ^font.Font, axis: int) {
  #reverse for i in self.topo {
    nd := &self.nodes[i]
    main := flow_axis(nd) == axis
    content: f32
    count := 0
    for c in children_of(self, i) {
      cn := &self.nodes[c]
      if !flows(cn) do continue
      s := least(self, c, axis)
      #partial switch cn.size[axis].kind {
      case .FIXED:
        s = cn.size[axis].value
      case .PERCENT:
        s = 0
      }
      content = content + s if main else max(content, s)
      count += 1
    }
    if main && count > 1 do content += nd.gap * f32(count - 1)
    if len(nd.text) > 0 {
      if axis == 0 {
        // wrapped text breaks down to its longest word
        text := nd.text
        if nd.wrap {
          for word in strings.fields_iterator(&text) do content = max(content, font.measure(f, word, nd.font_size))
        } else {
          for line in strings.split_lines_iterator(&text) do content = max(content, font.measure(f, line, nd.font_size))
        }
      } else {
        content = max(content, f32(self.line_ranges[i][1]) * font.line_height(f, nd.font_size))
      }
    }
    self.fit[i][axis] = content + padding(nd, axis)
  }
}

// The least a node shrinks to along `axis` when it does not fit its content: a clipping node
// scrolls what does not fit, so only its padding counts.
@(private = "file")
least :: proc(self: ^UI, i: u32, axis: int) -> f32 {
  nd := &self.nodes[i]
  if nd.clip && nd.size[axis].kind != .FIT do return padding(nd, axis)
  return self.fit[i][axis]
}

// Size along `axis` against a parent content box of `space`; GROW fills it.
@(private = "file")
resolve :: proc(self: ^UI, i: u32, axis: int, space: f32) -> f32 {
  s := self.nodes[i].size[axis]
  switch s.kind {
  case .FIT:
    return self.fit[i][axis]
  case .FIXED:
    return s.value
  case .PERCENT:
    return s.value * space
  case .GROW:
    return max(space, least(self, i, axis))
  }
  return 0
}

// Sizes along `axis`, parents before children; roots against the window. Along a parent's flow axis
// its GROW children share what the others leave, by weight; across it, and
// for absolute children, GROW fills the content box.
@(private = "file")
size_axis :: proc(self: ^UI, axis: int) {
  for i in self.topo {
    nd := &self.nodes[i]
    if parent_of(self, i) < 0 do self.rects[i].size[axis] = resolve(self, i, axis, self.frame.size[axis])
    space := self.rects[i].size[axis] - padding(nd, axis)
    kids := children_of(self, i)
    for c in kids do self.rects[c].size[axis] = resolve(self, c, axis, space)
    if flow_axis(nd) != axis do continue
    free := space
    weights: f32
    count := 0
    for c in kids {
      cn := &self.nodes[c]
      if !flows(cn) do continue
      count += 1
      if cn.size[axis].kind == .GROW {
        self.rects[c].size[axis] = least(self, c, axis)
        weights += cn.size[axis].value if cn.size[axis].value > 0 else 1
      }
      free -= self.rects[c].size[axis]
    }
    free -= nd.gap * f32(max(count - 1, 0))
    if weights == 0 || free <= 0 do continue
    for c in kids {
      cn := &self.nodes[c]
      if !flows(cn) || cn.size[axis].kind != .GROW do continue
      w := cn.size[axis].value if cn.size[axis].value > 0 else 1
      self.rects[c].size[axis] += free * w / weights
    }
  }
}

// Break every text node into lines: at newlines, and when `wrap`, before
// the word that would cross the content width.
@(private = "file")
wrap_text :: proc(self: ^UI, f: ^font.Font) {
  clear(&self.lines)
  for i in self.topo {
    nd := &self.nodes[i]
    first := len(self.lines)
    width := self.rects[i].size.x - padding(nd, 0)
    start := 0
    for start <= len(nd.text) && len(nd.text) > 0 {
      end := strings.index_byte(nd.text[start:], '\n')
      end = len(nd.text) if end < 0 else start + end
      line_start := start
      if nd.wrap {
        // the last space before the line overflows ends it
        for space := line_start; space < end; {
          next := strings.index_byte(nd.text[space + 1:end], ' ')
          next = end if next < 0 else space + 1 + next
          if next > line_start && space > line_start && font.measure(f, nd.text[line_start:next], nd.font_size) > width {
            append(&self.lines, Line{start = line_start, end = space})
            line_start = space + 1
          }
          space = next
        }
      }
      append(&self.lines, Line{start = line_start, end = end})
      start = end + 1
    }
    self.line_ranges[i] = {first, len(self.lines) - first}
    for &line in self.lines[first:] do line.width = font.measure(f, nd.text[line.start:line.end], nd.font_size)
  }
}

// Positions, text lines, clips, visibility and depth, parents before
// children; then the shown nodes into draw_order by depth, tree order
// breaking ties.
@(private = "file")
place :: proc(self: ^UI, f: ^font.Font) {
  for i in self.topo {
    nd := &self.nodes[i]
    r := &self.rects[i]
    if parent_of(self, i) < 0 {
      r.pos = (self.frame.size - r.size) * nd.anchor + nd.offset
      self.clips[i] = {{}, self.frame.size}
      self.shown[i] = !nd.hidden
      self.depth_z[i] = nd.z
    }
    content_pos := r.pos + {nd.padding[0], nd.padding[1]}
    content_size := r.size - {padding(nd, 0), padding(nd, 1)}
    // text lines, aligned in the content box
    if lr := self.line_ranges[i]; lr[1] > 0 {
      lh := font.line_height(f, nd.font_size)
      y := content_pos.y + (content_size.y - lh * f32(lr[1])) * ALIGN_FACTOR[nd.align[1]]
      for &line, k in self.lines[lr[0]:][:lr[1]] {
        line.pos = {content_pos.x + (content_size.x - line.width) * ALIGN_FACTOR[nd.align[0]], y + f32(k) * lh}
      }
    }
    child_clip := intersect(self.clips[i], r^) if nd.clip else self.clips[i]
    m := flow_axis(nd)
    total: f32
    count := 0
    kids := children_of(self, i)
    for c in kids do if flows(&self.nodes[c]) {
      total += self.rects[c].size[m]
      count += 1
    }
    total += nd.gap * f32(max(count - 1, 0))
    cursor := (content_size[m] - total) * ALIGN_FACTOR[nd.align[m]]
    origin := content_pos - nd.scroll
    for c in kids {
      cn := &self.nodes[c]
      cr := &self.rects[c]
      self.clips[c] = child_clip
      self.shown[c] = self.shown[i] && !cn.hidden
      self.depth_z[c] = self.depth_z[i] + cn.z
      if cn.position == .ABSOLUTE {
        cr.pos = r.pos + (r.size - cr.size) * cn.anchor + cn.offset
        continue
      }
      cr.pos = origin
      if !flows(cn) do continue
      cross := 1 - m
      cr.pos[m] += cursor
      cr.pos[cross] += (content_size[cross] - cr.size[cross]) * ALIGN_FACTOR[nd.align[cross]]
      cr.pos += cn.offset
      cursor += cr.size[m] + nd.gap
    }
  }
  clear(&self.draw_order)
  shown := make([dynamic]u32, 0, len(self.topo), context.temp_allocator)
  for i in self.topo do if self.shown[i] do append(&shown, i)
  // stable by depth: keys carry the tree-order position
  keys := make([]u64, len(shown), context.temp_allocator)
  for i, k in shown do keys[k] = u64(u32(self.depth_z[i]) ~ 0x8000_0000) << 32 | u64(k)
  slice.sort(keys)
  for key in keys {
    i := shown[u32(key)]
    append(&self.draw_order, handle_of(self, i))
  }
}

// Rects, clips and lines from reference units to window pixels.
@(private = "file")
to_window :: proc(self: ^UI) {
  s := self.frame.scale
  for i in self.topo {
    self.rects[i] = anchor.to_window(self.rects[i], self.frame)
    self.clips[i] = anchor.to_window(self.clips[i], self.frame)
    size := self.nodes[i].font_size * s
    for &line in self.lines[self.line_ranges[i][0]:][:self.line_ranges[i][1]] {
      line.pos *= s
      line.width *= s
      line.size = size
    }
  }
}

@(private = "file")
intersect :: proc(a, b: Rect) -> Rect {
  lo := [2]f32{max(a.pos.x, b.pos.x), max(a.pos.y, b.pos.y)}
  hi := [2]f32{min(a.pos.x + a.size.x, b.pos.x + b.size.x), min(a.pos.y + a.size.y, b.pos.y + b.size.y)}
  return {lo, {max(hi.x - lo.x, 0), max(hi.y - lo.y, 0)}}
}
