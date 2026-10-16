// Navigation mesh baking, at runtime or offline: add walkable and obstacle triangles to a
// NavGeometryBuilder with append_triangles, then build them into bytes with a NavMeshConfig
// choosing agent size and quality. navigation.load the bytes, or store them and load them in
// the shipped game, which then needs neither bake nor recast.
package bake

// Internals: recast config mapping (config.odin), detour tile data and BV tree construction
// (navmesh_builder.odin).
