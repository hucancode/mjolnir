#+build !js
#+private
package world

import "../containers"
import "core:math/rand"
import "core:mem"
import "core:testing"

@(private = "file")
near :: proc(a, b: matrix[4, 4]f32) -> bool {
  for i in 0 ..< 4 do for j in 0 ..< 4 do if abs(a[i, j] - b[i, j]) > 1e-3 do return false
  return true
}

@(test)
test_spawn_past_reserve :: proc(t: ^testing.T) {
  N :: 100_000
  w: World
  init(&w, 4)
  defer shutdown(&w)
  handles := make([]NodeHandle, N)
  defer delete(handles)
  for &h, i in handles {
    ok: bool
    h, ok = node_create(&w, position = {f32(i), 0, 0})
    testing.expect(t, ok, "spawning past the reserve grows")
    if !ok do return
  }
  update(&w)
  seen := 0
  for c in changes(&w) do if c.index > 4 do seen += 1
  testing.expect(t, seen >= N - 4, "changes report the nodes past the reserve")
  for h, i in handles {
    if !testing.expect(t, containers.slots_valid(&w.slots, h)) do return
    m := world_matrix(&w, h)
    if !testing.expectf(t, m[3].x == f32(i), "node %d at %v", i, m[3].xyz) do return
  }
}

@(test)
test_transform_pointer_survives_growth :: proc(t: ^testing.T) {
  w: World
  init(&w, 4)
  defer shutdown(&w)
  a := node_create(&w)
  p := transform(&w, a)
  for _ in 0 ..< 10_000 do node_create(&w)
  testing.expect(t, len(w.pages) > 2, "spawns added pages")
  p.position = {7, 8, 9}
  update(&w)
  testing.expect_value(t, world_matrix(&w, a)[3].xyz, [3]f32{7, 8, 9})
}

@(test)
test_parent_and_child_on_different_pages :: proc(t: ^testing.T) {
  w: World
  init(&w, 4)
  defer shutdown(&w)
  parent := node_create(&w)
  for _ in 0 ..< 5 * PAGE_SIZE do node_create(&w)
  child := node_create(&w, position = {0, 1, 0}, parent = parent)
  testing.expect(t, child.index >> PAGE_SHIFT >= 5)
  update(&w)
  transform(&w, parent).position = {10, 0, 0}
  update(&w)
  testing.expect_value(t, world_matrix(&w, child)[3].xyz, [3]f32{10, 1, 0})
}

@(test)
test_reuse_across_pages :: proc(t: ^testing.T) {
  N :: 3 * PAGE_SIZE
  w: World
  init(&w, 4)
  defer shutdown(&w)
  handles := make([]NodeHandle, N)
  defer delete(handles)
  for &h in handles do h = node_create(&w)
  update(&w)
  for i := 0; i < N; i += 2 do node_destroy(&w, handles[i])
  pages := len(w.pages)
  for _ in 0 ..< RETIRE_GRACE do update(&w)
  for _ in 0 ..< N / 2 do node_create(&w)
  testing.expect_value(t, len(w.pages), pages)
  for i := 0; i < N; i += 2 do testing.expect(t, !containers.slots_valid(&w.slots, handles[i]), "old handles are stale")
}

@(test)
test_teardown_after_growth :: proc(t: ^testing.T) {
  w: World
  init(&w, 4)
  defer shutdown(&w)
  first := node_create(&w)
  for _ in 0 ..< 20_000 do node_create(&w)
  update(&w)
  teardown(&w)
  testing.expect(t, containers.slots_valid(&w.slots, w.root), "the root survives")
  testing.expect_value(t, containers.slots_count(&w.slots), 1)
  again := node_create(&w)
  testing.expect_value(t, again.index, first.index)
  update(&w)
  testing.expect_value(t, len(w.topo), 2)
}

@(test)
test_despawn_deep_chain :: proc(t: ^testing.T) {
  N :: 200_000
  w: World
  init(&w)
  defer shutdown(&w)
  head := node_create(&w)
  p := head
  for _ in 1 ..< N do p = node_create(&w, parent = p)
  update(&w)
  testing.expect(t, node_destroy(&w, head))
  testing.expect_value(t, containers.slots_count(&w.slots), 1)
  update(&w)
  testing.expect_value(t, len(changes(&w)), N)
}

// Every subtree range of topo holds exactly the node's descendants, parents first.
@(private = "file")
check_topo :: proc(t: ^testing.T, w: ^World) -> bool {
  cursor: u32
  for i in containers.slots_next(&w.slots, &cursor) {
    first, end := w.topo_first[i], w.topo_end[i]
    if w.topo[first] != i do return testing.expectf(t, false, "node %d not at its topo_first", i)
    for k in first + 1 ..< end {
      d := w.topo[k]
      // d's ancestors include i
      found := false
      for p := node_at(w, d).parent.index; p != 0; p = node_at(w, p).parent.index do if p == i {found = true; break}
      if !found do return testing.expectf(t, false, "node %d in %d's range is no descendant", d, i)
      if w.topo_first[node_at(w, d).parent.index] >= k do return testing.expectf(t, false, "node %d before its parent", d)
    }
  }
  return true
}

@(test)
test_append_leaf_matches_rebuild :: proc(t: ^testing.T) {
  w: World
  init(&w, 4)
  defer shutdown(&w)
  live: [dynamic]NodeHandle
  defer delete(live)
  r := rand.create(42)
  context.random_generator = rand.default_random_generator(&r)
  last := w.root
  fast_spawns := 0
  for step in 0 ..< 1000 {
    for _ in 0 ..< 1 + rand.int_max(8) {
      switch rand.int_max(10) {
      case 0 ..= 3:
        stale := w.tree_stale
        h := node_create(&w, position = {rand.float32(), 0, 0})
        if !stale && !w.tree_stale do fast_spawns += 1
        append(&live, h)
        last = h
      case 4 ..= 5:
        h := node_create(&w, position = {0, rand.float32(), 0}, parent = last)
        append(&live, h)
        last = h
      case 6:
        if len(live) == 0 do continue
        h := node_create(&w, parent = live[rand.int_max(len(live))])
        append(&live, h)
      case 7:
        if len(live) < 2 do continue
        set_parent(&w, live[rand.int_max(len(live))], live[rand.int_max(len(live))])
      case 8:
        if len(live) == 0 do continue
        transform(&w, live[rand.int_max(len(live))]).position.z += 1
      case 9:
        if len(live) == 0 do continue
        k := rand.int_max(len(live))
        node_destroy(&w, live[k])
        unordered_remove(&live, k)
      }
    }
    update(&w)
    n := 0
    for h in live do if containers.slots_valid(&w.slots, h) {live[n] = h; n += 1}
    resize(&live, n)
    if !check_topo(t, &w) do return
    // a full rebuild and a full walk agree on every world matrix
    want := make([]matrix[4, 4]f32, w.slots.high_water, context.temp_allocator)
    for h in live do want[h.index] = world_matrix(&w, h)
    w.tree_stale = true
    for h in live do cache_at(&w, h.index).is_dirty = true
    for h in live do append(&w.touched, h.index)
    update(&w)
    for h in live do if !near(world_matrix(&w, h), want[h.index]) {
      testing.expectf(t, false, "step %d: node %d differs after a rebuild", step, h.index)
      return
    }
    free_all(context.temp_allocator)
  }
  testing.expect(t, fast_spawns > 100, "the leaf fast path ran")
}

@(test)
test_quiet_update_allocates_nothing :: proc(t: ^testing.T) {
  w: World
  init(&w)
  defer shutdown(&w)
  for _ in 0 ..< 1000 do node_create(&w)
  update(&w)
  update(&w)
  track: mem.Tracking_Allocator
  mem.tracking_allocator_init(&track, context.temp_allocator)
  defer mem.tracking_allocator_destroy(&track)
  context.temp_allocator = mem.tracking_allocator(&track)
  update(&w)
  testing.expect_value(t, len(changes(&w)), 0)
  testing.expect_value(t, track.total_allocation_count, 0)
}

@(test)
test_spawns_between_updates_grow_topo_by_page :: proc(t: ^testing.T) {
  N :: 3 * PAGE_SIZE
  w: World
  init(&w, 2)
  defer shutdown(&w)
  update(&w)
  moves := 0
  data := raw_data(w.topo_first)
  parent := w.root
  handles := make([]NodeHandle, N)
  defer delete(handles)
  for &h, i in handles {
    // a chain, then leaves under the root: both end the topo order
    h = node_create(&w, position = {1, 0, 0}, parent = parent if i < N / 2 else w.root)
    if i < N / 2 do parent = h
    if raw_data(w.topo_first) != data {
      moves += 1
      data = raw_data(w.topo_first)
    }
  }
  testing.expect(t, !w.tree_stale, "spawns at the end of the order need no rebuild")
  testing.expectf(t, moves <= len(w.pages) + 1, "topo grew %d times for %d pages", moves, len(w.pages))
  update(&w)
  for h, i in handles {
    x := f32(i + 1) if i < N / 2 else 1
    if !testing.expectf(t, world_matrix(&w, h)[3].x == x, "node %d at %v", i, world_matrix(&w, h)[3].xyz) do return
  }
}
