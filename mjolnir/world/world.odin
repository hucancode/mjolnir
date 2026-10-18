package world

import "../containers"
import "../geometry"
import "core:math/linalg"
import "core:slice"

// Node is one scene-graph entry: links, local transform, visibility and user tags.
Node :: struct {
  parent:         NodeHandle,
  transform:      Transform,
  name:           string,
  visible:        bool, // node's own visibility state
  tags:           u32, // user-defined bit flags
}

// What update derives per node, beside the Node.
@(private)
Node_Cache :: struct {
  is_dirty:       bool, // the transform or visibility changed since the last update
  parent_visible: bool, // visibility inherited from parent chain
  local_matrix:   matrix[4, 4]f32,
  world_matrix:   matrix[4, 4]f32,
}

@(private)
NODE_CACHE_INIT :: Node_Cache {
  parent_visible = true,
  local_matrix   = linalg.MATRIX4F32_IDENTITY,
  world_matrix   = linalg.MATRIX4F32_IDENTITY,
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
  // the tree derived from Node.parent, rebuilt by build_tree: CSR child lists indexed
  // by node index, and every reachable node with parents before children
  children:        [dynamic]NodeHandle,
  child_first:     [dynamic]u32,
  child_count:     [dynamic]u32,
  topo:            [dynamic]u32,
  // spawned since the last build_tree
  tree_stale:      bool,
  // what the last `update` changed, removals first; the next update replaces it
  feed:            [dynamic]NodeChange,
  // removals made between updates; published by update
  pending_removed: [dynamic]u32,
}

// node returns a copy of the node behind `handle`; false when stale. Change it with translate,
// rotate, scale, set_local, set_visible, tag and set_name.
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

// children lists a node's children, valid until the next node_create; nil when `handle` is stale.
// Children despawned since the last update may still be listed, as stale handles (node
// rejects them).
children :: proc(self: ^World, handle: NodeHandle) -> []NodeHandle {
  if !containers.slots_valid(&self.slots, handle) do return nil
  if self.tree_stale do build_tree(self)
  return children_of(self, handle.index)
}

// find returns the first node named `name` under `root` (the whole world by default), searching
// depth first; false when none is.
find :: proc(self: ^World, name: string, root: NodeHandle = {}) -> (handle: NodeHandle, ok: bool) #optional_ok {
  stack := make([dynamic]NodeHandle, context.temp_allocator)
  append(&stack, root if root != {} else self.root)
  for len(stack) > 0 {
    h := pop(&stack)
    n := lookup(self, h) or_continue
    if n.name == name && h != root do return h, true
    append(&stack, ..children(self, h))
  }
  return
}

@(private)
children_of :: #force_inline proc(self: ^World, i: u32) -> []NodeHandle {
  return self.children[self.child_first[i]:][:self.child_count[i]]
}

// Rebuild the child lists and topo order from every live node's parent.
@(private)
build_tree :: proc(self: ^World) {
  n := int(self.slots.high_water)
  resize(&self.child_first, n)
  resize(&self.child_count, n)
  slice.zero(self.child_count[:])
  for i in 0 ..< u32(n) {
    if i == self.root.index || !containers.slots_live(&self.slots, i) do continue
    p := self.nodes[i].parent
    if containers.slots_valid(&self.slots, p) do self.child_count[p.index] += 1
  }
  total: u32
  for count, i in self.child_count {
    self.child_first[i] = total
    total += count
  }
  resize(&self.children, int(total))
  fill := make([]u32, n, context.temp_allocator)
  for i in 0 ..< u32(n) {
    if i == self.root.index || !containers.slots_live(&self.slots, i) do continue
    p := self.nodes[i].parent
    if !containers.slots_valid(&self.slots, p) do continue
    self.children[self.child_first[p.index] + fill[p.index]] = NodeHandle(containers.slots_handle(&self.slots, i))
    fill[p.index] += 1
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
  self.tree_stale = false
}

// Live nodes, root included.
@(private)
node_count :: proc(self: ^World) -> int {
  return int(self.slots.count)
}

// tag sets user tag bits on a node; false if the node is not found.
tag :: proc(self: ^World, handle: NodeHandle, bits: u32) -> bool {
  node := lookup(self, handle) or_return
  node.tags |= bits
  return true
}

// untag clears user tag bits on a node; false if the node is not found.
untag :: proc(self: ^World, handle: NodeHandle, bits: u32) -> bool {
  node := lookup(self, handle) or_return
  node.tags &~= bits
  return true
}

@(private)
node_init :: proc(self: ^Node, name: string = "") {
  self.transform = TRANSFORM_IDENTITY
  self.name = name
  self.visible = true
  self.tags = 0
}

spawn :: node_create

// node_create (or its alias spawn) creates a node under `parent`, the world root by default;
// false when `parent` is stale or no slot is free.
node_create :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  name: string = "",
  parent: NodeHandle = {},
) -> (
  handle: NodeHandle,
  ok: bool,
) #optional_ok {
  parent := parent if parent != {} else self.root
  if !containers.slots_valid(&self.slots, parent) do return
  handle = alloc_node(self, name) or_return
  node := &self.nodes[handle.index]
  node.parent = parent
  node.transform.position = position
  self.cache[handle.index].is_dirty = true
  self.tree_stale = true
  return handle, true
}

@(private = "file")
alloc_node :: proc(self: ^World, name: string) -> (handle: NodeHandle, ok: bool) {
  index := containers.slots_alloc(&self.slots) or_return
  node_init(&self.nodes[index], name)
  self.cache[index] = NODE_CACHE_INIT
  return NodeHandle(containers.slots_handle(&self.slots, index)), true
}

// init prepares the world with its root node; false when no slot is free.
init :: proc(self: ^World) -> bool {
  containers.slots_init(&self.slots, MAX_NODES_IN_SCENE, RETIRE_GRACE)
  self.nodes = make([]Node, MAX_NODES_IN_SCENE)
  self.cache = make([]Node_Cache, MAX_NODES_IN_SCENE)
  self.root = alloc_node(self, "root") or_return
  self.nodes[self.root.index].parent = self.root
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
  delete(self.child_count)
  delete(self.topo)
  delete(self.feed)
  delete(self.pending_removed)
}

// teardown drops every node but the root at once. Removals are not reported:
// index-keyed consumers (render.teardown) must reset their own slots, before the
// next level spawns into the freed ones.
teardown :: proc(self: ^World) {
  slice.zero(self.nodes[self.slots.mark:self.slots.high_water])
  slice.zero(self.cache[self.slots.mark:self.slots.high_water])
  containers.slots_rewind(&self.slots)
  self.tree_stale = true
  clear(&self.pending_removed)
  clear(&self.feed)
}

// node_destroy removes a node and its descendants; changes reports them after the next update.
node_destroy :: proc(self: ^World, handle: NodeHandle) -> bool {
  if handle == self.root || !containers.slots_valid(&self.slots, handle) do return false
  // removals need no rebuild: the lists hold handles, and freed ones go stale
  if self.tree_stale do build_tree(self)
  despawn_subtree(self, handle)
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

// Recompute world transforms of dirty subtrees, parents first, and record every node
// whose world transform or effective visibility changed.
@(private)
traverse :: proc(self: ^World) {
  // world transform changed this update, per node index
  moved := make([]bool, len(self.child_first), context.temp_allocator)
  for i in self.topo {
    current_node, c := &self.nodes[i], &self.cache[i]
    parent_moved, parent_visible := false, true
    parent: ^Node_Cache
    if i != self.root.index {
      p := current_node.parent.index
      parent = &self.cache[p]
      parent_moved = moved[p]
      parent_visible = parent.parent_visible && self.nodes[p].visible
    }
    visibility_changed := c.parent_visible != parent_visible
    c.parent_visible = parent_visible
    is_dirty := c.is_dirty
    if is_dirty {
      t := current_node.transform
      c.local_matrix = linalg.matrix4_from_trs(t.position, t.rotation, t.scale)
      c.is_dirty = false
    }
    if parent_moved || is_dirty {
      c.world_matrix = parent.world_matrix * c.local_matrix if parent != nil else c.local_matrix
    }
    moved[i] = parent_moved || is_dirty
    if visibility_changed || moved[i] {
      append(
        &self.feed,
        NodeChange {
          index = i,
          world_matrix = c.world_matrix,
          visible = parent_visible && current_node.visible,
        },
      )
    }
  }
}

// set_world_pose places a node at a world (position, rotation) whatever its
// parent; scale is kept.
set_world_pose :: proc(
  self: ^World,
  handle: NodeHandle,
  position: [3]f32,
  rotation: quaternion128,
) {
  node := lookup(self, handle)
  if node == nil do return
  _, has_parent := lookup(self, node.parent)
  if !has_parent || node.parent == self.root || node.parent == handle {
    node.transform.position = position
    node.transform.rotation = rotation
  } else {
    parent_world := self.cache[node.parent.index].world_matrix
    inv := linalg.matrix4_inverse(parent_world)
    node.transform.position = (inv * [4]f32{position.x, position.y, position.z, 1}).xyz
    parent_rotation := linalg.quaternion_from_matrix4_f32(parent_world)
    node.transform.rotation = linalg.normalize(linalg.quaternion_inverse(parent_rotation) * rotation)
  }
  self.cache[handle.index].is_dirty = true
}

// set_world_poses is set_world_pose for every pose of `poses`: any struct with
// `user` (the node's Handle), `position` and `rotation` fields, such as
// physics.BodyPose.
set_world_poses :: proc(self: ^World, poses: []$T) {
  for &p in poses do set_world_pose(self, NodeHandle(p.user), p.position, p.rotation)
}

// set_local_matrix sets a node's local transform from a matrix (decomposed into TRS).
set_local_matrix :: proc(self: ^World, handle: NodeHandle, m: matrix[4, 4]f32) {
  position, rotation, scale := geometry.decompose_matrix(m)
  set_local(self, handle, position, rotation, scale)
}

// world_matrix returns a node's world matrix as of the last update; identity when stale.
world_matrix :: proc(self: ^World, handle: NodeHandle) -> matrix[4, 4]f32 {
  if !containers.slots_valid(&self.slots, handle) do return linalg.MATRIX4F32_IDENTITY
  return self.cache[handle.index].world_matrix
}

// set_visible shows or hides a node and its subtree.
set_visible :: proc(self: ^World, handle: NodeHandle, visible: bool) {
  node := lookup(self, handle)
  if node == nil do return
  if node.visible == visible do return
  node.visible = visible
  self.cache[handle.index].is_dirty = true
}

// destroy removes a node, as node_destroy does.
destroy :: proc {
  node_destroy,
}
