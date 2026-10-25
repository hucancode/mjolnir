package main

import "mjolnir/render"

TRUNK_SEGMENTS :: 24
TRUNK_STEP :: f32(1) / TRUNK_SEGMENTS

// The rod every bolt bends: a straight ribbon of TRUNK_SEGMENTS segments, from the ground (y = 0)
// to the sky (y = 1). Each segment has its own four vertices, two at each end, one on either side,
// so a vertex can see across its segment. The uv spans 0 to 1 across the ribbon and, along it, the
// joint number from 0 to TRUNK_SEGMENTS. A vertex also carries where its joint rests and when the
// leader reaches it, from 0 at the sky to 1 at the ground (position), the distance to the
// neighboring joints (normal.x), whether the other end of its segment lies toward the sky (1) or
// the ground (-1) from it (normal.y), how far along its segment it is (color.x), and the direction
// across the ribbon when straight (tangent.xy).
rod: render.MeshHandle

rod_create :: proc(r: ^render.Renderer) -> bool {
  vertices := make([dynamic]render.Vertex)
  indices := make([dynamic]u32)
  for segment in 0 ..< TRUNK_SEGMENTS {
    for end in 0 ..< 2 {
      joint := segment + end
      for side in ([2]f32{0, 1}) {
        append(
          &vertices,
          render.Vertex {
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
  rod = render.mesh_create(r, render.make_geometry(vertices[:], indices[:])) or_return
  return true
}

rod_destroy :: proc(r: ^render.Renderer) {
  render.mesh_destroy(r, rod)
}
