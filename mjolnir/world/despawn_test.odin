#+build !js
#+private
package world

import "core:fmt"
import "core:testing"

@(test)
test_despawn_single_node :: proc(t: ^testing.T) {
  w: World
  init(&w)
  defer shutdown(&w)

  // Spawn a single node
  node_handle, ok := spawn(&w, {1, 2, 3})
  testing.expectf(t, ok, "failed to spawn node")

  // Verify node exists
  n := lookup(&w, node_handle)
  testing.expectf(t, n != nil, "node should exist after spawning")

  // Despawn the node
  despawn_ok := despawn(&w, node_handle)
  testing.expectf(t, despawn_ok, "despawn should succeed")

  // Verify node no longer exists
  node_after := lookup(&w, node_handle)
  testing.expectf(
    t,
    node_after == nil,
    "node should not exist after despawning",
  )
}

@(test)
test_despawn_node_with_children :: proc(t: ^testing.T) {
  w: World
  init(&w)
  defer shutdown(&w)

  // Create parent with 3 children
  parent_handle, parent_ok := spawn(&w, {0, 0, 0})
  testing.expectf(t, parent_ok, "failed to spawn parent node")

  child1_handle, child1_ok := spawn(&w, {1, 0, 0}, parent = parent_handle)
  testing.expectf(t, child1_ok, "failed to spawn child1")

  child2_handle, child2_ok := spawn(&w, {2, 0, 0}, parent = parent_handle)
  testing.expectf(t, child2_ok, "failed to spawn child2")

  child3_handle, child3_ok := spawn(&w, {3, 0, 0}, parent = parent_handle)
  testing.expectf(t, child3_ok, "failed to spawn child3")

  // Verify all nodes exist
  parent := lookup(&w, parent_handle)
  testing.expectf(t, parent != nil, "parent should exist")
  testing.expectf(
    t,
    len(children(&w, parent_handle)) == 3,
    fmt.tprintf(
      "parent should have 3 children, got %d",
      len(children(&w, parent_handle)),
    ),
  )

  // Despawn parent
  despawn_ok := despawn(&w, parent_handle)
  testing.expectf(t, despawn_ok, "despawn should succeed")

  // Verify all nodes are freed
  parent_after := lookup(&w, parent_handle)
  child1_after := lookup(&w, child1_handle)
  child2_after := lookup(&w, child2_handle)
  child3_after := lookup(&w, child3_handle)

  testing.expectf(t, parent_after == nil, "parent should be freed")
  testing.expectf(t, child1_after == nil, "child1 should be freed")
  testing.expectf(t, child2_after == nil, "child2 should be freed")
  testing.expectf(t, child3_after == nil, "child3 should be freed")
}

@(test)
test_despawn_hierarchy :: proc(t: ^testing.T) {
  w: World
  init(&w)
  defer shutdown(&w)

  // Create a 3-level hierarchy:
  // root
  //   └─ parent
  //       ├─ child1
  //       │   └─ grandchild1
  //       └─ child2
  //           └─ grandchild2

  parent_handle, parent_ok := spawn(&w, {0, 0, 0})
  testing.expectf(t, parent_ok, "failed to spawn parent")

  child1_handle, child1_ok := spawn(&w, {1, 0, 0}, parent = parent_handle)
  testing.expectf(t, child1_ok, "failed to spawn child1")

  child2_handle, child2_ok := spawn(&w, {2, 0, 0}, parent = parent_handle)
  testing.expectf(t, child2_ok, "failed to spawn child2")

  grandchild1_handle, gc1_ok := spawn(&w, {1, 1, 0}, parent = child1_handle)
  testing.expectf(t, gc1_ok, "failed to spawn grandchild1")

  grandchild2_handle, gc2_ok := spawn(&w, {2, 1, 0}, parent = child2_handle)
  testing.expectf(t, gc2_ok, "failed to spawn grandchild2")

  // Despawn parent (should recursively delete entire subtree)
  despawn_ok := despawn(&w, parent_handle)
  testing.expectf(t, despawn_ok, "despawn should succeed")

  // Verify entire subtree is freed
  testing.expectf(
    t,
    lookup(&w, parent_handle) == nil,
    "parent should be freed",
  )
  testing.expectf(
    t,
    lookup(&w, child1_handle) == nil,
    "child1 should be freed",
  )
  testing.expectf(
    t,
    lookup(&w, child2_handle) == nil,
    "child2 should be freed",
  )
  testing.expectf(
    t,
    lookup(&w, grandchild1_handle) == nil,
    "grandchild1 should be freed",
  )
  testing.expectf(
    t,
    lookup(&w, grandchild2_handle) == nil,
    "grandchild2 should be freed",
  )
}

@(test)
test_despawn_detaches_from_parent :: proc(t: ^testing.T) {
  w: World
  init(&w)
  defer shutdown(&w)

  // Create parent with 2 children
  parent_handle, parent_ok := spawn(&w, {0, 0, 0})
  testing.expectf(t, parent_ok, "failed to spawn parent")

  child1_handle, child1_ok := spawn(&w, parent = parent_handle)
  testing.expectf(t, child1_ok, "failed to spawn child1")

  child2_handle, child2_ok := spawn(&w, parent = parent_handle)
  testing.expectf(t, child2_ok, "failed to spawn child2")

  testing.expectf(
    t,
    len(children(&w, parent_handle)) == 2,
    "parent should have 2 children",
  )

  // Despawn only child1 (not the parent)
  despawn_ok := despawn(&w, child1_handle)
  testing.expectf(t, despawn_ok, "despawn should succeed")

  // Verify child1 is freed but parent and child2 still exist
  testing.expectf(
    t,
    lookup(&w, child1_handle) == nil,
    "child1 should be freed",
  )

  parent_after := lookup(&w, parent_handle)
  child2_after := lookup(&w, child2_handle)
  testing.expectf(t, parent_after != nil, "parent should still exist")
  testing.expectf(t, child2_after != nil, "child2 should still exist")

  // Verify parent's children are updated
  update(&w)
  testing.expectf(
    t,
    len(children(&w, parent_handle)) == 1,
    fmt.tprintf(
      "parent should have 1 child remaining, got %d",
      len(children(&w, parent_handle)),
    ),
  )
  testing.expectf(
    t,
    children(&w, parent_handle)[0] == child2_handle,
    "remaining child should be child2",
  )
}

@(test)
test_despawn_reports_removed_node :: proc(t: ^testing.T) {
  w: World
  init(&w)
  defer shutdown(&w)
  node_handle, ok := spawn(&w, {1, 2, 3})
  testing.expectf(t, ok, "failed to spawn node")
  update(&w)
  changed := false
  for n in changes(&w) do changed |= n.index == node_handle.index && !n.removed
  testing.expectf(t, changed, "spawned node should be in the change feed")
  testing.expectf(t, despawn(&w, node_handle), "despawn should succeed")
  testing.expectf(t, lookup(&w, node_handle) == nil, "node should be freed immediately")
  update(&w)
  removed := false
  for n in changes(&w) do removed |= n.index == node_handle.index && n.removed
  testing.expectf(t, removed, "despawned node should be in the removal feed")
  update(&w)
  testing.expectf(t, len(changes(&w)) == 0, "removal reported once")
}

@(test)
test_teardown_keeps_root :: proc(t: ^testing.T) {
  w: World
  init(&w)
  defer shutdown(&w)
  parent := spawn(&w)
  child := spawn(&w, parent = parent)
  despawn(&w, spawn(&w)) // retiring at teardown
  update(&w)
  teardown(&w)
  _, root_ok := node(&w, w.root)
  _, parent_ok := lookup(&w, parent)
  _, child_ok := lookup(&w, child)
  testing.expect(t, root_ok && !parent_ok && !child_ok)
  testing.expect_value(t, node_count(&w), 1)
  testing.expect_value(t, len(children(&w, w.root)), 0)
  // the next map spawns into the freed slots and traverses cleanly
  again := spawn(&w, {1, 0, 0})
  testing.expect_value(t, again.index, parent.index)
  update(&w)
  testing.expect_value(t, len(changes(&w)), 1)
}
