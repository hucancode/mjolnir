# `mjolnir/geometry` — API Reference

Layer 1. Pure math + spatial-acceleration data structures + vertex formats +
OBJ loader. Used by `physics`, `render`, `world`, `navigation`.

## Vertex formats

```odin
Vertex :: struct {
  position: [3]f32,
  normal:   [3]f32,
  color:    [4]f32,
  uv:       [2]f32,
  tangent:  [4]f32,   // xyz = tangent, w = handedness
}

SkinningData :: struct {
  joints:  [4]u32,
  weights: [4]f32,
}

Vertex2D :: struct {
  pos:        [2]f32,
  uv:         [2]f32,
  color:      [4]u8,
  texture_id: u32,
}
```

Vulkan binding/attribute descriptions exposed as constants:
`VERTEX_BINDING_DESCRIPTION`, `VERTEX_ATTRIBUTE_DESCRIPTIONS`,
`VERTEX2D_BINDING_DESCRIPTION`, `VERTEX2D_ATTRIBUTE_DESCRIPTIONS`.

## Geometry

```odin
Geometry :: struct {
  vertices:  []Vertex,
  skinnings: []SkinningData,    // optional
  indices:   []u32,
  aabb:      Aabb,
}

Triangle :: struct { v0, v1, v2: [3]f32 }
Sphere   :: struct { center: [3]f32, radius: f32 }
Disc     :: struct { center: [3]f32, normal: [3]f32, radius: f32 }
Primitive :: union { Triangle, Sphere, Disc }
```

**Builders** (all return `Geometry`):

| Proc | Args | Notes |
|---|---|---|
| `make_geometry` | `vertices, indices, skinnings = nil` | Auto-fills tangents if missing. |
| `make_cube` | `color = {1,1,1,1}, random_colors = false` | 24 verts. |
| `make_triangle` | same | 3 verts. |
| `make_quad` | same | XZ plane (4 verts). |
| `make_billboard_quad` | same | XY plane (4 verts). |
| `make_sphere` | `segments=16, rings=16, radius=1, color, random_colors` | UV sphere. |
| `make_cone` | `segments=32, height=2, radius=1, color, random_colors` | |
| `make_capsule` | `segments=16, rings=16, height=2, radius=1, color, random_colors` | Hemis + cylinder. |
| `make_torus` | `segments=16, rings=16, major=1, minor=0.3, color, random_colors` | |
| `make_cylinder` | `segments=32, height=2, radius=1, color, random_colors` | With caps. |
| `make_fullscreen_triangle` | `color = {1,1,1,1}` | For directional light volume / fullscreen passes. |

**Cleanup:** `delete_geometry(g: Geometry)`.

**Primitive bounds / hit-tests:**

```odin
triangle_bounds       (tri: Triangle) -> Aabb
sphere_bounds         (s: Sphere)     -> Aabb
disc_bounds           (d: Disc)       -> Aabb
primitive_bounds      (p: Primitive)  -> Aabb
ray_triangle_intersection (ray, tri, max_t = F32_MAX) -> (hit: bool, t: f32)
ray_sphere_intersection   (ray, sphere, max_t = F32_MAX) -> (bool, f32)
```

## AABB / OBB

```odin
Aabb :: struct { min, max: [3]f32 }
Obb  :: struct { center: [3]f32, half_extents: [3]f32, rotation: quaternion128 }

AABB_UNDEFINED  // sentinel — min/max swapped, used to start "union over set"
```

**AABB:**

```odin
aabb_from_vertices(vs: []Vertex) -> Aabb
aabb_union(a, b: Aabb) -> Aabb               // contextless
aabb_intersects(a, b: Aabb) -> bool          // contextless
aabb_contains(outer, inner: Aabb) -> bool
aabb_contains_approx(outer, inner: Aabb, epsilon: f32 = 1e-6) -> bool
aabb_contains_point(aabb, point) -> bool
aabb_center / aabb_size / aabb_surface_area / aabb_volume
aabb_sphere_intersects(aabb, center, radius) -> bool
distance_point_aabb(point, aabb) -> f32
ray_aabb_intersection(origin, inv_dir, aabb) -> (t_near, t_far: f32)
ray_aabb_intersection_far(origin, inv_dir, aabb) -> f32
min_vec3 / max_vec3
```

**OBB:**

```odin
obb_axes(obb) -> (x, y, z: [3]f32)
obb_to_aabb(obb) -> Aabb
obb_closest_point(obb, point) -> [3]f32
obb_contains_point(obb, point) -> bool
```

## Frustum

```odin
Plane   :: [4]f32                    // Ax+By+Cz+D=0, inward normal
Frustum :: struct { planes: [6]Plane }   // L, R, B, T, near, far
Ray     :: struct { origin, direction: [3]f32 }
```

```odin
make_frustum(view_proj: matrix[4,4]f32) -> Frustum
signed_distance_to_plane(p: Plane, point: [3]f32) -> f32
frustum_test_point  (f: Frustum, p: [3]f32) -> bool
frustum_test_aabb   (f: Frustum, aabb: Aabb) -> bool
frustum_test_sphere (f: Frustum, c: [3]f32, r: f32) -> bool
frustum_corners_world(view, proj: matrix[4,4]f32) -> [8][3]f32
aabb_transform(aabb: Aabb, m: matrix[4,4]f32) -> Aabb
```

## BVH

Generic BVH over any element type with a user-supplied bounds proc.

```odin
BVHNode :: struct {
  bounds:          Aabb,
  left_child, right_child: i32,
  primitive_start, primitive_count: i32,
}

BVH($T: typeid) :: struct {
  nodes:       [dynamic]BVHNode,
  primitives:  [dynamic]T,
  bounds_func: proc(t: T) -> Aabb,
  node_levels: [dynamic][dynamic]i32,   // for parallel refit
  max_depth:   i32,
}

RayHit($T: typeid) :: struct { primitive: T, t: f32, hit: bool }

BVHStats :: struct {
  node_count, leaf_count, internal_count: int,
  max_depth: i32, avg_depth: f32,
  max_leaf_size, min_leaf_size: i32,
}
```

| Proc | Signature | Purpose |
|---|---|---|
| `bvh_build` | `(bvh, items, max_leaf_size: i32 = 4)` | SAH-binned build. |
| `bvh_build_parallel` | `(bvh, items, max_leaf_size = 4, thread_count: int = 0)` | Threaded build (0 = use core count). |
| `bvh_destroy` | `(bvh)` | Free nodes + primitives. |
| `bvh_query_aabb` | `(bvh, query: Aabb, results: ^[dynamic]T)` | All primitives overlapping AABB. SIMD. |
| `bvh_query_sphere` / `bvh_query_sphere_primitives` | `(bvh, center, radius, results)` | Sphere overlaps. |
| `bvh_query_ray` | `(bvh, ray, max_dist, results)` | All primitives intersecting ray. |
| `bvh_query_nearest` | `(bvh, point, max_dist, results)` | Nearest primitives within radius. |
| `bvh_raycast` / `bvh_raycast_single` | `(bvh, ray, max_dist, intersect_proc) -> RayHit(T)` | Closest hit. |
| `bvh_raycast_multi` | `(bvh, ray, max_dist, results, intersect_proc)` | All hits. |
| `bvh_refit` | `(bvh)` | Refit bounds (full pass over leaves). |
| `bvh_insert` / `bvh_remove` / `bvh_update` | `(bvh, item)` / `(bvh, idx)` / `(bvh, idx, new)` | Mutations (full rebuild). |
| `bvh_insert_incremental` | `(bvh, item)` | Best-fit insertion without rebuild. |
| `bvh_find_all_overlaps` | `(bvh, results: ^[dynamic][2]int)` | Self-pair overlap test. |
| `bvh_find_cross_overlaps` | `(bvh1, bvh2, results)` | Cross-tree pair overlap. |
| `bvh_validate` | `(bvh) -> bool` | Sanity check. |
| `bvh_get_stats` | `(bvh) -> BVHStats` | Stats. |
| `compute_bvh_levels` | `(bvh)` | Level-order list (for parallel refit). |

## Octree

```odin
OctreeNode($T) :: struct {
  bounds:      Aabb,
  center:      [3]f32,
  children:    [8]^OctreeNode(T),
  items:       [dynamic]T,
  depth:       i32,
  total_items: i32,
}

Octree($T) :: struct {
  root:        ^OctreeNode(T),
  max_depth:   i32,
  max_items:   i32,
  min_size:    f32,
  bounds_func: proc(t: T) -> Aabb,
  point_func:  proc(t: T) -> [3]f32,
}

OctreeStats :: struct {
  node_count, leaf_count, total_items: int,
  max_depth: i32, avg_items_leaf: f32,
}
```

| Proc | Signature |
|---|---|
| `octree_init` | `(octree, bounds, max_depth=8, max_items=8)` |
| `octree_destroy` | `(octree)` |
| `octree_insert` / `octree_remove` / `octree_update` | mutations |
| `octree_query_aabb` | `(octree, bounds, results)` |
| `octree_query_aabb_limited` | `(octree, bounds, max_results, results)` |
| `octree_query_sphere` | `(octree, center, radius, results)` |
| `octree_query_disc` | `(octree, center, normal, radius, results)` |
| `octree_query_ray` | `(octree, ray, max_dist, results)` |
| `octree_raycast` / `_single` / `_multi` | with custom `intersection_func` |
| `octree_get_stats` | `(octree) -> OctreeStats` |

## Interval tree

```odin
Interval :: struct { start, end: int }

IntervalTree :: struct {
  root:      ^IntervalNode,
  allocator: mem.Allocator,
}
```

```odin
interval_tree_init(tree, allocator = context.allocator)
interval_tree_destroy(tree)
interval_tree_insert(tree, start: int, count: int = 1)   // auto-merges
interval_tree_get_ranges(tree, allocator = context.temp_allocator) -> []Interval
interval_tree_clear(tree)
```

## Transform

```odin
Transform :: struct {
  position:     [3]f32,
  rotation:     quaternion128,
  scale:        [3]f32,
  is_dirty:     bool,
  local_matrix: matrix[4, 4]f32,
  world_matrix: matrix[4, 4]f32,
}

TRANSFORM_IDENTITY  // identity transform constant
```

```odin
decompose_matrix(m: matrix[4,4]f32) -> Transform
translate / translate_by                (t, x=0, y=0, z=0)
rotate    / rotate_by                   (t, q)
rotate    / rotate_by                   (t, angle, axis = Y)
scale_xyz / scale_xyz_by                (t, x=1, y=1, z=1)
scale     / scale_by                    (t, s)
update_local(t) -> bool                 // recompute if dirty
update_world(t, parent_world) -> bool
```

## SIMD batch ops

```odin
SIMD_Mode :: enum { Scalar, SSE, AVX2 }
simd_mode  : SIMD_Mode    // detected at startup
simd_lanes : int          // 1, 4, or 8

aabb_intersects_batch4(a, b: [4]Aabb) -> [4]bool
obb_to_aabb_batch4(obbs: [4]Obb, aabbs: ^[4]Aabb)
```

`physics/simd.odin` re-exports these plus a few quaternion / dot / cross
helpers — see `api_physics.md`.

## OBJ loader

```odin
load_obj(filename: string, scale: f32 = 1.0) -> (Geometry, bool)
```

Computes vertex normals if missing; supports negative indices and face
triangulation.

## Direction & range constants

```odin
VEC_FORWARD  :: [3]f32{0, 0, 1}
VEC_BACKWARD :: [3]f32{0, 0, -1}
VEC_UP       :: [3]f32{0, 1, 0}
VEC_DOWN     :: [3]f32{0, -1, 0}
VEC_LEFT     :: [3]f32{-1, 0, 0}
VEC_RIGHT    :: [3]f32{1, 0, 0}
F32_MIN      :: -3.40282347e+38
F32_MAX      ::  3.40282347e+38
```

## 2D helpers (XZ-plane navigation math)

```odin
vector_equal(a, b, eps = 1e-4) -> bool
calculate_polygon_min_extent_2d(verts) -> f32
point_segment_distance2_2d(p, a, b) -> (sq_dist, t: f32)
closest_point_on_segment(p, a, b) -> [3]f32
closest_point_on_segment_2d(p, a, b) -> [3]f32
ray_circle_intersect_2d(pos, vel, radius) -> (t: f32, hit: bool)
ray_segment_intersect_2d(start, dir, seg_a, seg_b) -> (t: f32, hit: bool)
segment_segment_intersect_2d(p0, p1, a, b) -> bool
perpendicular_cross_2d(a, b, c) -> f32
point_in_triangle_2d(p, a, b, c, eps = 0) -> bool
```
