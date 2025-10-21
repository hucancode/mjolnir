package world

import "../geometry"
import "../resources"
import "core:math"
import "core:math/linalg"

NodeEntry :: struct {
  handle:   resources.Handle,
  position: [3]f32,
  tags:     NodeTagSet,
}

// Tracked position for incremental updates
NodeCacheEntry :: struct {
  position: [3]f32,
  tags:     NodeTagSet,
}

AOEOctree :: struct {
  tree:            geometry.Octree(NodeEntry),
  node_cache:      map[resources.Handle]NodeCacheEntry,
  rebuild_pending: bool,
}

aoe_init :: proc(aoe: ^AOEOctree, bounds: geometry.Aabb) {
  geometry.octree_init(&aoe.tree, bounds, max_depth = 6, max_items = 16)
  aoe.tree.bounds_func = aoe_node_entry_to_aabb
  aoe.tree.point_func = aoe_node_entry_to_point
  aoe.node_cache = make(map[resources.Handle]NodeCacheEntry)
  aoe.rebuild_pending = false
}

aoe_destroy :: proc(aoe: ^AOEOctree) {
  geometry.octree_destroy(&aoe.tree)
  delete(aoe.node_cache)
}

@(private)
aoe_node_entry_to_aabb :: proc(entry: NodeEntry) -> geometry.Aabb {
  radius :: 0.5
  return geometry.Aabb {
    min = entry.position - {radius, radius, radius},
    max = entry.position + {radius, radius, radius},
  }
}

@(private)
aoe_node_entry_to_point :: proc(entry: NodeEntry) -> [3]f32 {
  return entry.position
}

aoe_insert :: proc(
  aoe: ^AOEOctree,
  handle: resources.Handle,
  position: [3]f32,
  tags: NodeTagSet = {},
) -> bool {
  entry := NodeEntry {
    handle   = handle,
    position = position,
    tags     = tags,
  }
  return geometry.octree_insert(&aoe.tree, entry)
}

aoe_remove :: proc(
  aoe: ^AOEOctree,
  handle: resources.Handle,
  position: [3]f32,
  tags: NodeTagSet = {},
) -> bool {
  entry := NodeEntry {
    handle   = handle,
    position = position,
    tags     = tags,
  }
  return geometry.octree_remove(&aoe.tree, entry)
}

aoe_update :: proc(
  aoe: ^AOEOctree,
  handle: resources.Handle,
  old_position: [3]f32,
  new_position: [3]f32,
  tags: NodeTagSet = {},
) -> bool {
  old_entry := NodeEntry {
    handle   = handle,
    position = old_position,
  }
  new_entry := NodeEntry {
    handle   = handle,
    position = new_position,
    tags     = tags,
  }
  return geometry.octree_update(&aoe.tree, old_entry, new_entry)
}

@(private)
filter_by_tags :: proc(
  entries: ^[dynamic]NodeEntry,
  tags_any: NodeTagSet = {},
  tags_all: NodeTagSet = {},
  tags_none: NodeTagSet = {},
) {
  i := 0
  for i < len(entries) {
    entry := entries[i]
    pass := true

    // Filter by tags_any: must have at least one of these tags
    if tags_any != {} && (entry.tags & tags_any) == {} {
      pass = false
    }

    // Filter by tags_all: must have all of these tags
    if pass && tags_all != {} && (entry.tags & tags_all) != tags_all {
      pass = false
    }

    // Filter by tags_none: must not have any of these tags
    if pass && tags_none != {} && (entry.tags & tags_none) != {} {
      pass = false
    }

    if !pass {
      unordered_remove(entries, i)
    } else {
      i += 1
    }
  }
}

aoe_query_sphere :: proc(
  aoe: ^AOEOctree,
  center: [3]f32,
  radius: f32,
  results: ^[dynamic]resources.Handle,
  tags_any: NodeTagSet = {},
  tags_all: NodeTagSet = {},
  tags_none: NodeTagSet = {},
) {
  clear(results)
  if aoe.tree.root == nil do return

  entries := make([dynamic]NodeEntry, 0)
  defer delete(entries)

  geometry.octree_query_sphere(&aoe.tree, center, radius, &entries)
  filter_by_tags(&entries, tags_any, tags_all, tags_none)

  for entry in entries {
    if linalg.distance(entry.position, center) <= radius {
      append(results, entry.handle)
    }
  }
}

aoe_query_cube :: proc(
  aoe: ^AOEOctree,
  center: [3]f32,
  half_extents: [3]f32,
  results: ^[dynamic]resources.Handle,
  tags_any: NodeTagSet = {},
  tags_all: NodeTagSet = {},
  tags_none: NodeTagSet = {},
) {
  bounds := geometry.Aabb {
    min = center - half_extents,
    max = center + half_extents,
  }
  aoe_query_box(aoe, bounds, results, tags_any, tags_all, tags_none)
}

aoe_query_box :: proc(
  aoe: ^AOEOctree,
  bounds: geometry.Aabb,
  results: ^[dynamic]resources.Handle,
  tags_any: NodeTagSet = {},
  tags_all: NodeTagSet = {},
  tags_none: NodeTagSet = {},
) {
  clear(results)
  if aoe.tree.root == nil do return

  entries := make([dynamic]NodeEntry, 0)
  defer delete(entries)

  geometry.octree_query_aabb(&aoe.tree, bounds, &entries)
  filter_by_tags(&entries, tags_any, tags_all, tags_none)

  for entry in entries {
    if geometry.aabb_contains_point(bounds, entry.position) {
      append(results, entry.handle)
    }
  }
}

aoe_query_disc :: proc(
  aoe: ^AOEOctree,
  center: [3]f32,
  normal: [3]f32,
  radius: f32,
  results: ^[dynamic]resources.Handle,
  tags_any: NodeTagSet = {},
  tags_all: NodeTagSet = {},
  tags_none: NodeTagSet = {},
) {
  clear(results)
  if aoe.tree.root == nil do return

  entries := make([dynamic]NodeEntry, 0)
  defer delete(entries)

  geometry.octree_query_disc(&aoe.tree, center, normal, radius, &entries)
  filter_by_tags(&entries, tags_any, tags_all, tags_none)

  norm_normal := linalg.normalize(normal)
  for entry in entries {
    to_point := entry.position - center
    dist_along_normal := linalg.dot(to_point, norm_normal)
    if math.abs(dist_along_normal) > 0.1 do continue

    projection := to_point - norm_normal * dist_along_normal
    if linalg.length(projection) <= radius {
      append(results, entry.handle)
    }
  }
}

aoe_query_fan :: proc(
  aoe: ^AOEOctree,
  origin: [3]f32,
  direction: [3]f32,
  radius: f32,
  angle: f32,
  results: ^[dynamic]resources.Handle,
  tags_any: NodeTagSet = {},
  tags_all: NodeTagSet = {},
  tags_none: NodeTagSet = {},
) {
  clear(results)
  if aoe.tree.root == nil do return

  entries := make([dynamic]NodeEntry, 0)
  defer delete(entries)

  // Query sphere first to get candidates
  geometry.octree_query_sphere(&aoe.tree, origin, radius, &entries)
  filter_by_tags(&entries, tags_any, tags_all, tags_none)

  norm_direction := linalg.normalize(direction)
  cos_half_angle := math.cos(angle * 0.5)

  for entry in entries {
    to_point := entry.position - origin
    dist := linalg.length(to_point)

    if dist > radius || dist < 0.0001 do continue

    dir_to_point := to_point / dist
    dot_product := linalg.dot(dir_to_point, norm_direction)

    if dot_product >= cos_half_angle {
      append(results, entry.handle)
    }
  }
}

aoe_mark_for_rebuild :: proc(aoe: ^AOEOctree) {
  aoe.rebuild_pending = true
}

// Incrementally update the octree based on node movements
aoe_update_from_world :: proc(aoe: ^AOEOctree, world: ^World) {
  // First frame: do full rebuild
  if len(aoe.node_cache) == 0 {
    aoe_rebuild_from_world(aoe, world)
    return
  }

  // Incremental updates for subsequent frames
  for i in 0 ..< len(world.nodes.entries) {
    entry := &world.nodes.entries[i]
    if !entry.active do continue

    node := &entry.item
    handle := resources.Handle {
      index      = u32(i),
      generation = entry.generation,
    }
    new_position := node.transform.world_matrix[3].xyz
    new_tags := node.tags

    // Check if node is in cache
    cached, in_cache := aoe.node_cache[handle]

    if node.pending_deletion {
      // Remove deleted nodes
      if in_cache {
        old_entry := NodeEntry {
          handle   = handle,
          position = cached.position,
          tags     = cached.tags,
        }
        geometry.octree_remove(&aoe.tree, old_entry)
        delete_key(&aoe.node_cache, handle)
      }
      continue
    }

    if in_cache {
      // Update existing node if position or tags changed
      position_changed := cached.position != new_position
      tags_changed := cached.tags != new_tags

      if position_changed || tags_changed {
        // Remove from old position
        old_entry := NodeEntry {
          handle   = handle,
          position = cached.position,
          tags     = cached.tags,
        }
        geometry.octree_remove(&aoe.tree, old_entry)

        // Insert at new position
        new_entry := NodeEntry {
          handle   = handle,
          position = new_position,
          tags     = new_tags,
        }
        geometry.octree_insert(&aoe.tree, new_entry)

        // Update cache
        aoe.node_cache[handle] = NodeCacheEntry {
          position = new_position,
          tags     = new_tags,
        }
      }
    } else {
      // New node: insert and cache
      new_entry := NodeEntry {
        handle   = handle,
        position = new_position,
        tags     = new_tags,
      }
      geometry.octree_insert(&aoe.tree, new_entry)
      aoe.node_cache[handle] = NodeCacheEntry {
        position = new_position,
        tags     = new_tags,
      }
    }
  }
}

// Full rebuild - only used on first frame or when explicitly requested
aoe_rebuild_from_world :: proc(aoe: ^AOEOctree, world: ^World) {
  // Clear existing octree
  bounds :=
    aoe.tree.root.bounds if aoe.tree.root != nil else geometry.Aabb{min = {-1000, -1000, -1000}, max = {1000, 1000, 1000}}
  geometry.octree_destroy(&aoe.tree)
  geometry.octree_init(&aoe.tree, bounds, max_depth = 6, max_items = 16)
  aoe.tree.bounds_func = aoe_node_entry_to_aabb
  aoe.tree.point_func = aoe_node_entry_to_point

  // Clear and rebuild cache
  clear(&aoe.node_cache)

  // Insert all active nodes
  for i in 0 ..< len(world.nodes.entries) {
    entry := &world.nodes.entries[i]
    if !entry.active || entry.item.pending_deletion do continue

    node := &entry.item
    handle := resources.Handle {
      index      = u32(i),
      generation = entry.generation,
    }
    position := node.transform.world_matrix[3].xyz

    node_entry := NodeEntry {
      handle   = handle,
      position = position,
      tags     = node.tags,
    }
    geometry.octree_insert(&aoe.tree, node_entry)

    // Cache position
    aoe.node_cache[handle] = NodeCacheEntry {
      position = position,
      tags     = node.tags,
    }
  }

  aoe.rebuild_pending = false
}
