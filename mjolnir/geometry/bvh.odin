package geometry

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:sync"
import "core:thread"

// BVHNode is one 32-byte node of the depth-first node array. A leaf (count > 0) owns the primitives
// [offset, offset+count). An inner node (count == 0) has its left child at the next index and its
// right child at offset.
BVHNode :: struct {
  bounds: Aabb,
  offset: i32,
  count:  i32,
}

// BVH is a bounding volume hierarchy over items of type T. bounds[i] is the box of primitives[i];
// the caller moves bounds and calls bvh_refit.
BVH :: struct($T: typeid) {
  nodes:      [dynamic]BVHNode,
  primitives: [dynamic]T,
  bounds:     [dynamic]Aabb,
}

// bvh_destroy frees the memory held by bvh.
bvh_destroy :: proc(self: ^BVH($T)) {
  delete(self.nodes)
  delete(self.primitives)
  delete(self.bounds)
}

@(private = "file")
BVH_BINS :: 16
@(private = "file")
BVH_MAX_DEPTH :: 48 // deeper subtrees split by count, keeping traversal stacks bounded
@(private = "file")
BVH_STACK :: 64
@(private = "file")
PARALLEL_BUILD_THRESHOLD :: 1000
@(private = "file")
PARALLEL_TASK_THRESHOLD :: 250
@(private = "file")
PARALLEL_DEPTH_THRESHOLD :: 4

@(private = "file")
BuildPrim :: struct {
  bounds: Aabb,
  index:  i32,
}

@(private = "file")
bin_of :: #force_inline proc "contextless" (c, lo, scale: f32) -> int {
  return clamp(int((c - lo) * scale), 0, BVH_BINS - 1)
}

// Bounds of the prims and of their centers.
@(private = "file")
build_extents :: proc(prims: []BuildPrim) -> (bounds, centers: Aabb) {
  bounds, centers = AABB_UNDEFINED, AABB_UNDEFINED
  for &p in prims {
    c := aabb_center(p.bounds)
    bounds = aabb_union(bounds, p.bounds)
    centers.min = linalg.min(centers.min, c)
    centers.max = linalg.max(centers.max, c)
  }
  return
}

// Partitions prims in place around the cheapest binned SAH split; returns the left count.
@(private = "file")
build_split :: proc(prims: []BuildPrim, centers: Aabb, depth: i32) -> int {
  half := len(prims) / 2
  extent := centers.max - centers.min
  if depth >= BVH_MAX_DEPTH || max(extent.x, extent.y, extent.z) < 1e-4 do return half
  scale := [3]f32{}
  bin_bounds: [3][BVH_BINS]Aabb
  bin_count: [3][BVH_BINS]i32
  for ax in 0 ..< 3 {
    if extent[ax] >= 1e-4 do scale[ax] = BVH_BINS / extent[ax]
    for &b in bin_bounds[ax] do b = AABB_UNDEFINED
  }
  for &p in prims {
    c := aabb_center(p.bounds)
    #unroll for ax in 0 ..< 3 {
      k := bin_of(c[ax], centers.min[ax], scale[ax])
      bin_count[ax][k] += 1
      bin_bounds[ax][k] = aabb_union(bin_bounds[ax][k], p.bounds)
    }
  }
  best_cost := f32(F32_MAX)
  best_axis, best_bin := -1, 0
  for ax in 0 ..< 3 {
    if scale[ax] == 0 do continue
    right_area: [BVH_BINS]f32 // area of bins (i, BVH_BINS)
    acc := AABB_UNDEFINED
    for i := BVH_BINS - 1; i > 0; i -= 1 {
      acc = aabb_union(acc, bin_bounds[ax][i])
      right_area[i] = aabb_surface_area(acc)
    }
    left := AABB_UNDEFINED
    n_left: i32
    n_right := i32(len(prims))
    for i in 0 ..< BVH_BINS - 1 {
      left = aabb_union(left, bin_bounds[ax][i])
      n_left += bin_count[ax][i]
      n_right -= bin_count[ax][i]
      if n_left == 0 || n_right == 0 do continue
      cost := aabb_surface_area(left) * f32(n_left) + right_area[i + 1] * f32(n_right)
      if cost < best_cost do best_cost, best_axis, best_bin = cost, ax, i
    }
  }
  if best_axis < 0 do return half
  lo, s := centers.min[best_axis], scale[best_axis]
  split := 0
  for j in 0 ..< len(prims) {
    if bin_of(aabb_center(prims[j].bounds)[best_axis], lo, s) <= best_bin {
      prims[split], prims[j] = prims[j], prims[split]
      split += 1
    }
  }
  return split
}

// Appends the subtree over prims (first primitive slot is base) to nodes in depth-first order.
@(private = "file")
build_range :: proc(prims: []BuildPrim, base, max_leaf, depth: i32, nodes: ^[dynamic]BVHNode) {
  bounds, centers := build_extents(prims)
  me := len(nodes)
  if i32(len(prims)) <= max_leaf {
    append(nodes, BVHNode{bounds, base, i32(len(prims))})
    return
  }
  append(nodes, BVHNode{bounds = bounds})
  mid := build_split(prims, centers, depth)
  build_range(prims[:mid], base, max_leaf, depth + 1, nodes)
  nodes[me].offset = i32(len(nodes))
  build_range(prims[mid:], base + i32(mid), max_leaf, depth + 1, nodes)
}

// bvh_build rebuilds bvh over items with their bounds; leaves hold at most max_leaf_size items.
bvh_build :: proc(self: ^BVH($T), items: []T, bounds: []Aabb, max_leaf_size: i32 = 4) {
  assert(len(items) == len(bounds))
  prims := build_prims(items, bounds)
  defer delete(prims)
  clear(&self.nodes)
  reserve(&self.nodes, len(items))
  if len(items) > 0 do build_range(prims, 0, max_leaf_size, 0, &self.nodes)
  bvh_gather(self, items, prims)
}

@(private = "file")
build_prims :: proc(items: []$T, bounds: []Aabb) -> []BuildPrim {
  prims := make([]BuildPrim, len(items))
  for &p, i in prims do p = {bounds[i], i32(i)}
  return prims
}

// Stores items and bounds in the order the build left prims.
@(private = "file")
bvh_gather :: proc(self: ^BVH($T), items: []T, prims: []BuildPrim) {
  resize(&self.primitives, len(items))
  resize(&self.bounds, len(items))
  for p, i in prims {
    self.primitives[i] = items[p.index]
    self.bounds[i] = p.bounds
  }
}

@(private = "file")
BuildTask :: struct {
  prims:    []BuildPrim,
  base:     i32,
  max_leaf: i32,
  depth:    i32,
  pool:     ^thread.Pool,
  nodes:    [dynamic]BVHNode, // heap allocated: tasks run on threads that do not share the caller's allocator
  done:     bool,
}

// Builds a subtree into task.nodes (offsets relative to that array); the top levels fork onto the pool.
@(private = "file")
build_task :: proc(task: ^BuildTask) {
  defer sync.atomic_store(&task.done, true)
  task.nodes.allocator = runtime.heap_allocator()
  if task.depth >= PARALLEL_DEPTH_THRESHOLD || len(task.prims) < PARALLEL_TASK_THRESHOLD {
    build_range(task.prims, task.base, task.max_leaf, task.depth, &task.nodes)
    return
  }
  bounds, centers := build_extents(task.prims)
  mid := build_split(task.prims, centers, task.depth)
  left := task^
  left.prims, left.depth, left.nodes, left.done = task.prims[:mid], task.depth + 1, nil, false
  right := task^
  right.prims, right.base, right.depth, right.nodes, right.done =
    task.prims[mid:], task.base + i32(mid), task.depth + 1, nil, false
  thread.pool_add_task(task.pool, runtime.nil_allocator(), proc(t: thread.Task) {
    build_task((^BuildTask)(t.data))
  }, &left, 0)
  build_task(&right)
  for !sync.atomic_load(&left.done) {
    if queued, ok := thread.pool_pop_waiting(task.pool); ok {
      thread.pool_do_work(task.pool, queued)
    } else {
      intrinsics.cpu_relax()
    }
  }
  append(&task.nodes, BVHNode{bounds = bounds, offset = 1 + i32(len(left.nodes))})
  for sub in ([2]^BuildTask{&left, &right}) {
    at := i32(len(task.nodes))
    for n in sub.nodes {
      n := n
      if n.count == 0 do n.offset += at
      append(&task.nodes, n)
    }
    delete(sub.nodes)
  }
}

// bvh_build_parallel builds the BVH on the thread pool, falling back to a sequential build for small inputs.
bvh_build_parallel :: proc(
  self: ^BVH($T),
  items: []T,
  bounds: []Aabb,
  thread_pool: ^thread.Pool,
  max_leaf_size: i32 = 4,
  parallel_threshold: int = PARALLEL_BUILD_THRESHOLD,
) {
  if len(items) < parallel_threshold || thread_pool == nil || !thread_pool.is_running || len(thread_pool.threads) == 0 {
    bvh_build(self, items, bounds, max_leaf_size)
    return
  }
  assert(len(items) == len(bounds))
  prims := build_prims(items, bounds)
  defer delete(prims)
  root := BuildTask {
    prims    = prims,
    max_leaf = max_leaf_size,
    pool     = thread_pool,
  }
  build_task(&root)
  clear(&self.nodes)
  append(&self.nodes, ..root.nodes[:])
  delete(root.nodes)
  bvh_gather(self, items, prims)
}

// bvh_refit recomputes node bounds bottom-up after bounds changed, keeping the tree shape.
bvh_refit :: proc(self: ^BVH($T)) {
  #no_bounds_check for i := len(self.nodes) - 1; i >= 0; i -= 1 {
    node := &self.nodes[i]
    if node.count > 0 {
      node.bounds = AABB_UNDEFINED
      for b in self.bounds[node.offset:node.offset + node.count] do node.bounds = aabb_union(node.bounds, b)
    } else {
      node.bounds = aabb_union(self.nodes[i + 1].bounds, self.nodes[node.offset].bounds)
    }
  }
}

// bvh_query_aabb replaces results with the items whose bounds overlap query_bounds.
bvh_query_aabb :: proc(self: ^BVH($T), query_bounds: Aabb, results: ^[dynamic]T) {
  clear(results)
  if len(self.nodes) == 0 do return
  stack: [BVH_STACK]i32
  top, i := 0, i32(0)
  for {
    node := &self.nodes[i]
    if aabb_intersects(node.bounds, query_bounds) {
      if node.count == 0 {
        stack[top] = node.offset
        top += 1
        i += 1
        continue
      }
      #no_bounds_check for j in node.offset ..< node.offset + node.count {
        if aabb_intersects(self.bounds[j], query_bounds) do append(results, self.primitives[j])
      }
    }
    if top == 0 do break
    top -= 1
    i = stack[top]
  }
}

// Slab test with a precomputed inverse direction; hit when near <= far, near <= max_dist and far >= 0.
@(private = "file")
ray_hits :: #force_inline proc "contextless" (origin, inv_dir: [3]f32, box: Aabb, max_dist: f32) -> bool {
  t_near, t_far := ray_aabb_intersection(origin, inv_dir, box)
  return t_near <= t_far && t_near <= max_dist && t_far >= 0
}

// bvh_query_ray replaces results with the items whose bounds the ray crosses within max_dist.
bvh_query_ray :: proc(self: ^BVH($T), ray: Ray, max_dist: f32, results: ^[dynamic]T) {
  clear(results)
  if len(self.nodes) == 0 do return
  // Near-zero components act as parallel to the slab: tiny, so the slab is crossed far away or never.
  inv_dir: [3]f32
  #unroll for ax in 0 ..< 3 {
    d := ray.direction[ax]
    inv_dir[ax] = 1 / (abs(d) < 1e-6 ? math.copy_sign(f32(1e-6), d) : d)
  }
  stack: [BVH_STACK]i32
  top, i := 0, i32(0)
  for {
    node := &self.nodes[i]
    if ray_hits(ray.origin, inv_dir, node.bounds, max_dist) {
      if node.count == 0 {
        stack[top] = node.offset
        top += 1
        i += 1
        continue
      }
      #no_bounds_check for j in node.offset ..< node.offset + node.count {
        if ray_hits(ray.origin, inv_dir, self.bounds[j], max_dist) do append(results, self.primitives[j])
      }
    }
    if top == 0 do break
    top -= 1
    i = stack[top]
  }
}

// RayHit is a ray query result: the primitive hit, the hit distance t, and whether anything was hit.
RayHit :: struct($T: typeid) {
  primitive: T,
  t:         f32,
  hit:       bool,
}

// BVHOverlapPair is a pair of overlapping primitives found by bvh_find_all_overlaps.
BVHOverlapPair :: struct($T: typeid) {
  a: T,
  b: T,
}

// BVHCrossPair is a pair of overlapping primitives found by bvh_find_cross_overlaps.
BVHCrossPair :: struct($T: typeid, $U: typeid) {
  a: T,
  b: U,
}

// bvh_find_all_overlaps finds all overlapping pairs within a single BVH in O(N + K).
bvh_find_all_overlaps :: proc(self: ^BVH($T), results: ^[dynamic]BVHOverlapPair(T)) {
  clear(results)
  if len(self.nodes) == 0 do return
  overlaps(self, self, 0, 0, true, (^[dynamic]BVHCrossPair(T, T))(results))
}

// bvh_find_cross_overlaps finds all overlapping pairs between two BVHs in O(N + M + K).
bvh_find_cross_overlaps :: proc(self: ^BVH($T), bvh_b: ^BVH($U), results: ^[dynamic]BVHCrossPair(T, U)) {
  clear(results)
  if len(self.nodes) == 0 || len(bvh_b.nodes) == 0 do return
  overlaps(self, bvh_b, 0, 0, false, results)
}

// Tree-vs-tree descent; the larger node splits first. With same, a is b and each pair is reported once.
@(private = "file")
overlaps :: proc(a: ^BVH($T), b: ^BVH($U), ia, ib: i32, same: bool, out: ^[dynamic]BVHCrossPair(T, U)) {
  na, nb := &a.nodes[ia], &b.nodes[ib]
  if !aabb_intersects(na.bounds, nb.bounds) do return
  a_leaf, b_leaf := na.count > 0, nb.count > 0
  if a_leaf && b_leaf {
    #no_bounds_check for i in na.offset ..< na.offset + na.count {
      box := a.bounds[i]
      for j in (i + 1 if same && ia == ib else nb.offset) ..< nb.offset + nb.count {
        if aabb_intersects(box, b.bounds[j]) do append(out, BVHCrossPair(T, U){a.primitives[i], b.primitives[j]})
      }
    }
  } else if same && ia == ib {
    l, r := ia + 1, na.offset
    overlaps(a, b, l, l, true, out)
    overlaps(a, b, r, r, true, out)
    overlaps(a, b, l, r, true, out)
  } else if b_leaf || (!a_leaf && aabb_surface_area(na.bounds) >= aabb_surface_area(nb.bounds)) {
    overlaps(a, b, ia + 1, ib, same, out)
    overlaps(a, b, na.offset, ib, same, out)
  } else {
    overlaps(a, b, ia, ib + 1, same, out)
    overlaps(a, b, ia, nb.offset, same, out)
  }
}
