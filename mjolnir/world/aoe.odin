package world

import "../geometry"
import "../resources"
import "core:math/linalg"

NodeEntry :: struct {
  handle: resources.Handle,
  position: [3]f32,
}

AOEOctree :: struct {
  tree: geometry.Octree(NodeEntry),
}

aoe_init :: proc(aoe: ^AOEOctree, bounds: geometry.Aabb) {
  geometry.octree_init(&aoe.tree, bounds, max_depth = 6, max_items = 16)
  aoe.tree.bounds_func = aoe_node_entry_to_aabb
  aoe.tree.point_func = aoe_node_entry_to_point
}

aoe_destroy :: proc(aoe: ^AOEOctree) {
  geometry.octree_destroy(&aoe.tree)
}

@(private)
aoe_node_entry_to_aabb :: proc(entry: NodeEntry) -> geometry.Aabb {
  radius :: 0.5
  return geometry.Aabb{
    min = entry.position - {radius, radius, radius},
    max = entry.position + {radius, radius, radius},
  }
}

@(private)
aoe_node_entry_to_point :: proc(entry: NodeEntry) -> [3]f32 {
  return entry.position
}

aoe_insert :: proc(aoe: ^AOEOctree, handle: resources.Handle, position: [3]f32) -> bool {
  entry := NodeEntry{handle = handle, position = position}
  return geometry.octree_insert(&aoe.tree, entry)
}

aoe_remove :: proc(aoe: ^AOEOctree, handle: resources.Handle, position: [3]f32) -> bool {
  entry := NodeEntry{handle = handle, position = position}
  return geometry.octree_remove(&aoe.tree, entry)
}

aoe_update :: proc(aoe: ^AOEOctree, handle: resources.Handle, old_position: [3]f32, new_position: [3]f32) -> bool {
  old_entry := NodeEntry{handle = handle, position = old_position}
  new_entry := NodeEntry{handle = handle, position = new_position}
  return geometry.octree_update(&aoe.tree, old_entry, new_entry)
}

aoe_query_sphere :: proc(
  aoe: ^AOEOctree,
  center: [3]f32,
  radius: f32,
  results: ^[dynamic]resources.Handle,
) {
  entries := make([dynamic]NodeEntry, 0)
  defer delete(entries)
  geometry.octree_query_sphere(&aoe.tree, center, radius, &entries)
  clear(results)
  for entry in entries {
    append(results, entry.handle)
  }
}

aoe_query_box :: proc(
  aoe: ^AOEOctree,
  bounds: geometry.Aabb,
  results: ^[dynamic]resources.Handle,
) {
  entries := make([dynamic]NodeEntry, 0)
  defer delete(entries)
  geometry.octree_query_aabb(&aoe.tree, bounds, &entries)
  clear(results)
  for entry in entries {
    append(results, entry.handle)
  }
}

aoe_query_disc :: proc(
  aoe: ^AOEOctree,
  center: [3]f32,
  normal: [3]f32,
  radius: f32,
  results: ^[dynamic]resources.Handle,
) {
  entries := make([dynamic]NodeEntry, 0)
  defer delete(entries)
  geometry.octree_query_disc(&aoe.tree, center, normal, radius, &entries)
  clear(results)
  for entry in entries {
    append(results, entry.handle)
  }
}
