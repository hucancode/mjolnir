package world

import cont "../containers"
import "core:fmt"
import "core:log"
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
  node := get_node(&w, node_handle)
  testing.expectf(t, node != nil, "node should exist after spawning")

  // Despawn the node
  despawn_ok := despawn(&w, node_handle)
  testing.expectf(t, despawn_ok, "despawn should succeed")

  // Verify node no longer exists
  node_after := get_node(&w, node_handle)
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

  child1_handle, child1_ok := spawn_child(&w, parent_handle, {1, 0, 0})
  testing.expectf(t, child1_ok, "failed to spawn child1")

  child2_handle, child2_ok := spawn_child(&w, parent_handle, {2, 0, 0})
  testing.expectf(t, child2_ok, "failed to spawn child2")

  child3_handle, child3_ok := spawn_child(&w, parent_handle, {3, 0, 0})
  testing.expectf(t, child3_ok, "failed to spawn child3")

  // Verify all nodes exist
  parent := get_node(&w, parent_handle)
  testing.expectf(t, parent != nil, "parent should exist")
  testing.expectf(
    t,
    len(parent.children) == 3,
    fmt.tprintf(
      "parent should have 3 children, got %d",
      len(parent.children),
    ),
  )

  // Despawn parent
  despawn_ok := despawn(&w, parent_handle)
  testing.expectf(t, despawn_ok, "despawn should succeed")

  // Verify all nodes are freed
  parent_after := get_node(&w, parent_handle)
  child1_after := get_node(&w, child1_handle)
  child2_after := get_node(&w, child2_handle)
  child3_after := get_node(&w, child3_handle)

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

  child1_handle, child1_ok := spawn_child(&w, parent_handle, {1, 0, 0})
  testing.expectf(t, child1_ok, "failed to spawn child1")

  child2_handle, child2_ok := spawn_child(&w, parent_handle, {2, 0, 0})
  testing.expectf(t, child2_ok, "failed to spawn child2")

  grandchild1_handle, gc1_ok := spawn_child(&w, child1_handle, {1, 1, 0})
  testing.expectf(t, gc1_ok, "failed to spawn grandchild1")

  grandchild2_handle, gc2_ok := spawn_child(&w, child2_handle, {2, 1, 0})
  testing.expectf(t, gc2_ok, "failed to spawn grandchild2")

  // Despawn parent (should recursively delete entire subtree)
  despawn_ok := despawn(&w, parent_handle)
  testing.expectf(t, despawn_ok, "despawn should succeed")

  // Verify entire subtree is freed
  testing.expectf(
    t,
    get_node(&w, parent_handle) == nil,
    "parent should be freed",
  )
  testing.expectf(
    t,
    get_node(&w, child1_handle) == nil,
    "child1 should be freed",
  )
  testing.expectf(
    t,
    get_node(&w, child2_handle) == nil,
    "child2 should be freed",
  )
  testing.expectf(
    t,
    get_node(&w, grandchild1_handle) == nil,
    "grandchild1 should be freed",
  )
  testing.expectf(
    t,
    get_node(&w, grandchild2_handle) == nil,
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

  child1_handle, child1_ok := spawn_child(&w, parent_handle)
  testing.expectf(t, child1_ok, "failed to spawn child1")

  child2_handle, child2_ok := spawn_child(&w, parent_handle)
  testing.expectf(t, child2_ok, "failed to spawn child2")

  parent := get_node(&w, parent_handle)
  testing.expectf(
    t,
    len(parent.children) == 2,
    "parent should have 2 children",
  )

  // Despawn only child1 (not the parent)
  despawn_ok := despawn(&w, child1_handle)
  testing.expectf(t, despawn_ok, "despawn should succeed")

  // Verify child1 is freed but parent and child2 still exist
  testing.expectf(
    t,
    get_node(&w, child1_handle) == nil,
    "child1 should be freed",
  )

  parent_after := get_node(&w, parent_handle)
  child2_after := get_node(&w, child2_handle)
  testing.expectf(t, parent_after != nil, "parent should still exist")
  testing.expectf(t, child2_after != nil, "child2 should still exist")

  // Verify parent's children array is updated
  testing.expectf(
    t,
    len(parent_after.children) == 1,
    fmt.tprintf(
      "parent should have 1 child remaining, got %d",
      len(parent_after.children),
    ),
  )
  testing.expectf(
    t,
    parent_after.children[0] == child2_handle,
    "remaining child should be child2",
  )
}

@(test)
test_despawn_with_staging :: proc(t: ^testing.T) {
  w: World
  init(&w)
  defer shutdown(&w)

  // Spawn a node
  node_handle, ok := spawn(&w, {1, 2, 3})
  testing.expectf(t, ok, "failed to spawn node")

  // Node should be staged after spawn
  _, data_staged := w.staging.node_data[node_handle]
  testing.expectf(t, data_staged, "node data should be staged after spawn")

  // Despawn the node
  despawn_ok := despawn(&w, node_handle)
  testing.expectf(t, despawn_ok, "despawn should succeed")

  // Node should be staged again for GPU cleanup
  _, data_staged_after := w.staging.node_data[node_handle]
  testing.expectf(
    t,
    data_staged_after,
    "node data should be staged after despawn for GPU cleanup",
  )

  // Node should be freed immediately
  node_after := get_node(&w, node_handle)
  testing.expectf(
    t,
    node_after == nil,
    "node should be freed immediately after despawn",
  )
}
