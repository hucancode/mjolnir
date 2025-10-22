package world

import "../geometry"
import "../resources"
import "core:math"
import "core:log"
import "core:math/linalg"

NodeEntry :: struct {
  handle:   resources.Handle,
  position: [3]f32,
  tags:     NodeTagSet,
  bounds:   geometry.Aabb, // Transformed mesh AABB (or point-based for non-mesh nodes)
}

@(private)
node_entry_to_aabb :: proc(entry: NodeEntry) -> geometry.Aabb {
  // Use actual mesh bounds if available (non-zero)
  if .MESH in entry.tags && entry.bounds != {} {
    return entry.bounds
  }
  // For non-mesh nodes or nodes without actual mesh bounds, use point-based AABB
  radius :: 0.5
  return geometry.Aabb {
    min = entry.position - {radius, radius, radius},
    max = entry.position + {radius, radius, radius},
  }
}

@(private)
node_entry_to_point :: proc(entry: NodeEntry) -> [3]f32 {
  return entry.position
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

query_sphere :: proc(
  world: ^World,
  center: [3]f32,
  radius: f32,
  results: ^[dynamic]resources.Handle,
  tags_any: NodeTagSet = {},
  tags_all: NodeTagSet = {},
  tags_none: NodeTagSet = {},
) {
  clear(results)
  if world.node_octree.root == nil do return
  entries := make([dynamic]NodeEntry, 0)
  defer delete(entries)
  geometry.octree_query_sphere(&world.node_octree, center, radius, &entries)
  filter_by_tags(&entries, tags_any, tags_all, tags_none)
  for entry in entries {
    if linalg.distance(entry.position, center) <= radius {
      append(results, entry.handle)
    }
  }
}

query_cube :: proc(
  world: ^World,
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
  query_box(world, bounds, results, tags_any, tags_all, tags_none)
}

query_box :: proc(
  world: ^World,
  bounds: geometry.Aabb,
  results: ^[dynamic]resources.Handle,
  tags_any: NodeTagSet = {},
  tags_all: NodeTagSet = {},
  tags_none: NodeTagSet = {},
) {
  clear(results)
  if world.node_octree.root == nil do return
  entries := make([dynamic]NodeEntry, 0)
  defer delete(entries)
  geometry.octree_query_aabb(&world.node_octree, bounds, &entries)
  filter_by_tags(&entries, tags_any, tags_all, tags_none)
  for entry in entries {
    if geometry.aabb_contains_point(bounds, entry.position) {
      append(results, entry.handle)
    }
  }
}

query_disc :: proc(
  world: ^World,
  center: [3]f32,
  normal: [3]f32,
  radius: f32,
  results: ^[dynamic]resources.Handle,
  tags_any: NodeTagSet = {},
  tags_all: NodeTagSet = {},
  tags_none: NodeTagSet = {},
) {
  clear(results)
  if world.node_octree.root == nil do return
  entries := make([dynamic]NodeEntry, 0)
  defer delete(entries)
  geometry.octree_query_disc(
    &world.node_octree,
    center,
    normal,
    radius,
    &entries,
  )
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

query_fan :: proc(
  world: ^World,
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
  if world.node_octree.root == nil do return
  entries := make([dynamic]NodeEntry, 0)
  defer delete(entries)
  // Query sphere first to get candidates
  geometry.octree_query_sphere(&world.node_octree, origin, radius, &entries)
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

// Process pending octree updates - O(k) where k is number of changed nodes
process_octree_updates :: proc(world: ^World, rm: ^resources.Manager) {
  if len(world.octree_dirty_set) == 0 do return
  for handle, _ in world.octree_dirty_set {
    node := resources.get(world.nodes, handle)
    // Case 1: Node was deleted - remove from octree and entry map
    if node == nil || node.pending_deletion {
      if old_entry, exists := world.octree_entry_map[handle]; exists {
        geometry.octree_remove(&world.node_octree, old_entry)
        delete_key(&world.octree_entry_map, handle)
      }
      continue
    }
    // Case 2: Compute new entry from current node state
    new_position := node.transform.world_matrix[3].xyz
    new_tags := node.tags
    new_bounds := geometry.Aabb{}
    if .MESH in new_tags && rm != nil {
      if mesh_attachment, has_mesh := node.attachment.(MeshAttachment); has_mesh {
        if mesh := resources.get(rm.meshes, mesh_attachment.handle); mesh != nil {
          local_bounds := geometry.Aabb{min = mesh.aabb_min, max = mesh.aabb_max}
          new_bounds = geometry.aabb_transform(local_bounds, node.transform.world_matrix)
        }
      }
    }
    new_entry := NodeEntry{
      handle = handle,
      position = new_position,
      tags = new_tags,
      bounds = new_bounds,
    }
    // Case 3: Check if node already exists in octree
    old_entry, exists := world.octree_entry_map[handle]
    if exists {
      // Node exists - remove old and insert new
      geometry.octree_remove(&world.node_octree, old_entry)
    }
    // Insert new entry
    geometry.octree_insert(&world.node_octree, new_entry)
    world.octree_entry_map[handle] = new_entry
  }
  // Clear dirty set for next frame
  clear(&world.octree_dirty_set)
}
