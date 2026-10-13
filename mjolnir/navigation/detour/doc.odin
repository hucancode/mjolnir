// Package detour is a port of Detour: the tiled navigation mesh (Nav_Mesh),
// its queries (Nav_Mesh_Query: find_path, raycast, find_nearest_poly,
// find_straight_path) and tile serialization. Start with nav_mesh_init,
// nav_mesh_add_tile and nav_mesh_query_init. Most users go through the
// navigation package instead. Query code is in pathfinding.odin,
// spatial_queries.odin and funnel.odin.
package detour
