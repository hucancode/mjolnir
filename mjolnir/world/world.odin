package world

import cont "../containers"
import "../geometry"
import "core:math/linalg"
import "core:slice"

// Node is one scene-graph entry: links, local transform, visibility and user tags.
Node :: struct {
  parent:         NodeHandle,
  children:       [dynamic]NodeHandle,
  transform:      Transform,
  name:           string,
  visible:        bool, // node's own visibility state
  parent_visible: bool, // visibility inherited from parent chain
  tags:           u32, // user-defined bit flags
}

@(private)
TraverseEntry :: struct {
  handle:            NodeHandle,
  parent_transform:  matrix[4, 4]f32,
  parent_is_dirty:   bool,
  parent_is_visible: bool,
}

// A node whose world transform or effective visibility changed, or that was
// despawned (`removed`; the other fields are then zero).
NodeChange :: struct {
  index:        u32,
  world_matrix: matrix[4, 4]f32,
  visible:      bool, // own visibility and every ancestor's
  removed:      bool,
}

// World is the scene graph. Set up with init, free with shutdown.
World :: struct {
  root:             NodeHandle,
  nodes:           cont.Pool(Node),
  traversal_stack: [dynamic]TraverseEntry,
  // what the last `update` changed, removals first; the next update replaces it
  feed:            [dynamic]NodeChange,
  // removals made between updates; published by update
  pending_removed: [dynamic]u32,
}

// node returns the node behind `h`; false when stale.
node :: proc(w: ^World, h: NodeHandle) -> (^Node, bool) #optional_ok {
  return cont.get(w.nodes, h)
}

// valid reports whether `h` refers to a live node.
valid :: proc(w: ^World, h: NodeHandle) -> bool {
  return cont.is_valid(w.nodes, h)
}

// Live nodes, root included. O(capacity).
@(private)
node_count :: proc(w: ^World) -> int {
  return cont.count(w.nodes)
}

// tag sets user tag bits on a node; false if the node is not found.
tag :: proc(world: ^World, handle: NodeHandle, bits: u32) -> bool {
  node := cont.get(world.nodes, handle) or_return
  node.tags |= bits
  return true
}

// untag clears user tag bits on a node; false if the node is not found.
untag :: proc(world: ^World, handle: NodeHandle, bits: u32) -> bool {
  node := cont.get(world.nodes, handle) or_return
  node.tags &~= bits
  return true
}

@(private)
node_init :: proc(self: ^Node, name: string = "") {
  self.transform = TRANSFORM_IDENTITY
  self.name = name
  self.visible = true
  self.parent_visible = true
  self.tags = 0
}

@(private)
node_destroy :: proc(self: ^Node) {
  delete(self.children)
  self.children = {}
}

@(private)
detach :: proc(nodes: cont.Pool(Node), child_handle: NodeHandle) {
  child_node := cont.get(nodes, child_handle)
  if child_node == nil do return
  parent_handle := child_node.parent
  if parent_handle == child_handle do return
  parent_node := cont.get(nodes, parent_handle)
  if parent_node == nil do return
  if idx, found := slice.linear_search(parent_node.children[:], child_handle); found {
    unordered_remove(&parent_node.children, idx)
  }
  child_node.parent = child_handle
}

@(private)
attach :: proc(nodes: cont.Pool(Node), parent_handle, child_handle: NodeHandle) {
  child_node := cont.get(nodes, child_handle)
  parent_node := cont.get(nodes, parent_handle)
  if child_node == nil || parent_node == nil do return
  if old_parent_node, ok := cont.get(nodes, child_node.parent); ok {
    if idx, found := slice.linear_search(old_parent_node.children[:], child_handle); found {
      unordered_remove(&old_parent_node.children, idx)
    }
  }
  child_node.parent = parent_handle
  if parent_handle != child_handle {
    append(&parent_node.children, child_handle)
  }
}

// spawn creates a node under the world root.
spawn :: proc(
  self: ^World,
  position: [3]f32 = {0, 0, 0},
  name: string = "",
) -> (
  handle: NodeHandle,
  ok: bool,
) #optional_ok {
  return spawn_child(self, self.root, position, name)
}

// spawn_child creates a node under `parent`.
spawn_child :: proc(
  self: ^World,
  parent: NodeHandle,
  position: [3]f32 = {0, 0, 0},
  name: string = "",
) -> (
  handle: NodeHandle,
  ok: bool,
) #optional_ok {
  node: ^Node
  handle, node = cont.alloc(&self.nodes, NodeHandle) or_return
  node_init(node, name)
  node.transform.position = position
  node.transform.is_dirty = true
  attach(self.nodes, parent, handle)
  return handle, true
}

// init prepares `world` with its root node; false when the pool cannot allocate.
init :: proc(world: ^World) -> bool {
  cont.init(&world.nodes, MAX_NODES_IN_SCENE, RETIRE_GRACE)
  root: ^Node
  world.root, root = cont.alloc(&world.nodes, NodeHandle) or_return
  node_init(root, "root")
  root.parent = world.root
  return true
}

// update advances one tick: recomputes world transforms and fills the change feed.
update :: proc(world: ^World) {
  clear(&world.feed)
  for index in world.pending_removed do append(&world.feed, NodeChange{index = index, removed = true})
  clear(&world.pending_removed)
  cont.tick(&world.nodes, nil, node_retire)
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
  cont.flush(&world.nodes, nil, node_retire)
  cont.destroy(&world.nodes, node_destroy)
  delete(world.traversal_stack)
  delete(world.feed)
  delete(world.pending_removed)
}

// teardown despawns every node under root. Slots are reclaimed immediately and
// removals are not reported: index-keyed consumers (render.teardown) must reset
// their own slots, before the next level spawns into the freed ones.
teardown :: proc(world: ^World) {
  root := cont.get(world.nodes, world.root)
  if root == nil do return
  kids := make([dynamic]NodeHandle, 0, len(root.children), context.temp_allocator)
  append(&kids, ..root.children[:])
  clear(&root.children)
  for h in kids {
    node := cont.get(world.nodes, h) or_continue
    node.parent = h // detached, matching detach()'s self-parent convention
    despawn_subtree(world, h, node)
  }
  cont.flush(&world.nodes, nil, node_retire)
  clear(&world.pending_removed)
  clear(&world.feed)
}

// despawn removes a node and its descendants; changes reports them after the next update.
despawn :: proc(world: ^World, handle: NodeHandle) -> bool {
  node := cont.get(world.nodes, handle) or_return
  detach(world.nodes, handle)
  despawn_subtree(world, handle, node)
  return true
}

// Free a node and its descendants without touching the parent's children
// array; the caller has already detached `handle`. Skipping per-child detach
// keeps bulk despawn O(N).
@(private)
despawn_subtree :: proc(world: ^World, handle: NodeHandle, node: ^Node) {
  for child_handle in node.children {
    child_node := cont.get(world.nodes, child_handle) or_continue
    despawn_subtree(world, child_handle, child_node)
  }
  append(&world.pending_removed, handle.index)
  cont.free_deferred(&world.nodes, handle)
}

@(private = "file")
node_retire :: proc(item: ^Node, _: rawptr) {
  node_destroy(item)
}

// Recompute world transforms of dirty subtrees and record every node whose
// world transform or effective visibility changed.
@(private)
traverse :: proc(world: ^World) {
  append(
    &world.traversal_stack,
    TraverseEntry{world.root, linalg.MATRIX4F32_IDENTITY, false, true},
  )
  for len(world.traversal_stack) > 0 {
    entry := pop(&world.traversal_stack)
    current_node := cont.get(world.nodes, entry.handle) or_continue
    visibility_changed := current_node.parent_visible != entry.parent_is_visible
    current_node.parent_visible = entry.parent_is_visible
    t := &current_node.transform
    is_dirty := t.is_dirty
    if is_dirty {
      t.local_matrix = linalg.matrix4_from_trs(t.position, t.rotation, t.scale)
      t.is_dirty = false
    }
    if entry.parent_is_dirty || is_dirty {
      t.world_matrix = entry.parent_transform * t.local_matrix
    }
    if visibility_changed || is_dirty || entry.parent_is_dirty {
      append(
        &world.feed,
        NodeChange {
          index = entry.handle.index,
          world_matrix = current_node.transform.world_matrix,
          visible = current_node.parent_visible && current_node.visible,
        },
      )
    }
    for child_handle in current_node.children {
      append(
        &world.traversal_stack,
        TraverseEntry {
          child_handle,
          current_node.transform.world_matrix,
          is_dirty || entry.parent_is_dirty,
          current_node.parent_visible && current_node.visible,
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
  node := cont.get(world.nodes, handle)
  if node == nil do return
  parent, has_parent := cont.get(world.nodes, node.parent)
  if !has_parent || node.parent == world.root || node.parent == handle {
    node.transform.position = position
    node.transform.rotation = rotation
  } else {
    parent_world := parent.transform.world_matrix
    inv := linalg.matrix4_inverse(parent_world)
    node.transform.position = (inv * [4]f32{position.x, position.y, position.z, 1}).xyz
    parent_rotation := linalg.quaternion_from_matrix4_f32(parent_world)
    node.transform.rotation = linalg.normalize(linalg.quaternion_inverse(parent_rotation) * rotation)
  }
  node.transform.is_dirty = true
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
  node, ok := cont.get(world.nodes, handle)
  if !ok do return linalg.MATRIX4F32_IDENTITY
  return node.transform.world_matrix
}

// set_visible shows or hides a node and its subtree.
set_visible :: proc(world: ^World, handle: NodeHandle, visible: bool) {
  node := cont.get(world.nodes, handle)
  if node == nil do return
  if node.visible == visible do return
  node.visible = visible
  node.transform.is_dirty = true
}
