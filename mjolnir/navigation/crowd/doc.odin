// Groups of agents walking on a navigation mesh, with path following, neighbour separation
// and obstacle avoidance. init a crowd on a navigation.NavMesh's detour_mesh, agent_add,
// give agents goals with move_to, then update once per tick and read each agent's position
// and velocity (agent). destroy frees it.
package crowd

// Internals: path corridor, path queue, local boundary, proximity grid and velocity sampling
// are package-private in the sibling files.
