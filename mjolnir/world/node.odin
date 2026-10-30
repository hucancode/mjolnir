package world

import "../geometry"

// transform returns a node's local transform to edit in place; update recomputes the node and
// its subtree. The pointer is valid for this tick: getting it marks the node, so get it again
// next tick. false when stale.
transform :: proc(self: ^World, handle: NodeHandle) -> (^geometry.Transform, bool) #optional_ok {
  node := edit(self, handle)
  if node == nil do return nil, false
  return &node.transform, true
}
