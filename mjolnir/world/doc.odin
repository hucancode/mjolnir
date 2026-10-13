// Scene graph: a pool of nodes with parent/child links, local transforms and
// visibility. Entry points: init, spawn, update (recomputes world matrices),
// then changed_nodes/removed_nodes for consumers such as the renderer.
// Handles live in handles.odin, node transform helpers in node.odin.
package world
