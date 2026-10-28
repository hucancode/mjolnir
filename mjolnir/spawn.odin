package mjolnir

import "render"
import "world"

// spawn_mesh spawns a node at position under parent (the world root by default) drawing mesh,
// scaled by scale.
spawn_mesh :: proc(
  w: ^world.World,
  r: ^render.Renderer,
  mesh: render.MeshAttachment,
  position: [3]f32 = {},
  scale: [3]f32 = {1, 1, 1},
  parent: world.NodeHandle = {},
) -> world.NodeHandle {
  node := world.spawn(w, position, parent = parent)
  render.attach(r, node, mesh)
  if scale != {1, 1, 1} do world.scale(w, node, scale)
  return node
}
