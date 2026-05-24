---
title: Geometry
---

Pure math + spatial-acceleration data structures + vertex formats +
OBJ loader. Layer 1, no dependencies on the rest of the engine. Used
by `physics`, `render`, `world`, and `navigation`.

## Scope

Shapes (AABB / OBB / triangle / sphere / disc), the vertex formats the
GPU pipeline expects, transform decomposition, frustum extraction, and
acceleration structures — BVH, octree, interval tree. Also the OBJ
loader, since it deals with raw `Geometry`.

## Acceleration structures

- **BVH** — primary broadphase. Generic over element type with a
  user-supplied bounds proc, built via SAH binning. Supports incremental
  insertion and refit; full rebuild only when a kill-count threshold
  trips. Used by physics broadphase, render visibility culling, and
  raycast queries.
- **Octree** — used where queries are dominated by point/sphere lookups
  in a large static set; cheaper to query than a BVH when the workload
  is heavily point-sample dominated.
- **Interval tree** — auto-merging set of integer ranges. Backs streaming
  allocators that need "what ranges are free / occupied" without storing
  every element.

## Transform

`Transform{position, rotation, scale}` + a dirty bit + cached
local/world matrices. `update_local` and `update_world` rebuild lazily
during the scene-graph traversal — nothing recomputes unless something
upstream moved.

## Vertex formats

`Vertex` (position, normal, color, uv, tangent) and `SkinningData`
(joints + weights) are bit-for-bit what the GPU pipelines consume; the
matching `vk.VertexInputBindingDescription` lives next to them so the
two never drift.
