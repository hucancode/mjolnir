package ui

import "../anchor"
import "../containers"
import "../font"
import "core:slice"
import "core:strings"

@(private = "file")
ALIGN_FACTOR := [Align]f32 {
  .START  = 0,
  .CENTER = 0.5,
  .END    = 1,
}

// layout lays every node out in the reference frame (init), then fits it to `window`: scaled
// up or down until one axis matches, the other axis's leftover space going to the roots by
// their pin. Rects, clips and lines come out in window pixels. Text is measured in f, which may
// be nil for a tree without text.
// A fixed sequence of passes over the nodes in tree order: widths resolve before text wraps,
// heights after.
layout :: proc(self: ^UI, window: [2]f32, f: ^font.Font) {
  self.frame = anchor.frame(self.reference, window)
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

// A root's rect fitted to the window frame by its pin.
@(private = "file")
fit_root :: proc(self: ^UI, i: u32) -> Rect {
  nd := item(self, i)
  return anchor.fit({nd.offset, self.rects[i].size}, nd.pin, self.reference, self.frame.size)
}

@(private = "file")
item :: #force_inline proc(self: ^UI, i: u32) -> ^Node {
  return &self.nodes[i]
}

@(private = "file")
children_of :: #force_inline proc(self: ^UI, i: u32) -> []u32 {
  return self.children[self.child_first[i]:][:self.child_count[i]]
}

// Index of a node's parent, or -1 for a root (no parent, or a stale one).
@(private = "file")
parent_of :: proc(self: ^UI, i: u32) -> int {
  p := item(self, i).parent
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
  order :: proc(self: ^UI, i: u32) -> i32 {return item(self, i).order}
  sort_indices(self.topo[:], order, self)
  for i in 0 ..< len(self.child_count) do sort_indices(children_of(self, u32(i)), order, self)
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
// A FIXED child counts its size, a PERCENT one nothing.
@(private = "file")
fit_axis :: proc(self: ^UI, f: ^font.Font, axis: int) {
  #reverse for i in self.topo {
    nd := item(self, i)
    main := flow_axis(nd) == axis
    content: f32
    count := 0
    for c in children_of(self, i) {
      cn := item(self, c)
      if !flows(cn) do continue
      s := self.fit[c][axis]
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
        text := nd.text
        for line in strings.split_lines_iterator(&text) do content = max(content, font.measure(f, line, nd.font_size))
      } else {
        content = max(content, f32(self.line_ranges[i][1]) * font.line_height(f, nd.font_size))
      }
    }
    self.fit[i][axis] = content + padding(nd, axis)
  }
}

// Size along `axis` against a parent content box of `space`; GROW fills it.
@(private = "file")
resolve :: proc(self: ^UI, i: u32, axis: int, space: f32) -> f32 {
  s := item(self, i).size[axis]
  switch s.kind {
  case .FIT:
    return self.fit[i][axis]
  case .FIXED:
    return s.value
  case .PERCENT:
    return s.value * space
  case .GROW:
    return max(space, self.fit[i][axis])
  }
  return 0
}

// Sizes along `axis`, parents before children; roots stretch by their pin. Along a parent's flow axis
// its GROW children share what the others leave, by weight; across it, and
// for absolute children, GROW fills the content box.
@(private = "file")
size_axis :: proc(self: ^UI, axis: int) {
  for i in self.topo {
    nd := item(self, i)
    if parent_of(self, i) < 0 {
      self.rects[i].size[axis] = resolve(self, i, axis, self.reference[axis])
      self.rects[i].size[axis] = fit_root(self, i).size[axis]
    }
    space := self.rects[i].size[axis] - padding(nd, axis)
    kids := children_of(self, i)
    for c in kids do self.rects[c].size[axis] = resolve(self, c, axis, space)
    if flow_axis(nd) != axis do continue
    free := space
    weights: f32
    count := 0
    for c in kids {
      cn := item(self, c)
      if !flows(cn) do continue
      count += 1
      if cn.size[axis].kind == .GROW {
        self.rects[c].size[axis] = self.fit[c][axis]
        weights += cn.size[axis].value if cn.size[axis].value > 0 else 1
      }
      free -= self.rects[c].size[axis]
    }
    free -= nd.gap * f32(max(count - 1, 0))
    if weights == 0 || free <= 0 do continue
    for c in kids {
      cn := item(self, c)
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
    nd := item(self, i)
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
    nd := item(self, i)
    r := &self.rects[i]
    if parent_of(self, i) < 0 {
      r.pos = fit_root(self, i).pos
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
    for c in kids do if flows(item(self, c)) {
      total += self.rects[c].size[m]
      count += 1
    }
    total += nd.gap * f32(max(count - 1, 0))
    cursor := (content_size[m] - total) * ALIGN_FACTOR[nd.align[m]]
    origin := content_pos - nd.scroll
    for c in kids {
      cn := item(self, c)
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
    append(&self.draw_order, NodeHandle(containers.slots_handle(&self.slots, i)))
  }
}

// Rects, clips and lines from reference units to window pixels.
@(private = "file")
to_window :: proc(self: ^UI) {
  s := self.frame.scale
  for i in self.topo {
    self.rects[i] = anchor.to_window(self.rects[i], self.frame)
    self.clips[i] = anchor.to_window(self.clips[i], self.frame)
    size := item(self, i).font_size * s
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
