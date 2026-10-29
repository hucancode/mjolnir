package mjolnir

import "render"
import "world"

// spawn spawns a node at position under parent (the world root by default), scaled by scale,
// with attachment on it: a mesh to draw, or a light, emitter or force field to place there.
spawn :: proc(
  w: ^world.World,
  r: ^render.Renderer,
  attachment: render.Attachment,
  position: [3]f32 = {},
  scale: [3]f32 = {1, 1, 1},
  parent: world.NodeHandle = {},
) -> world.NodeHandle {
  node := world.spawn(w, position, parent = parent)
  render.attach(r, node, attachment)
  if scale != {1, 1, 1} do world.scale(w, node, scale)
  return node
}
