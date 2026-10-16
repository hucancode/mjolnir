// The runtime navigation mesh: load a NavMesh from bytes (baked by navigation/bake, now or
// offline), then find_path, raycast and nearest_point against it; destroy frees it. save
// encodes it back into bytes. It never imports the baker, so a game that loads pre-baked data
// ships without recast. Sub-packages: bake (baking), crowd (agent steering), and the
// low-level Detour and Recast ports, detour and recast.
package navigation
