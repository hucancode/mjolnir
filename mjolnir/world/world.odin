package world

import cont "../containers"
import "../geometry"
import "core:math/linalg"
import "core:slice"

Node :: struct {
  parent:         NodeHandle,
  children:       [dynamic]NodeHandle,
  transform:      geometry.Transform,
  name:           string,
  visible:        bool, // node's own visibility state
  parent_visible: bool, // visibility inherited from parent chain
  tags:           u32, // user-defined bit flags
}

TraverseEntry :: struct {
  handle:            NodeHandle,
  parent_transform:  matrix[4, 4]f32,
  parent_is_dirty:   bool,
  parent_is_visible: bool,
}

// A node whose world transform or effective visibility changed.
NodeChange :: struct {
  index:        u32,
  world_matrix: matrix[4, 4]f32,
  visible:      bool, // own visibility and every ancestor's
}

// What changed during the last `update`. Consumers (renderers, audio, net)
// read it after update; the next update replaces it. Node indices are stable
// for a node's lifetime and safe to use as external slot ids.
ChangeFeed :: struct {
  changed: [dynamic]NodeChange,
  removed: [dynamic]u32,
}

World :: struct {
  root:             NodeHandle,
  nodes:           Pool(Node),
  traversal_stack: [dynamic]TraverseEntry,
  feed:            ChangeFeed,
  // removals made between updates; published by update
  pending_removed: [dynamic]u32,
}

// Boundary accessors. Keep `containers` invisible to user code by going through these.
node :: proc(w: ^World, h: NodeHandle) -> (^Node, bool) #optional_ok {
  return cont.get(w.nodes, h)
}

valid :: proc(w: ^World, h: NodeHandle) -> bool {
  return cont.is_valid(w.nodes, h)
}

// Live nodes, root included.
node_count :: proc(w: ^World) -> int {
  return cont.count(w.nodes)
}

// Set user tag bits on a node. Returns false if node not found.
tag :: proc(world: ^World, handle: NodeHandle, bits: u32) -> bool {
  node := cont.get(world.nodes, handle) or_return
  node.tags |= bits
  return true
}

// Clear user tag bits on a node. Returns false if node not found.
untag :: proc(world: ^World, handle: NodeHandle, bits: u32) -> bool {
  node := cont.get(world.nodes, handle) or_return
  node.tags &~= bits
  return true
}

node_init :: proc(self: ^Node, name: string = "") {
  self.transform = geometry.TRANSFORM_IDENTITY
  self.name = name
  self.visible = true
  self.parent_visible = true
  self.tags = 0
}

node_destroy :: proc(self: ^Node) {
  delete(self.children)
  self.children = {}
}

detach :: proc(nodes: Pool(Node), child_handle: NodeHandle) {
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

attach :: proc(nodes: Pool(Node), parent_handle, child_handle: NodeHandle) {
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

init :: proc(world: ^World) -> bool {
  cont.init(&world.nodes, MAX_NODES_IN_SCENE, RETIRE_GRACE)
  root: ^Node
  world.root, root = cont.alloc(&world.nodes, NodeHandle) or_return
  node_init(root, "root")
  root.parent = world.root
  return true
}

// Advance one tick: recompute world transforms and fill the change feed.
update :: proc(world: ^World) {
  clear(&world.feed.changed)
  clear(&world.feed.removed)
  append(&world.feed.removed, ..world.pending_removed[:])
  clear(&world.pending_removed)
  cont.tick(&world.nodes, nil, node_retire)
  traverse(world)
}

changed_nodes :: proc(world: ^World) -> []NodeChange {
  return world.feed.changed[:]
}

removed_nodes :: proc(world: ^World) -> []u32 {
  return world.feed.removed[:]
}

shutdown :: proc(world: ^World) {
  cont.flush(&world.nodes, nil, node_retire)
  cont.destroy(&world.nodes, node_destroy)
  delete(world.traversal_stack)
  delete(world.feed.changed)
  delete(world.feed.removed)
  delete(world.pending_removed)
}

// Despawn every node under root. Slots are reclaimed immediately and the
// removals are not reported: consumers keyed by node index must reset their
// own slots alongside.
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
  clear(&world.feed.changed)
  clear(&world.feed.removed)
}

// Despawn a node and all its children recursively. Removals are reported by
// the next update's `removed_nodes`.
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
    is_dirty := geometry.update_local(&current_node.transform)
    if entry.parent_is_dirty || is_dirty {
      geometry.update_world(&current_node.transform, entry.parent_transform)
    }
    if visibility_changed || is_dirty || entry.parent_is_dirty {
      append(
        &world.feed.changed,
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

// Place a node so its world pose is (position, rotation), whatever its
// parent. Scale is kept.
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

// Set a node's local transform from a matrix (decomposed into TRS).
set_local_matrix :: proc(world: ^World, handle: NodeHandle, m: matrix[4, 4]f32) {
  node := cont.get(world.nodes, handle)
  if node == nil do return
  d := geometry.decompose_matrix(m)
  node.transform.position = d.position
  node.transform.rotation = d.rotation
  node.transform.scale = d.scale
  node.transform.is_dirty = true
}

world_matrix :: proc(world: ^World, handle: NodeHandle) -> matrix[4, 4]f32 {
  node, ok := cont.get(world.nodes, handle)
  if !ok do return linalg.MATRIX4F32_IDENTITY
  return node.transform.world_matrix
}

set_visible :: proc(world: ^World, handle: NodeHandle, visible: bool) {
  node := cont.get(world.nodes, handle)
  if node == nil do return
  if node.visible == visible do return
  node.visible = visible
  node.transform.is_dirty = true
}
