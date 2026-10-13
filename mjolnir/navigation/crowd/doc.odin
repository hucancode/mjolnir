// Package crowd simulates groups of agents walking on a navigation.NavMesh
// with path following, neighbour separation and obstacle avoidance. Entry
// points: create, add_agent, move_to, update, destroy. Internals (path
// corridor, path queue, local boundary, proximity grid, velocity sampling) are
// package-private in the sibling files.
package crowd
