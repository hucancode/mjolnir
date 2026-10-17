package world

import cont "../containers"
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
  slots:           cont.Slots,
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

// node returns a copy of the node behind `h`; false when stale. Change it with translate,
// rotate, scale, set_local, set_visible, tag and set_name.
node :: proc(w: ^World, h: NodeHandle) -> (n: Node, ok: bool) #optional_ok {
  p := lookup(w, h) or_return
  return p^, true
}

// set_name names a node; the name is borrowed, not copied.
set_name :: proc(world: ^World, handle: NodeHandle, name: string) {
  node := lookup(world, handle)
  if node == nil do return
  node.name = name
}

@(private)
lookup :: #force_inline proc(w: ^World, h: NodeHandle) -> (^Node, bool) #optional_ok {
  if !cont.slots_valid(&w.slots, h) do return nil, false
  return &w.nodes[h.index], true
}

// children lists a node's children, valid until the next spawn; nil when `h` is stale.
// Children despawned since the last update may still be listed, as stale handles (node
// rejects them).
children :: proc(w: ^World, h: NodeHandle) -> []NodeHandle {
  if !cont.slots_valid(&w.slots, h) do return nil
  if w.tree_stale do build_tree(w)
  return children_of(w, h.index)
}

@(private)
children_of :: #force_inline proc(w: ^World, i: u32) -> []NodeHandle {
  return w.children[w.child_first[i]:][:w.child_count[i]]
}

// Rebuild the child lists and topo order from every live node's parent.
@(private)
build_tree :: proc(w: ^World) {
  n := int(w.slots.high_water)
  resize(&w.child_first, n)
  resize(&w.child_count, n)
  slice.zero(w.child_count[:])
  for i in 0 ..< u32(n) {
    if i == w.root.index || !cont.slots_live(&w.slots, i) do continue
    p := w.nodes[i].parent
    if cont.slots_valid(&w.slots, p) do w.child_count[p.index] += 1
  }
  total: u32
  for count, i in w.child_count {
    w.child_first[i] = total
    total += count
  }
  resize(&w.children, int(total))
  fill := make([]u32, n, context.temp_allocator)
  for i in 0 ..< u32(n) {
    if i == w.root.index || !cont.slots_live(&w.slots, i) do continue
    p := w.nodes[i].parent
    if !cont.slots_valid(&w.slots, p) do continue
    w.children[w.child_first[p.index] + fill[p.index]] = NodeHandle(cont.slots_handle(&w.slots, i))
    fill[p.index] += 1
  }
  // depth first, so a subtree is contiguous
  clear(&w.topo)
  stack := make([dynamic]u32, 0, 64, context.temp_allocator)
  append(&stack, w.root.index)
  for len(stack) > 0 {
    i := pop(&stack)
    append(&w.topo, i)
    for c in children_of(w, i) do append(&stack, c.index)
  }
  w.tree_stale = false
}

// Live nodes, root included.
@(private)
node_count :: proc(w: ^World) -> int {
  return int(w.slots.count)
}

// tag sets user tag bits on a node; false if the node is not found.
tag :: proc(world: ^World, handle: NodeHandle, bits: u32) -> bool {
  node := lookup(world, handle) or_return
  node.tags |= bits
  return true
}

// untag clears user tag bits on a node; false if the node is not found.
untag :: proc(world: ^World, handle: NodeHandle, bits: u32) -> bool {
  node := lookup(world, handle) or_return
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

// spawn creates a node under `parent`, the world root by default; false when `parent` is
// stale or no slot is free.
spawn :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  name: string = "",
  parent: NodeHandle = {},
) -> (
  handle: NodeHandle,
  ok: bool,
) #optional_ok {
  parent := parent if parent != {} else self.root
  if !cont.slots_valid(&self.slots, parent) do return
  handle = alloc_node(self, name) or_return
  node := &self.nodes[handle.index]
  node.parent = parent
  node.transform.position = position
  self.cache[handle.index].is_dirty = true
  self.tree_stale = true
  return handle, true
}

@(private = "file")
alloc_node :: proc(world: ^World, name: string) -> (handle: NodeHandle, ok: bool) {
  index := cont.slots_alloc(&world.slots) or_return
  node_init(&world.nodes[index], name)
  world.cache[index] = NODE_CACHE_INIT
  return NodeHandle(cont.slots_handle(&world.slots, index)), true
}

// init prepares `world` with its root node; false when no slot is free.
init :: proc(world: ^World) -> bool {
  cont.slots_init(&world.slots, MAX_NODES_IN_SCENE, RETIRE_GRACE)
  world.nodes = make([]Node, MAX_NODES_IN_SCENE)
  world.cache = make([]Node_Cache, MAX_NODES_IN_SCENE)
  world.root = alloc_node(world, "root") or_return
  world.nodes[world.root.index].parent = world.root
  world.tree_stale = true
  // the root outlives teardown
  cont.slots_mark(&world.slots)
  return true
}

// update advances one tick: recomputes world transforms and fills the change feed.
update :: proc(world: ^World) {
  clear(&world.feed)
  if world.tree_stale || len(world.pending_removed) > 0 do build_tree(world)
  for index in world.pending_removed do append(&world.feed, NodeChange{index = index, removed = true})
  clear(&world.pending_removed)
  for r in cont.slots_tick(&world.slots) do world.nodes[r.index], world.cache[r.index] = {}, {}
  traverse(world)
}

// changes lists what the last update changed: nodes despawned since the update
// before (`removed`, first), then nodes whose world transform or visibility changed.
// Node indices are stable for a node's lifetime: safe as external slot ids.
changes :: proc(world: ^World) -> []NodeChange {
  return world.feed[:]
}

// shutdown frees everything `world` owns.
shutdown :: proc(world: ^World) {
  cont.slots_destroy(&world.slots)
  delete(world.nodes)
  delete(world.cache)
  delete(world.children)
  delete(world.child_first)
  delete(world.child_count)
  delete(world.topo)
  delete(world.feed)
  delete(world.pending_removed)
}

// teardown drops every node but the root at once. Removals are not reported:
// index-keyed consumers (render.teardown) must reset their own slots, before the
// next level spawns into the freed ones.
teardown :: proc(world: ^World) {
  slice.zero(world.nodes[world.slots.mark:world.slots.high_water])
  slice.zero(world.cache[world.slots.mark:world.slots.high_water])
  cont.slots_rewind(&world.slots)
  world.tree_stale = true
  clear(&world.pending_removed)
  clear(&world.feed)
}

// despawn removes a node and its descendants; changes reports them after the next update.
despawn :: proc(world: ^World, handle: NodeHandle) -> bool {
  if handle == world.root || !cont.slots_valid(&world.slots, handle) do return false
  // removals need no rebuild: the lists hold handles, and freed ones go stale
  if world.tree_stale do build_tree(world)
  despawn_subtree(world, handle)
  return true
}

@(private)
despawn_subtree :: proc(world: ^World, handle: NodeHandle) {
  for child in children_of(world, handle.index) {
    if cont.slots_valid(&world.slots, child) do despawn_subtree(world, child)
  }
  append(&world.pending_removed, handle.index)
  cont.slots_free(&world.slots, handle.index)
}

// Recompute world transforms of dirty subtrees, parents first, and record every node
// whose world transform or effective visibility changed.
@(private)
traverse :: proc(world: ^World) {
  // world transform changed this update, per node index
  moved := make([]bool, len(world.child_first), context.temp_allocator)
  for i in world.topo {
    current_node, c := &world.nodes[i], &world.cache[i]
    parent_moved, parent_visible := false, true
    parent: ^Node_Cache
    if i != world.root.index {
      p := current_node.parent.index
      parent = &world.cache[p]
      parent_moved = moved[p]
      parent_visible = parent.parent_visible && world.nodes[p].visible
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
        &world.feed,
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
  world: ^World,
  handle: NodeHandle,
  position: [3]f32,
  rotation: quaternion128,
) {
  node := lookup(world, handle)
  if node == nil do return
  _, has_parent := lookup(world, node.parent)
  if !has_parent || node.parent == world.root || node.parent == handle {
    node.transform.position = position
    node.transform.rotation = rotation
  } else {
    parent_world := world.cache[node.parent.index].world_matrix
    inv := linalg.matrix4_inverse(parent_world)
    node.transform.position = (inv * [4]f32{position.x, position.y, position.z, 1}).xyz
    parent_rotation := linalg.quaternion_from_matrix4_f32(parent_world)
    node.transform.rotation = linalg.normalize(linalg.quaternion_inverse(parent_rotation) * rotation)
  }
  world.cache[handle.index].is_dirty = true
}

// set_world_poses is set_world_pose for every pose of `poses`: any struct with
// `user` (the node's Handle), `position` and `rotation` fields, such as
// physics.BodyPose.
set_world_poses :: proc(world: ^World, poses: []$T) {
  for &p in poses do set_world_pose(world, NodeHandle(p.user), p.position, p.rotation)
}

// set_local_matrix sets a node's local transform from a matrix (decomposed into TRS).
set_local_matrix :: proc(world: ^World, handle: NodeHandle, m: matrix[4, 4]f32) {
  position, rotation, scale := geometry.decompose_matrix(m)
  set_local(world, handle, position, rotation, scale)
}

// world_matrix returns a node's world matrix as of the last update; identity when stale.
world_matrix :: proc(world: ^World, handle: NodeHandle) -> matrix[4, 4]f32 {
  if !cont.slots_valid(&world.slots, handle) do return linalg.MATRIX4F32_IDENTITY
  return world.cache[handle.index].world_matrix
}

// set_visible shows or hides a node and its subtree.
set_visible :: proc(world: ^World, handle: NodeHandle, visible: bool) {
  node := lookup(world, handle)
  if node == nil do return
  if node.visible == visible do return
  node.visible = visible
  world.cache[handle.index].is_dirty = true
}
