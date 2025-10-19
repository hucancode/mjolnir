package geometry

import "core:mem"

Interval :: struct {
  start, end: int,
}

IntervalNode :: struct {
  interval:      Interval,
  max_end:       int,
  left, right:   ^IntervalNode,
  height:        int,
}

IntervalTree :: struct {
  root:      ^IntervalNode,
  allocator: mem.Allocator,
}

interval_tree_init :: proc(tree: ^IntervalTree, allocator := context.allocator) {
  tree.root = nil
  tree.allocator = allocator
}

interval_tree_destroy :: proc(tree: ^IntervalTree) {
  destroy_node(tree.root, tree.allocator)
  tree.root = nil
}

@(private)
destroy_node :: proc(node: ^IntervalNode, allocator: mem.Allocator) {
  if node == nil do return
  destroy_node(node.left, allocator)
  destroy_node(node.right, allocator)
  free(node, allocator)
}

@(private)
node_height :: proc(node: ^IntervalNode) -> int {
  return node.height if node != nil else 0
}

@(private)
node_balance :: proc(node: ^IntervalNode) -> int {
  return node_height(node.left) - node_height(node.right) if node != nil else 0
}

@(private)
update_node :: proc(node: ^IntervalNode) {
  if node == nil do return

  node.height = max(node_height(node.left), node_height(node.right)) + 1

  node.max_end = node.interval.end
  if node.left != nil do node.max_end = max(node.max_end, node.left.max_end)
  if node.right != nil do node.max_end = max(node.max_end, node.right.max_end)
}

@(private)
rotate_right :: proc(y: ^IntervalNode) -> ^IntervalNode {
  x := y.left
  t2 := x.right

  x.right = y
  y.left = t2

  update_node(y)
  update_node(x)

  return x
}

@(private)
rotate_left :: proc(x: ^IntervalNode) -> ^IntervalNode {
  y := x.right
  t2 := y.left

  y.left = x
  x.right = t2

  update_node(x)
  update_node(y)

  return y
}

interval_tree_insert :: proc(tree: ^IntervalTree, start: int, count: int = 1) {
  if count <= 0 do return
  new_interval := Interval{start, start + count - 1}
  // Collect all existing intervals
  intervals := make([dynamic]Interval, 0, tree.allocator)
  defer delete(intervals)
  collect_intervals(tree.root, &intervals)
  // Clear tree
  destroy_node(tree.root, tree.allocator)
  tree.root = nil
  // Add new interval to list
  append(&intervals, new_interval)
  // Sort intervals by start position
  // TODO: use slice.sort_proc
  for i in 0..<len(intervals) {
    for j in i+1..<len(intervals) {
      if intervals[i].start > intervals[j].start {
        intervals[i], intervals[j] = intervals[j], intervals[i]
      }
    }
  }
  // Merge overlapping/adjacent intervals
  merged := make([dynamic]Interval, 0, tree.allocator)
  defer delete(merged)
  if len(intervals) > 0 {
    current := intervals[0]
    for i in 1..<len(intervals) {
      if intervals[i].start <= current.end + 1 {
        // Merge intervals
        current.end = max(current.end, intervals[i].end)
      } else {
        // No overlap, add current and start new
        append(&merged, current)
        current = intervals[i]
      }
    }
    append(&merged, current)
  }
  // Rebuild tree with merged intervals
  for interval in merged {
    tree.root = insert_simple(tree.root, interval, tree.allocator)
  }
}

@(private)
insert_simple :: proc(node: ^IntervalNode, interval: Interval, allocator: mem.Allocator) -> ^IntervalNode {
  if node == nil {
    new_node := new(IntervalNode, allocator)
    new_node.interval = interval
    new_node.max_end = interval.end
    new_node.height = 1
    return new_node
  }
  if interval.start < node.interval.start {
    node.left = insert_simple(node.left, interval, allocator)
  } else {
    node.right = insert_simple(node.right, interval, allocator)
  }
  update_node(node)
  balance := node_balance(node)
  if balance > 1 && interval.start < node.left.interval.start {
    return rotate_right(node)
  }
  if balance < -1 && interval.start > node.right.interval.start {
    return rotate_left(node)
  }
  if balance > 1 && interval.start > node.left.interval.start {
    node.left = rotate_left(node.left)
    return rotate_right(node)
  }
  if balance < -1 && interval.start < node.right.interval.start {
    node.right = rotate_right(node.right)
    return rotate_left(node)
  }
  return node
}

@(private)
collect_intervals :: proc(node: ^IntervalNode, intervals: ^[dynamic]Interval) {
  if node == nil do return
  collect_intervals(node.left, intervals)
  append(intervals, node.interval)
  collect_intervals(node.right, intervals)
}

interval_tree_get_ranges :: proc(tree: ^IntervalTree, allocator := context.temp_allocator) -> []Interval {
  intervals := make([dynamic]Interval, 0, allocator)
  collect_intervals(tree.root, &intervals)
  return intervals[:]
}

interval_tree_clear :: proc(tree: ^IntervalTree) {
  destroy_node(tree.root, tree.allocator)
  tree.root = nil
}
