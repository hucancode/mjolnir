---
title: Geometry
---

Pure math + spatial-acceleration data structures. Layer 1, no
dependencies on the rest of the engine and no Vulkan. Used by
`physics`, `render`, `world`, `animation` and `navigation`.

## Scope

Shapes (AABB, OBB, sphere) and their intersection and
distance tests, `Ray`, transform decomposition,
projection matrices, frustum extraction, and acceleration structures
(BVH, octree). Render's vertex format, primitive builders and OBJ loader live in
`render/mesh`; recast's polygon helpers live in `navigation/recast`.

## Acceleration structures

- **BVH** — primary broadphase. Generic over element type with a
  user-supplied bounds proc, built via SAH binning (optionally in
  parallel). Supports refit, AABB and ray queries, and self/cross overlap
  pair finding. Used by the physics broadphase and spatial queries.
- **Octree** — used where queries are dominated by point/sphere lookups
  in a large static set; cheaper to query than a BVH when the workload
  is heavily point-sample dominated.

## Transform

`decompose_matrix` splits an affine matrix into position, rotation and
scale. The scene-graph `Transform` (dirty bit, cached matrices) lives in
`world`.
