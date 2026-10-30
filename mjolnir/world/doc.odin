// A scene graph: a tree of nodes with transforms. Spawn and move nodes, call update each tick,
// and pass its changes to what draws or simulates them (render.stage_transforms). A node's
// index keys it there (its render slot), and a hidden node hides its subtree.
package world

// Layer 2: systems
