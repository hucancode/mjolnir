package animation

import "../geometry"
import "core:math/linalg"
import "core:slice"
import "core:strings"

// Skeleton is the bone hierarchy definition, shared by every instance animated with it.
// Immutable after skeleton_init. One flat array per attribute, indexed by
// bone; bone indices match the skin's joint order.
Skeleton :: struct {
  names:        []string,
  parents:      []i32, // -1 = root
  order:        []u32, // every parent appears before its children
  inverse_bind: []matrix[4, 4]f32,
  bind:         []matrix[4, 4]f32, // skeleton-space rest pose
  rest:         []geometry.Transform, // local rest pose
  lengths:      []f32, // rest distance to parent (0 for roots)
  depths:       []u32, // root = 0
}

// skeleton_init builds a skeleton from parent indices and inverse bind matrices (copied). `rest`
// is each bone's local transform where no clip moves it; nil takes the bind pose. Fails if the
// parent links contain a cycle or out-of-range index.
skeleton_init :: proc(
  self: ^Skeleton,
  parents: []i32,
  inverse_bind: []matrix[4, 4]f32,
  names: []string = nil,
  rest: []geometry.Transform = nil,
) -> bool {
  n := len(parents)
  if len(inverse_bind) != n do return false
  for p in parents do if p < -1 || int(p) >= n do return false
  self.parents = slice.clone(parents)
  self.inverse_bind = slice.clone(inverse_bind)
  self.names = make([]string, n)
  for name, i in names do if i < n do self.names[i] = strings.clone(name)
  self.order = make([]u32, n)
  self.depths = make([]u32, n)
  // Breadth-first from roots gives parent-before-child order and depths.
  visited := 0
  for i in 0 ..< n do if parents[i] == -1 {
    self.order[visited] = u32(i)
    visited += 1
  }
  for head := 0; head < visited; head += 1 {
    cur := self.order[head]
    for i in 0 ..< n do if parents[i] == i32(cur) {
      self.order[visited] = u32(i)
      self.depths[i] = self.depths[cur] + 1
      visited += 1
    }
  }
  if visited != n {
    skeleton_destroy(self)
    return false
  }
  self.bind = make([]matrix[4, 4]f32, n)
  self.rest = make([]geometry.Transform, n)
  self.lengths = make([]f32, n)
  for i in 0 ..< n do self.bind[i] = linalg.matrix4_inverse(inverse_bind[i])
  for i in self.order {
    p := parents[i]
    local := self.bind[i]
    if p >= 0 {
      local = inverse_bind[p] * self.bind[i]
      self.lengths[i] = linalg.distance(self.bind[p][3].xyz, self.bind[i][3].xyz)
    }
    r := &self.rest[i]
    r.position, r.rotation, r.scale = geometry.decompose_matrix(local)
    if len(rest) == n do r^ = rest[i]
  }
  return true
}

// skeleton_destroy frees the skeleton's arrays.
skeleton_destroy :: proc(self: ^Skeleton) {
  for name in self.names do delete(name)
  delete(self.names)
  delete(self.parents)
  delete(self.order)
  delete(self.inverse_bind)
  delete(self.bind)
  delete(self.rest)
  delete(self.lengths)
  delete(self.depths)
  self^ = {}
}

// bone_count returns the number of bones in the skeleton.
bone_count :: #force_inline proc "contextless" (self: ^Skeleton) -> int {
  return len(self.parents)
}

// bone_find returns the index of the bone named name.
bone_find :: proc(self: ^Skeleton, name: string) -> (index: u32, ok: bool) #optional_ok {
  for n, i in self.names do if n == name do return u32(i), true
  return 0, false
}

// bones_find returns the indices of the named bones. Fails if any name is missing.
bones_find :: proc(
  self: ^Skeleton,
  names: []string,
  allocator := context.allocator,
) -> (
  indices: []u32,
  ok: bool,
) #optional_ok {
  indices = make([]u32, len(names), allocator)
  for name, i in names {
    idx, found := bone_find(self, name)
    if !found {
      delete(indices, allocator)
      return nil, false
    }
    indices[i] = idx
  }
  return indices, true
}

// bone_chain returns the chain from `root_name` down to `tip_name` (root first). Fails if tip does
// not descend from root.
bone_chain :: proc(
  self: ^Skeleton,
  root_name, tip_name: string,
  allocator := context.allocator,
) -> (
  indices: []u32,
  ok: bool,
) #optional_ok {
  root := bone_find(self, root_name) or_return
  tip := bone_find(self, tip_name) or_return
  count := 1
  for cur := i32(tip); cur != i32(root); cur = self.parents[cur] {
    if self.parents[cur] < 0 do return nil, false
    count += 1
  }
  indices = make([]u32, count, allocator)
  cur := i32(tip)
  for i := count - 1; i >= 0; i -= 1 {
    indices[i] = u32(cur)
    cur = self.parents[cur]
  }
  return indices, true
}

// bone_chain_down returns a chain of up to `length` bones starting at `root_name`, following each bone's
// first child. Fails when fewer than 2 bones are found.
bone_chain_down :: proc(
  self: ^Skeleton,
  root_name: string,
  length: u32,
  allocator := context.allocator,
) -> (
  indices: []u32,
  ok: bool,
) #optional_ok {
  root := bone_find(self, root_name) or_return
  chain := make([dynamic]u32, 0, length, context.temp_allocator)
  append(&chain, root)
  outer: for len(chain) < int(length) {
    cur := i32(chain[len(chain) - 1])
    for p, i in self.parents do if p == cur {
      append(&chain, u32(i))
      continue outer
    }
    break
  }
  if len(chain) < 2 do return nil, false
  return slice.clone(chain[:], allocator), true
}

// bone_subtree returns a bone and all its descendants, parents first.
bone_subtree :: proc(
  self: ^Skeleton,
  root_name: string,
  allocator := context.allocator,
) -> (
  bones: []u32,
  ok: bool,
) #optional_ok {
  root := bone_find(self, root_name) or_return
  inside := make([]bool, bone_count(self), context.temp_allocator)
  inside[root] = true
  out := make([dynamic]u32, 0, bone_count(self), allocator)
  for i in self.order {
    if p := self.parents[i]; i != root && (p < 0 || !inside[p]) do continue
    inside[i] = true
    append(&out, i)
  }
  return out[:], true
}

// rest_position returns the rest-pose position of a bone in skeleton space.
rest_position :: proc(self: ^Skeleton, name: string) -> (pos: [3]f32, ok: bool) #optional_ok {
  idx := bone_find(self, name) or_return
  return self.bind[idx][3].xyz, true
}

// rest_offset returns the rest-pose offset (tip - root) in skeleton space.
rest_offset :: proc(self: ^Skeleton, root_name, tip_name: string) -> (offset: [3]f32, ok: bool) #optional_ok {
  root := rest_position(self, root_name) or_return
  tip := rest_position(self, tip_name) or_return
  return tip - root, true
}
