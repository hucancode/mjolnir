package main

import "mjolnir/render"
import "mjolnir/geometry"

TRUNK_SEGMENTS :: 24
TRUNK_STEP :: f32(1) / TRUNK_SEGMENTS

rod_create :: proc(r: ^render.Renderer) -> (render.MeshHandle, bool) {
  vertices := make([dynamic]geometry.Vertex)
  indices := make([dynamic]u32)
  for segment in 0 ..< TRUNK_SEGMENTS {
    for end in 0 ..< 2 {
      joint := segment + end
      for side in ([2]f32{0, 1}) {
        append(
          &vertices,
          geometry.Vertex {
            position = {0, f32(joint) / TRUNK_SEGMENTS, f32(TRUNK_SEGMENTS - joint) / TRUNK_SEGMENTS},
            normal = {TRUNK_STEP, 1 if end == 0 else -1, 0},
            color = {f32(end), 0, 0, 0},
            uv = {side, f32(joint)},
            tangent = {1, 0, 0, 1},
          },
        )
      }
    }
    a := u32(4 * segment)
    append(&indices, a, a + 1, a + 2, a + 1, a + 3, a + 2)
  }
  return render.mesh_create(r, geometry.make_mesh(vertices[:], indices[:]))
}
