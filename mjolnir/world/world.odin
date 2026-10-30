package world

import "../containers"
import "../geometry"
import "core:math/linalg"
import "core:slice"

// Handle is an untyped handle, for links stored outside world (e.g. a physics body's user).
Handle :: containers.Handle

// NodeHandle identifies a node; stale after node_destroy or teardown.
NodeHandle :: distinct Handle

// RETIRE_GRACE is how many updates a despawned slot stays reserved, so index-keyed consumers see the removal.
@(private)
RETIRE_GRACE :: 3

// Node is one scene-graph entry: links, local transform and visibility.
Node :: struct {
  parent:    NodeHandle,
  transform: geometry.Transform,
  name:      string,
  visible:   bool, // node's own visibility state
}

// What update derives per node, beside the Node.
@(private)
Node_Cache :: struct {
  is_dirty:     bool, // the transform changed since the last update
  visible:      bool, // own visibility and every ancestor's
  world_matrix: matrix[4, 4]f32,
}

@(private)
NODE_CACHE_INIT :: Node_Cache {
  visible      = true,
  world_matrix = linalg.MATRIX4F32_IDENTITY,
}

// A node whose world transform or effective visibility changed, or that was
// despawned (`removed`; the other fields are then zero).
NodeChange :: struct {
  index:        u32,
  world_matrix: matrix[4, 4]f32,
  visible:      bool, // own visibility and every ancestor's
  removed:      bool,
}

// World is the scene graph. init/shutdown own its memory (application lifetime);
// teardown empties it between maps.
World :: struct {
  root:    NodeHandle,
  using _: World_State,
}

@(private)
World_State :: struct {
  // indexed by NodeHandle.index; slots says which are live
  nodes:           []Node,
  cache:           []Node_Cache,
  slots:           containers.Slots,
  // the tree derived from Node.parent, rebuilt by build_tree: CSR child lists (node i's
  // children are children[child_first[i]:child_first[i + 1]]), and every reachable node with
  // parents before children
  children:        [dynamic]NodeHandle,
  child_first:     [dynamic]u32,
  topo:            [dynamic]u32,
  // per node index: where it sits in topo and where its subtree ends there
  topo_first:      [dynamic]u32,
  topo_end:        [dynamic]u32,
  // parents changed (spawn, set_parent, teardown) since the last build_tree
  tree_stale:      bool,
  // nodes spawned, moved or shown/hidden since the last update: update walks their subtrees
  touched:         [dynamic]u32,
  // what the last `update` changed, removals first; the next update replaces it
  feed:            [dynamic]NodeChange,
  // removals made between updates; published by update
  pending_removed: [dynamic]u32,
}

// node returns a copy of the node behind `handle`; false when stale. Change it with translate,
// rotate, rotate_by, scale, set_local, set_world_pose, set_parent, set_visible and set_name.
node :: proc(self: ^World, handle: NodeHandle) -> (n: Node, ok: bool) #optional_ok {
  p := lookup(self, handle) or_return
  return p^, true
}

// set_name names a node; the name is borrowed, not copied.
set_name :: proc(self: ^World, handle: NodeHandle, name: string) {
  node := lookup(self, handle)
  if node == nil do return
  node.name = name
}

@(private)
lookup :: #force_inline proc(self: ^World, handle: NodeHandle) -> (^Node, bool) #optional_ok {
  if !containers.slots_valid(&self.slots, handle) do return nil, false
  return &self.nodes[handle.index], true
}

// edit is lookup for a change to the node's transform: update recomputes it.
@(private)
edit :: #force_inline proc(self: ^World, handle: NodeHandle) -> ^Node {
  if !containers.slots_valid(&self.slots, handle) do return nil
  c := &self.cache[handle.index]
  if !c.is_dirty do append(&self.touched, handle.index)
  c.is_dirty = true
  return &self.nodes[handle.index]
}

// children lists a node's children, valid until the tree next changes (node_create, set_parent,
// update after a node_destroy, teardown); nil when `handle` is stale.
// Children despawned since the last update may still be listed, as stale handles (node
// rejects them).
children :: proc(self: ^World, handle: NodeHandle) -> []NodeHandle {
  if lookup(self, handle) == nil do return nil
  if self.tree_stale do build_tree(self)
  return children_of(self, handle.index)
}

// find returns the first node named `name` under `root` (the whole world by default), searching
// depth first; false when none is.
find :: proc(self: ^World, name: string, root: NodeHandle = {}) -> (handle: NodeHandle, ok: bool) #optional_ok {
  start := root if root != {} else self.root
  stack := make([dynamic]NodeHandle, context.temp_allocator)
  append(&stack, start)
  for len(stack) > 0 {
    h := pop(&stack)
    n := lookup(self, h) or_continue
    if n.name == name && h != start do return h, true
    append(&stack, ..children(self, h))
  }
  return
}

@(private)
children_of :: #force_inline proc(self: ^World, i: u32) -> []NodeHandle {
  return self.children[self.child_first[i]:self.child_first[i + 1]]
}

// Rebuild the child lists and topo order from every live node's parent.
@(private)
build_tree :: proc(self: ^World) {
  n := int(self.slots.high_water)
  // counts at i + 1, summed into the start of each list, then each child placed at its parent's
  // next free entry, which leaves child_first[i + 1] at the start of list i + 1
  resize(&self.child_first, n + 1)
  slice.zero(self.child_first[:])
  for i in 0 ..< u32(n) {
    if !containers.slots_live(&self.slots, i) do continue
    p := self.nodes[i].parent
    if containers.slots_valid(&self.slots, p) do self.child_first[p.index + 1] += 1
  }
  for i in 1 ..= n do self.child_first[i] += self.child_first[i - 1]
  resize(&self.children, int(self.child_first[n]))
  next := slice.clone(self.child_first[:n], context.temp_allocator)
  for i in 0 ..< u32(n) {
    if !containers.slots_live(&self.slots, i) do continue
    p := self.nodes[i].parent
    if !containers.slots_valid(&self.slots, p) do continue
    self.children[next[p.index]] = NodeHandle(containers.slots_handle(&self.slots, i))
    next[p.index] += 1
  }
  // depth first, so a subtree is contiguous
  clear(&self.topo)
  stack := make([dynamic]u32, 0, 64, context.temp_allocator)
  append(&stack, self.root.index)
  for len(stack) > 0 {
    i := pop(&stack)
    append(&self.topo, i)
    for c in children_of(self, i) do append(&stack, c.index)
  }
  // a subtree is its root and the subtrees after it: sizes summed leaves first
  resize(&self.topo_first, n)
  resize(&self.topo_end, n)
  for i, k in self.topo do self.topo_first[i], self.topo_end[i] = u32(k), 1
  #reverse for i in self.topo do self.topo_end[self.nodes[i].parent.index] += self.topo_end[i]
  for i in self.topo do self.topo_end[i] += self.topo_first[i]
  self.tree_stale = false
}

spawn :: node_create

// node_create (or its alias spawn) creates a node at a local position, rotation and scale under
// `parent`, the world root by default; `name` is borrowed, not copied. false when `parent` is
// stale or no slot is free.
node_create :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  rotation: quaternion128 = linalg.QUATERNIONF32_IDENTITY,
  scale: [3]f32 = {1, 1, 1},
  name: string = "",
  parent: NodeHandle = {},
) -> (
  handle: NodeHandle,
  ok: bool,
) #optional_ok {
  parent := parent if parent != {} else self.root
  if !containers.slots_valid(&self.slots, parent) do return
  handle = alloc_node(self, name) or_return
  node := edit(self, handle)
  node.parent = parent
  node.transform = {position, rotation, scale}
  self.tree_stale = true
  return handle, true
}

@(private = "file")
alloc_node :: proc(self: ^World, name: string) -> (handle: NodeHandle, ok: bool) {
  index := containers.slots_alloc(&self.slots) or_return
  alloc_node_at(self, index, name)
  return NodeHandle(containers.slots_handle(&self.slots, index)), true
}

@(private = "file")
alloc_node_at :: proc(self: ^World, index: u32, name: string) {
  self.nodes[index] = {transform = geometry.TRANSFORM_IDENTITY, name = name, visible = true}
  self.cache[index] = NODE_CACHE_INIT
}

// init prepares the world for max_nodes nodes, its root among them: node indices stay below
// max_nodes, so a consumer keyed by index needs as many slots (render.MAX_SLOTS). false when it
// is too small for the root.
init :: proc(self: ^World, max_nodes: u32 = 65536) -> bool {
  containers.slots_init(&self.slots, max_nodes, RETIRE_GRACE)
  self.nodes = make([]Node, max_nodes)
  self.cache = make([]Node_Cache, max_nodes)
  // index 0 is never a node: the root's parent is the zero handle, whose cache is the identity
  self.cache[0] = NODE_CACHE_INIT
  self.root = alloc_node(self, "root") or_return
  self.tree_stale = true
  // the root outlives teardown
  containers.slots_mark(&self.slots)
  return true
}

// update advances one tick: recomputes world transforms and fills the change feed.
update :: proc(self: ^World) {
  clear(&self.feed)
  if self.tree_stale || len(self.pending_removed) > 0 do build_tree(self)
  for index in self.pending_removed do append(&self.feed, NodeChange{index = index, removed = true})
  clear(&self.pending_removed)
  for r in containers.slots_tick(&self.slots) do self.nodes[r.index], self.cache[r.index] = {}, {}
  traverse(self)
}

// changes lists what the last update changed: nodes despawned since the update
// before (`removed`, first), then nodes whose world transform or visibility changed.
// Node indices are stable for a node's lifetime: safe as external slot ids.
changes :: proc(self: ^World) -> []NodeChange {
  return self.feed[:]
}

// shutdown frees everything the world owns.
shutdown :: proc(self: ^World) {
  containers.slots_destroy(&self.slots)
  delete(self.nodes)
  delete(self.cache)
  delete(self.children)
  delete(self.child_first)
  delete(self.topo)
  delete(self.topo_first)
  delete(self.topo_end)
  delete(self.touched)
  delete(self.feed)
  delete(self.pending_removed)
}

// teardown drops every node but the root at once, back to how init left the world. Their
// indices are reused at once, so removals are not reported: a consumer keyed by node index
// forgets every index it saw, before the next map spawns (render.teardown).
teardown :: proc(self: ^World) {
  containers.slots_rewind(&self.slots)
  alloc_node_at(self, self.root.index, "root")
  self.tree_stale = true
  clear(&self.touched)
  clear(&self.pending_removed)
  clear(&self.feed)
}

// node_destroy removes a node and its descendants; changes reports them after the next update.
// false for the root or a stale handle.
node_destroy :: proc(self: ^World, handle: NodeHandle) -> bool {
  if handle == self.root || lookup(self, handle) == nil do return false
  // removals need no rebuild: the lists hold handles, and freed ones go stale
  if self.tree_stale do build_tree(self)
  despawn_subtree(self, handle)
  return true
}

// set_parent moves a node and its subtree under `parent`. With keep_world it stays where it was
// (as of the last update) by taking a new local transform; else its local transform now hangs
// from the new parent. false for the root, a stale handle, or a parent inside the subtree.
set_parent :: proc(self: ^World, handle, parent: NodeHandle, keep_world := false) -> bool {
  if handle == self.root || lookup(self, handle) == nil || lookup(self, parent) == nil do return false
  for p := parent; p != {}; p = self.nodes[p.index].parent do if p == handle do return false
  node := edit(self, handle)
  if keep_world {
    local := linalg.matrix4_inverse(self.cache[parent.index].world_matrix) * self.cache[handle.index].world_matrix
    node.transform.position, node.transform.rotation, node.transform.scale = geometry.decompose_matrix(local)
  }
  node.parent = parent
  self.tree_stale = true
  return true
}

@(private)
despawn_subtree :: proc(self: ^World, handle: NodeHandle) {
  for child in children_of(self, handle.index) {
    if containers.slots_valid(&self.slots, child) do despawn_subtree(self, child)
  }
  append(&self.pending_removed, handle.index)
  containers.slots_free(&self.slots, handle.index)
}

// Recompute world transforms of the touched nodes' subtrees, parents first, and record every
// node whose world transform or effective visibility changed. A subtree is contiguous in topo,
// so the touched nodes in topo order walk each range once.
@(private)
traverse :: proc(self: ^World) {
  defer clear(&self.touched)
  // world transform changed this update, per node index
  moved := make([]bool, self.slots.high_water, context.temp_allocator)
  // much of the tree touched: one walk beats sorting the roots
  if len(self.touched) * 32 >= len(self.topo) {
    for i in self.topo do refresh(self, i, moved)
    return
  }
  // topo position above, node index below: sorted, the roots in topo order
  roots := make([dynamic]u64, 0, len(self.touched), context.temp_allocator)
  for i in self.touched do if containers.slots_live(&self.slots, i) do append(&roots, u64(self.topo_first[i]) << 32 | u64(i))
  slice.sort(roots[:])
  walked: u32
  for key in roots {
    r := u32(key)
    if self.topo_first[r] < walked do continue
    walked = self.topo_end[r]
    for i in self.topo[self.topo_first[r]:walked] do refresh(self, i, moved)
  }
}

// One node of a walked range, whose parent is up to date.
@(private = "file")
refresh :: proc(self: ^World, i: u32, moved: []bool) {
  current_node, c := &self.nodes[i], &self.cache[i]
  // the root's parent is index 0: the identity, visible and never moved
  p := current_node.parent.index
  parent := &self.cache[p]
  parent_moved := moved[p]
  visible := parent.visible && current_node.visible
  visibility_changed := c.visible != visible
  c.visible = visible
  is_dirty := c.is_dirty
  c.is_dirty = false
  if parent_moved || is_dirty {
    t := current_node.transform
    local := linalg.matrix4_from_trs(t.position, t.rotation, t.scale)
    c.world_matrix = parent.world_matrix * local
  }
  moved[i] = parent_moved || is_dirty
  if visibility_changed || moved[i] {
    append(&self.feed, NodeChange{index = i, world_matrix = c.world_matrix, visible = visible})
  }
}

// set_world_pose places a node at a world (position, rotation) whatever its parent, as the
// parent was at the last update; scale is kept. Exact only under uniformly scaled parents.
set_world_pose :: proc(
  self: ^World,
  handle: NodeHandle,
  position: [3]f32,
  rotation: quaternion128,
) {
  node := edit(self, handle)
  if node == nil do return
  parent_world := self.cache[node.parent.index].world_matrix
  inv := linalg.matrix4_inverse(parent_world)
  node.transform.position = (inv * [4]f32{position.x, position.y, position.z, 1}).xyz
  _, parent_rotation, _ := geometry.decompose_matrix(parent_world)
  node.transform.rotation = linalg.normalize(linalg.quaternion_inverse(parent_rotation) * rotation)
}

// set_world_poses is set_world_pose for every pose of `poses`, a struct with a `user` field
// holding the node's handle and `position` and `rotation` fields.
set_world_poses :: proc(self: ^World, poses: []$T) {
  for &p in poses do set_world_pose(self, NodeHandle(p.user), p.position, p.rotation)
}

// world_matrix returns a node's world matrix as of the last update; identity when stale.
world_matrix :: proc(self: ^World, handle: NodeHandle) -> matrix[4, 4]f32 {
  if lookup(self, handle) == nil do return linalg.MATRIX4F32_IDENTITY
  return self.cache[handle.index].world_matrix
}

// set_visible shows or hides a node and its subtree.
set_visible :: proc(self: ^World, handle: NodeHandle, visible: bool) {
  node := lookup(self, handle)
  if node == nil || node.visible == visible do return
  node.visible = visible
  // a node listed twice is walked once (traverse)
  append(&self.touched, handle.index)
}

// destroy removes a node, as node_destroy does.
destroy :: proc {
  node_destroy,
}
