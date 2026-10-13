// Geometry primitives and spatial math shared by the engine: Aabb, Obb, Ray,
// Sphere, Frustum, quaternion helpers, and a generic BVH for broad-phase queries.
// Entry points: bvh_build / bvh_query_* / bvh_find_*_overlaps (bvh.odin),
// make_frustum (frustum.odin), 2D XZ-plane helpers used by navigation (geometry.odin).
// The octree (octree.odin) is package-private and exercised only by tests.
package geometry
