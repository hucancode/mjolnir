package mjolnir

import "render"
import "world"

// spawn spawns a node at a local position, rotation and scale under parent (the world root by
// default), named `name` (borrowed), with attachment on it: a mesh to draw, or a light, emitter
// or force field to place there.
spawn :: proc(
  w: ^world.World,
  r: ^render.Renderer,
  attachment: render.Attachment,
  position: [3]f32 = {},
  rotation: quaternion128 = 1,
  scale: [3]f32 = {1, 1, 1},
  name: string = "",
  parent: world.NodeHandle = {},
) -> world.NodeHandle {
  node := world.spawn(w, position, rotation, scale, name, parent)
  render.attach(r, node, attachment)
  return node
}
