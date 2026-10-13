// Package bake builds a navigation.NavMesh from triangle geometry at runtime
// or offline. Entry points: NavGeometryBuilder, append_triangles, build, with
// NavMeshConfig choosing agent size and quality. Internals (recast config
// mapping, detour tile data and BV tree construction) are in config.odin and
// navmesh_builder.odin.
package bake
