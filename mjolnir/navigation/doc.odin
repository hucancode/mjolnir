// Pathfinding on a navigation mesh: load one baked by navigation/bake, then find paths and
// nearest points.
package navigation

// The runtime navigation mesh: load a NavMesh from bytes (baked by navigation/bake, now or
// offline), then find_path, raycast and nearest_point against it; destroy frees it. save
// encodes it back into bytes. It never imports the baker, so a game that loads pre-baked data
// ships without recast. Sub-packages: bake (baking), crowd (agent steering), and the
// low-level Detour and Recast ports, detour and recast.
