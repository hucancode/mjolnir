---
title: Geometry
---

Pure math + spatial-acceleration data structures. Layer 1, no
dependencies on the rest of the engine and no Vulkan. Used by
`physics`, `render`, `world`, `animation` and `navigation`.

## Scope

Shapes (AABB, triangle, sphere, disc) and their intersection and
distance tests, `Ray`, transform decomposition,
projection matrices, frustum extraction, and acceleration structures
(BVH, octree). Render's vertex format and primitive builders live in
`render/mesh`; recast's polygon helpers live in `navigation/recast`.

## Acceleration structures

- **BVH** — primary broadphase. Generic over element type with a
  user-supplied bounds proc, built via SAH binning. Supports incremental
  insertion and refit; full rebuild only when a kill-count threshold
  trips. Used by physics broadphase, render visibility culling, and
  raycast queries.
- **Octree** — used where queries are dominated by point/sphere lookups
  in a large static set; cheaper to query than a BVH when the workload
  is heavily point-sample dominated.

## Transform

`Transform{position, rotation, scale}` + a dirty bit + cached
local/world matrices. `update_local` and `update_world` rebuild lazily
during the scene-graph traversal — nothing recomputes unless something
upstream moved.

## OBJ loading

`load_obj(path, scale)` returns an `ObjMesh{positions, indices}`
(faces fan-triangulated); free it with `obj_mesh_destroy`. Hand it to
`render/mesh.from_triangles` for a render mesh or to
`navigation.append_triangles` for a navmesh.
