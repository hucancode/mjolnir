// Package navigation is the runtime navmesh: load or init a NavMesh, then
// find_path, raycast and nearest_point against it. It never imports the baker,
// so shipped games can load pre-baked data without recast. Baking lives in
// navigation/bake, crowd steering in navigation/crowd, and the low-level
// Detour/Recast ports in navigation/detour and navigation/recast.
package navigation
