// Pathfinding on a navigation mesh: init one from bytes baked by navigation/bake, then find paths
// and nearest points, or crowd_init a Crowd on it to steer many agents toward their goals.
package navigation

// Layer 2: systems

// The runtime navigation mesh: init a NavMesh from bytes (baked by navigation/bake, now or
// offline), then find_path, raycast and nearest_point against it; destroy frees it. save
// encodes it back into bytes. It never imports the baker, so a game that loads pre-baked data
// ships without recast. A Crowd (crowd.odin) moves agents across it, steering around each
// other; its internals (path corridor, path queue, local boundary, proximity grid, velocity
// sampling) are package-private in the sibling files. Sub-packages: bake (baking) and the
// low-level Detour and Recast ports, detour and recast.
// Recast, Detour and DetourCrowd are Copyright (c) 2009 Mikko Mononen memon@inside.org; (originally written in C++, ported to Odin and adapted by hucancode@gmail.com)
